import KidicomKit
import SwiftUI

/// How the image area is split.
enum ViewerLayout: String, CaseIterable, Identifiable {
    case single, sideBySide, three, stacked, grid

    var id: String { rawValue }
    var columns: Int {
        switch self {
        case .single, .stacked: 1
        case .sideBySide, .grid: 2
        case .three: 3
        }
    }
    var rows: Int { self == .stacked || self == .grid ? 2 : 1 }
    var count: Int { columns * rows }

    var title: LocalizedStringResource {
        switch self {
        case .single: "1 Viewport"
        case .sideBySide: "2 Side by Side"
        case .three: "3 Side by Side"
        case .stacked: "2 Stacked"
        case .grid: "4 Viewports"
        }
    }

    var symbol: String {
        switch self {
        case .single: "square"
        case .sideBySide: "rectangle.split.2x1"
        case .three: "rectangle.split.3x1"
        case .stacked: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        }
    }
}

/// The state of one viewer window: the study's series and up to four viewports.
@Observable
final class ViewerModel {
    private(set) var stacks: [SeriesStack] = []
    /// Four viewports always exist; the layout decides how many show.
    let viewports: [Viewport] = (0 ..< 4).map { _ in Viewport() }
    var activeIndex = 0
    var layout: ViewerLayout = .single {
        didSet {
            maximized = nil
            fillEmptyViewports()
        }
    }
    /// The MPR session, while it is on.
    private(set) var mpr: MPRSession?
    /// Progress while a volume builds, 0...1.
    private(set) var buildProgress: Double?
    /// Why the last MPR or 3D request failed, shown inline.
    var mprMessage: String?
    /// The 3D view, while it is on.
    private(set) var volume3D: VolumeSession?
    /// Volumes already built, by series id, shared by MPR and 3D.
    @ObservationIgnored private var volumes: [String: Volume] = [:]

    /// Prior studies opened to compare, shown below the series strip.
    var priors: [PriorStudy] = []
    /// Scroll follows across parallel viewports (S-031). On by default.
    var syncScroll = true
    /// W/L follows across viewports. Off by default.
    var syncWindowLevel = false {
        didSet { connectWindowSync() }
    }

    init() {
        connectSync()
    }

    /// The viewport shown alone over the whole image area (double-click), or nil.
    private(set) var maximized: Viewport?

    /// Double-click in a viewport: maximize it in a split layout, restore
    /// it when maximized, reset it in a single layout.
    func doubleClick(_ viewport: Viewport) {
        activate(viewport)
        if maximized != nil {
            maximized = nil
        } else if layout.count > 1 {
            maximized = viewport
        } else {
            viewport.reset()
        }
    }

    /// Esc: leave 3D or the maximized viewport first, then the measuring tool.
    func escape() {
        if volume3D != nil { volume3D = nil } else if maximized != nil { maximized = nil } else { tool = .navigate }
    }

    /// Shows the DICOM tags of the active image (⌘I).
    var showsTags = false
    /// The left-button tool, shared by every viewport.
    var tool: MeasureTool = .navigate {
        didSet { for viewport in viewports { viewport.tool = tool } }
    }

    var visible: ArraySlice<Viewport> { viewports.prefix(layout.count) }
    var active: Viewport? { viewports.indices.contains(activeIndex) ? viewports[activeIndex] : nil }

    /// Snapshot mode sets the layout of the next viewer that opens.
    static var nextLayout: ViewerLayout?
    /// Snapshot mode: rotate right and flip the first viewport of the next viewer.
    static var nextTransformed = false
    /// Snapshot mode: add a distance and an angle once the first image shows.
    static var nextMeasured = false
    /// Snapshot mode: open the tag inspector in the next viewer.
    static var nextShowsTags = false
    /// Snapshot mode: open MPR in the next viewer; with MIP, a 20 mm MIP on the second plane.
    static var nextMPR = false
    static var nextMIP = false
    static var next3D = false
    /// Snapshot mode: open the newest prior beside the next viewer's study.
    static var nextComparePrior = false

