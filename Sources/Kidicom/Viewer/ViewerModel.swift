import SwiftUI

/// How the image area is split.
enum ViewerLayout: String, CaseIterable, Identifiable {
    case single, sideBySide, stacked, grid

    var id: String { rawValue }
    var columns: Int { self == .sideBySide || self == .grid ? 2 : 1 }
    var rows: Int { self == .stacked || self == .grid ? 2 : 1 }
    var count: Int { columns * rows }

    var title: LocalizedStringResource {
        switch self {
        case .single: "1 Viewport"
        case .sideBySide: "2 Side by Side"
        case .stacked: "2 Stacked"
        case .grid: "4 Viewports"
        }
    }

    var symbol: String {
        switch self {
        case .single: "square"
        case .sideBySide: "rectangle.split.2x1"
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
        didSet { fillEmptyViewports() }
    }

    var visible: ArraySlice<Viewport> { viewports.prefix(layout.count) }
    var active: Viewport? { viewports.indices.contains(activeIndex) ? viewports[activeIndex] : nil }

    /// Snapshot mode sets the layout of the next viewer that opens.
    static var nextLayout: ViewerLayout?
    /// Snapshot mode: rotate right and flip the first viewport of the next viewer.
    static var nextTransformed = false

    func load(_ study: Study) {
        guard stacks.isEmpty else { return }
        if let next = Self.nextLayout { layout = next; Self.nextLayout = nil }
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
    }

    func activate(_ viewport: Viewport) {
        if let index = viewports.firstIndex(where: { $0 === viewport }) { activeIndex = index }
    }

    func show(_ stack: SeriesStack) {
        active?.show(stack)
    }

    /// New viewports get the series not shown yet, in strip order.
    private func fillEmptyViewports() {
        if activeIndex >= layout.count { activeIndex = 0 }
        guard !stacks.isEmpty else { return }
        for viewport in visible where viewport.stack == nil {
            let shown = Set(visible.compactMap { $0.stack?.id })
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
        let isActive = viewer.active === viewport && viewer.layout.count > 1
        return ViewportView(viewport: viewport, isActive: isActive) { viewer.activate(viewport) }
            .overlay { ViewportOverlay(viewport: viewport, study: study).allowsHitTesting(false) }
            .overlay {
                Rectangle()
                    .strokeBorder(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .clipped()
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let stack = viewer.stacks.first(where: { $0.id == id }) else { return false }
                viewer.activate(viewport)
                viewport.show(stack)
                return true
            }
    }
}