    func load(_ study: Study) {
        guard stacks.isEmpty else { return }
        if let next = Self.nextLayout { layout = next; Self.nextLayout = nil }
        if Self.nextShowsTags { showsTags = true; Self.nextShowsTags = false }
        stacks = study.series.sorted { ($0.number, $0.seriesDescription) < ($1.number, $1.seriesDescription) }
            .map(SeriesStack.init(series:))
            .filter { $0.count > 0 }
        // Start on the series with the most images, not the scout.
        if let main = stacks.max(by: { $0.count < $1.count }) { viewports[0].show(main) }
        if Self.nextTransformed {
            viewports[0].rotate(clockwise: true)
            viewports[0].flip(horizontal: true)
            Self.nextTransformed = false
        }
        fillEmptyViewports()
        for stack in stacks { Task { await stack.makeThumbnail() } }
        if Self.next3D {
            Self.next3D = false
            Task { await enter3D() }
        }
        if Self.nextMPR {
            Self.nextMPR = false
            let mip = Self.nextMIP
            Self.nextMIP = false
            Task {
                await enterMPR()
                if mip, let source = viewports[1].source as? ReformatSource {
                    source.setSlab(20, mip: true)
                    viewports[1].reload()
                }
            }
        }
        if Self.nextMeasured {
            Self.nextMeasured = false
            let viewport = viewports[0]
            Task {
                while viewport.slice == nil { try? await Task.sleep(for: .milliseconds(20)) }
                guard let slice = viewport.slice else { return }
                let w = CGFloat(slice.width), h = CGFloat(slice.height)
                viewport.measurements = [
                    Measurement(kind: .distance, points: [CGPoint(x: w * 0.3, y: h * 0.45), CGPoint(x: w * 0.6, y: h * 0.45)], slice: viewport.index),
                    Measurement(kind: .angle, points: [CGPoint(x: w * 0.55, y: h * 0.7), CGPoint(x: w * 0.65, y: h * 0.85), CGPoint(x: w * 0.8, y: h * 0.75)], slice: viewport.index),
                ]
                viewport.selected = viewport.measurements[1].id
            }
        }
    }

    func activate(_ viewport: Viewport) {
        if let index = viewports.firstIndex(where: { $0 === viewport }) { activeIndex = index }
    }

    func show(_ stack: SeriesStack) {
        active?.show(stack)
        if let active, layout.count > 1 { alignNewViewport(active) }
    }

    /// The current study's series and those of opened priors.
    var allStacks: [SeriesStack] { stacks + priors.flatMap(\.stacks) }

    /// Right-click on a thumbnail: show the series in one more viewport to
    /// compare, 1 -> 2 side by side -> 3 side by side -> 2x2. With four
    /// viewports open, it replaces the active one.
    func compare(_ stack: SeriesStack) {
        let next: ViewerLayout?
        switch layout.count {
        case 1: next = .sideBySide
        case 2: next = .three
        case 3: next = .grid
        default: next = nil
        }
        guard let next else {
            active?.show(stack)
            if let active { alignNewViewport(active) }
            return
        }
        let target = layout.count
        // Keep the open viewports, then fill the new one with this series.
        viewports[target].show(stack)
        layout = next
        activeIndex = target
        alignNewViewport(viewports[target])
    }

    // MARK: MPR (S-020 to S-022)

    /// The series MPR would use: the active viewport's series of files.
    var mprCandidate: SeriesStack? {
        guard let stack = active?.stack, stack.count >= 3, !stack.isCine else { return nil }
        return stack
    }

    func toggleMPR() {
        if mpr != nil { exitMPR() } else { Task { await enterMPR() } }
    }

    func enterMPR() async {
        guard mpr == nil, buildProgress == nil, let stack = mprCandidate, let current = active else { return }
        mprMessage = nil
        buildProgress = 0
        defer { buildProgress = nil }
        guard let volume = await volume(for: stack) else { return }
        let window = current.effectiveWindow ?? VOIWindow(center: 40, width: 400)
        let sources = VolumePlane.allCases.map {
            ReformatSource(volume: volume, plane: $0, seriesID: stack.id, modality: stack.modality, window: window)
        }
        mpr = MPRSession(volume: volume, sources: sources, previousLayout: layout,
                         previousSources: viewports.map(\.source), previousIndexes: viewports.map(\.index))
        // Center each plane on the image the person was looking at.
        let nativeIndex = volume.depth - 1 - min(volume.depth - 1, current.index)
        let personWindow = current.window
        for (i, source) in sources.enumerated() {
            let viewport = viewports[i]
            viewport.show(source, at: i == 0 ? nativeIndex : source.count / 2)
            viewport.setWindowQuietly(personWindow)
            viewport.onWindowChange = { [weak self] window in self?.syncWindow(window, from: viewport) }
        }
        // Sources first, then the layout, so no viewport loads a series on the way.
        layout = .three
        activeIndex = 0
    }

    /// Builds or reuses the volume of a series, reporting why it can't be built.
    private func volume(for stack: SeriesStack) async -> Volume? {
        if let cached = volumes[stack.id] { return cached }
        buildProgress = 0
        defer { buildProgress = nil }
        do {
            let volume = try await stack.buildVolume { self.buildProgress = $0 }
            volumes = [stack.id: volume]   // keep one volume in memory
            return volume
        } catch VolumeError.mixedOrientations {
            mprMessage = String(localized: "This series mixes image orientations and can't be reformatted.")
        } catch {
            mprMessage = String(localized: "This series can't be reformatted. It needs at least three parallel images with position data.")
        }
        return nil
    }

    // MARK: 3D (S-023)

    func toggle3D() {
        if volume3D != nil { volume3D = nil } else { Task { await enter3D() } }
    }

    func enter3D() async {
        guard volume3D == nil, buildProgress == nil else { return }
        let stack = mprCandidate ?? (mpr.flatMap { session in stacks.first { $0.id == session.sources.first?.id.split(separator: "#").first.map(String.init) } })
        guard let stack else { return }
        mprMessage = nil
        let window = active?.effectiveWindow ?? VOIWindow(center: 40, width: 400)
        guard let volume = await volume(for: stack) else { return }
        guard let session = VolumeSession(volume: volume, title: stack.title, window: window, modality: stack.modality) else {
            mprMessage = String(localized: "3D needs a Mac with Metal.")
            return
        }
        volume3D = session
    }

    func exitMPR() {
        guard let session = mpr else { return }
        mpr = nil
        for (i, viewport) in viewports.enumerated() {
            viewport.onWindowChange = nil
            if let previous = session.previousSources[i] { viewport.show(previous, at: session.previousIndexes[i]) }
        }
        layout = session.previousLayout
        activeIndex = 0
        connectWindowSync()
    }

    /// W/L follows across the three planes.
    private func syncWindow(_ window: VOIWindow?, from origin: Viewport) {
        guard mpr != nil else { return }
        for viewport in viewports.prefix(3) where viewport !== origin {
            viewport.setWindowQuietly(window)
        }
    }

    /// A click (no drag) in an MPR plane moves the other two planes there.
    func click(at point: CGPoint, in viewport: Viewport) {
        guard let session = mpr, let mine = viewport.source as? ReformatSource else { return }
        for (i, other) in session.sources.enumerated() where other !== mine {
            if let index = session.volume.index(of: other.plane, at: (Double(point.x), Double(point.y)), in: mine.plane) {
                viewports[i].go(to: index)
            }
        }
    }

    /// New viewports get the series not shown yet, in strip order.
    private func fillEmptyViewports() {
        if activeIndex >= layout.count { activeIndex = 0 }
        guard !stacks.isEmpty else { return }
        for viewport in visible where viewport.source == nil {
            let shown = Set(visible.compactMap { $0.source?.id })
            // Skip scouts (single images) while real series are left.
            let next = stacks.first { !shown.contains($0.id) && $0.count > 1 }
                ?? stacks.first { !shown.contains($0.id) }
                ?? stacks[0]
            viewport.show(next)
        }
    }
}

/// The image area: one to four viewports, the active one outlined.
struct ViewportGrid: View {
    let viewer: ViewerModel
    let study: Study

    var body: some View {
        let layout = viewer.layout
        if let session = viewer.volume3D {
            VolumePane(session: session, study: study)
                .onKeyPress(.escape) { viewer.escape(); return .handled }
        } else if let maximized = viewer.maximized {
            cell(maximized)
        } else {
            grid(layout)
        }
    }

    private func grid(_ layout: ViewerLayout) -> some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0 ..< layout.rows, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< layout.columns, id: \.self) { column in
                        cell(viewer.viewports[row * layout.columns + column])
                    }
                }
            }
        }
        .background(Color(white: 0.25))
    }

    private func cell(_ viewport: Viewport) -> some View {
        let isActive = viewer.active === viewport && viewer.layout.count > 1 && viewer.maximized == nil
        return ViewportView(viewport: viewport, isActive: isActive, onActivate: { viewer.activate(viewport) },
                            onEscape: { viewer.escape() },
                            onClick: { point in viewer.click(at: point, in: viewport) },
                            onDoubleClick: { viewer.doubleClick(viewport) })
            .overlay { CrosshairOverlay(viewer: viewer, viewport: viewport) }
            .overlay { MeasurementOverlay(viewport: viewport) }
            .overlay { ViewportOverlay(viewport: viewport, study: study).allowsHitTesting(false) }
            .overlay {
                Rectangle()
                    .strokeBorder(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .clipped()
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let stack = viewer.allStacks.first(where: { $0.id == id }) else { return false }
                viewer.activate(viewport)
                viewport.show(stack)
                viewer.alignNewViewport(viewport)
                return true
            }
    }
}
