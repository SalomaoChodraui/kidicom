import AppKit
import KidicomKit
import SwiftData
import SwiftUI

/// The viewer window for one study: the series strip and the viewport.
struct ViewerView: View {
    let studyUID: UUID
    @Query private var studies: [Study]
    @Query(sort: \Study.studyDate, order: .reverse) private var allStudies: [Study]
    @State private var viewer = ViewerModel()

    /// Other studies of the same patient, newest first.
    private func priors(of study: Study) -> [Study] {
        guard !study.patientID.isEmpty else { return [] }
        return allStudies.filter { $0.patientID == study.patientID && $0.uid != study.uid && !Availability.shared.isOffline($0) }
    }

    init(studyUID: UUID) {
        self.studyUID = studyUID
        _studies = Query(filter: #Predicate<Study> { $0.uid == studyUID })
    }

    /// Plane, rotate, flip, and reset for the active viewport; it also carries their shortcuts.
    private var orientationMenu: some View {
        Menu {
            Section("Plane") {
                Button("Axial") { Task { await viewer.show(plane: .axial) } }
                    .keyboardShortcut("1", modifiers: .control)
                Button("Coronal") { Task { await viewer.show(plane: .coronal) } }
                    .keyboardShortcut("2", modifiers: .control)
                Button("Sagittal") { Task { await viewer.show(plane: .sagittal) } }
                    .keyboardShortcut("3", modifiers: .control)
            }
            .disabled(!viewer.canChangePlane)
            Section("Rotate and Flip") {
                Button("Rotate Right") { viewer.active?.rotate(clockwise: true) }
                    .keyboardShortcut("r", modifiers: .control)
                Button("Rotate Left") { viewer.active?.rotate(clockwise: false) }
                    .keyboardShortcut("l", modifiers: .control)
                Button("Flip Horizontal") { viewer.active?.flip(horizontal: true) }
                    .keyboardShortcut("h", modifiers: [])
                Button("Flip Vertical") { viewer.active?.flip(horizontal: false) }
                    .keyboardShortcut("v", modifiers: [])
            }
            Divider()
            Button("Reset View") {
                if let session = viewer.volume3D { session.resetCamera() } else { viewer.active?.reset() }
            }
                .keyboardShortcut("r", modifiers: .command)
        } label: {
            Label("Orientation", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .menuIndicator(.hidden)
        .help("Plane, rotate, or flip the active viewport (⌃1 to ⌃3, ⌃R, ⌃L, H, V); ⌘R resets the view")
    }

    var body: some View {
        Group {
            if let study = studies.first {
                if study.isOffline {
                    ContentUnavailableView(
                        "Study Offline", systemImage: "externaldrive.badge.xmark",
                        description: Text("The files of this study were moved or removed.")
                    )
                } else {
                    content(study)
                }
            } else {
                ContentUnavailableView("Study Not Found", systemImage: "questionmark.square.dashed")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func content(_ study: Study) -> some View {
        HStack(spacing: 0) {
            if viewer.seriesInline {
                SeriesStrip(viewer: viewer, current: study, others: priors(of: study))
                    .frame(width: SeriesStrip.width)
                    .overlay(alignment: .trailing) { Divider() }
                    .gridProbe("series-strip", area: "viewer", edge: nil)
            }
            ViewportGrid(viewer: viewer, study: study)
                .gridProbe("image-area", area: "viewer", edge: nil)
                .overlay {
                    if let progress = viewer.buildProgress {
                        VStack(spacing: Space.sm) {
                            ProgressView(value: progress).frame(width: 200)
                            Text("Building volume…")
                        }
                        .padding(Space.lg)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                }
                .overlay(alignment: .top) {
                    if let message = viewer.mprMessage {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(message)
                            Button("Close") { viewer.mprMessage = nil }.controlSize(.small)
                        }
                        .padding(Space.sm)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card))
                        .padding(Space.lg)
                    }
                }
        }
        .overlay(alignment: .leading) {
            if viewer.seriesAutoHide {
                SeriesReveal(viewer: viewer, current: study, others: priors(of: study))
            }
        }
        .gridArea("viewer", inset: 0)
        .inspector(isPresented: Bindable(viewer).showsTags) {
            TagInspector(viewport: viewer.active)
                .inspectorColumnWidth(min: 400, ideal: 600, max: 1000)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(viewer.seriesInline ? "Hide Series" : "Show Series", systemImage: "sidebar.left") {
                    viewer.toggleSeries()
                }
                .help("Show or hide the series to give more room to the images (⇧⌘S)")
            }
            ToolbarItem {
                Menu {
                    Picker("Layout", selection: Bindable(viewer).layout) {
                        ForEach(ViewerLayout.allCases) { layout in
                            Label(layout.title, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label("Layout", systemImage: viewer.layout == .single ? "rectangle.split.2x1" : viewer.layout.symbol)
                } primaryAction: {
                    viewer.toggleSplit()
                }
                .help(viewer.layout == .single
                      ? "Split the image area; the arrow picks up to four viewports"
                      : "Back to one viewport; the arrow picks up to four viewports")
            }
            ToolbarItem {
                let others = priors(of: study)
                Menu {
                    if others.isEmpty {
                        Text("No other studies of this patient")
                    }
                    ForEach(others, id: \.uid) { prior in
                        Button {
                            viewer.openPrior(prior)
                        } label: {
                            Text("\(prior.studyDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")  \(prior.modalities)  \(prior.studyDescription)")
                        }
                    }
                    Divider()
                    Toggle("Sync Scrolling", isOn: Bindable(viewer).syncScroll)
                    Toggle("Sync Zoom", isOn: Bindable(viewer).syncZoom)
                    Toggle("Sync Window/Level", isOn: Bindable(viewer).syncWindowLevel)
                } label: {
                    // No badge: a toolbar menu shows only its icon; the priors are listed inside and in the strip.
                    Image(systemName: "clock.arrow.circlepath")
                    .accessibilityLabel(Text("Compare"))
                } primaryAction: {
                    if let latest = others.first { viewer.openPrior(latest) }
                }
                .help("Open the latest prior study of this patient beside the current one; the arrow lists the others and what scrolls together")
            }
            ToolbarItem {
                Picker("Tool", selection: Bindable(viewer).tool) {
                    ForEach(MeasureTool.allCases) { tool in
                        let in3D = viewer.volume3D != nil
                        Label { Text(tool.title(in3D: in3D)) } icon: { tool.icon(in3D: in3D) }.tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help(Text("Left button: window/level (\(ToolKeys.shared.key(for: .navigate).uppercased())), scroll (\(ToolKeys.shared.key(for: .scroll).uppercased())), rotate (\(ToolKeys.shared.key(for: .rotate).uppercased())), distance (\(ToolKeys.shared.key(for: .distance).uppercased())), angle (\(ToolKeys.shared.key(for: .angle).uppercased())), or area (\(ToolKeys.shared.key(for: .area).uppercased())). Esc returns to window/level."))
            }
            ToolbarItem {
                let playing = viewer.active?.isPlaying == true
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    viewer.active?.togglePlay()
                }
                .help(playing ? "Pause the cine (Space)" : "Play the images as a cine (Space)")
                .disabled((viewer.active?.count ?? 0) < 2)
            }
            // The planes and the orientation menu share one capsule. Plane and
            // slab mean nothing in 3D: their room goes to the 3D presets.
            ToolbarItem {
                HStack(spacing: Space.xs) {
                    if viewer.volume3D == nil {
                        PlanePicker(viewer: viewer)
                    }
                    orientationMenu
                }
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { viewer.mpr != nil }, set: { _ in viewer.toggleMPR() })) {
                    Label("MPR", systemImage: "square.stack.3d.up")
                }
                .help(viewer.mpr == nil ? "Reformat the active series in three planes (MPR)" : "Leave MPR")
                .disabled(viewer.mpr == nil && viewer.mprCandidate == nil || viewer.buildProgress != nil)
            }
            if viewer.volume3D == nil {
                ToolbarItem {
                    SlabControl(viewer: viewer)
                }
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { viewer.volume3D != nil }, set: { _ in viewer.toggle3D() })) {
                    Label("3D", systemImage: "view.3d")
                }
                .help(viewer.volume3D == nil ? "Show the active series as a 3D volume" : "Leave 3D (Esc)")
                .disabled(viewer.volume3D == nil && viewer.mprCandidate == nil && viewer.mpr == nil || viewer.buildProgress != nil)
            }
            if let session = viewer.volume3D {
                ToolbarItem {
                    Menu {
                        ForEach(VolumePreset.allCases) { preset in
                            Button { session.apply(preset) } label: { Text(preset.title) }
                        }
                    } label: {
                        Label { Text(session.camera.preset.title) } icon: { Image(systemName: "paintpalette") }
                            .labelStyle(.titleAndIcon)
                    }
                    .fixedSize()
                    .help("Which tissues the 3D view shows")
                }
            }
            ToolbarItem {
                Button("DICOM Tags", systemImage: "info.circle") { viewer.showsTags.toggle() }
                    .keyboardShortcut("i")
                    .help("Show the DICOM tags of the image (⌘I)")
            }
        }
        .focusedSceneValue(\.viewer, viewer)
        // In full screen the toolbar and the menu bar slide in when the pointer reaches the top.
        .windowToolbarFullScreenVisibility(.onHover)
        .navigationTitle(study.displayName)
        .navigationSubtitle(study.studyDescription)
        // The patient and study show on the image; the toolbar needs the room.
        .toolbar(removing: .title)
        .background(CloseKeyCatcher(close: { viewer.closeActiveViewport() }, windowClosed: { viewer.close() },
                                    attached: { viewer.window = $0 }, exitedFullScreen: { viewer.exitedFullScreen() },
                                    tab: { viewer.overlay = viewer.overlay.next }))
        .task(id: study.uid) {
            viewer.load(study)
            if ViewerModel.nextComparePrior, let prior = priors(of: study).first {
                ViewerModel.nextComparePrior = false
                try? await Task.sleep(for: .milliseconds(300))
                viewer.openPrior(prior)
            }
        }
    }
}

/// Thumbnails of the study's series. Click shows one; drag it to a viewport.
struct SeriesStrip: View {
    let viewer: ViewerModel
    static let width: CGFloat = 184
    let current: Study
    /// The patient's other studies, newest first: the strip's timeline.
    var others: [Study] = []

    private func thumbnail(_ stack: SeriesStack) -> some View {
        Button { viewer.show(stack) } label: {
            SeriesThumbnail(stack: stack, isShown: viewer.active?.source?.id == stack.id)
        }
        .buttonStyle(.plain)
        .overlay { RightClickCatcher { viewer.compare(stack) } }
        .draggable(stack.id)
        .help(Text("Show \(stack.title). Right-click to open it beside the others to compare."))
    }

    var body: some View {
        ScrollView {
            // One folder per study; its header stays on top while its series scroll.
            LazyVStack(alignment: .leading, spacing: Space.md, pinnedViews: [.sectionHeaders]) {
                Section {
                    if !viewer.currentCollapsed {
                        ForEach(viewer.stacks) { stack in thumbnail(stack) }
                    }
                } header: {
                    StudyFolderHeader(study: current, isCurrent: true, expanded: !viewer.currentCollapsed,
                                      seriesCount: viewer.stacks.count) {
                        viewer.currentCollapsed.toggle()
                    }
                }
                ForEach(others, id: \.uid) { study in
                    let expanded = viewer.expandedPriors.contains(study.uid)
                    Section {
                        if expanded, let prior = viewer.priors.first(where: { $0.id == study.uid }) {
                            ForEach(prior.stacks) { stack in thumbnail(stack) }
                        }
                    } header: {
                        StudyFolderHeader(study: study, isCurrent: false, expanded: expanded,
                                          seriesCount: study.series.count) {
                            viewer.togglePrior(study)
                        }
                        .padding(.top, Space.sm)
                    }
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.bottom, Space.sm)
        }
        .background(.background.secondary)
    }
}

/// The header of one study in the series strip: date, description,
/// modalities. Click to fold or unfold its series.
struct StudyFolderHeader: View {
    let study: Study
    let isCurrent: Bool
    let expanded: Bool
    let seriesCount: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Space.sm) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: Space.xs)
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: Space.md)
                        Text(study.studyDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    HStack(spacing: Space.xs) {
                        if isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, Space.xs)
                                .background(Palette.accent, in: Capsule())
                        }
                        Text(study.modalities)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(study.studyDescription)
                        .font(.caption)
                        .lineLimit(2)
                    Text("^[\(seriesCount) series](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar, in: RoundedRectangle(cornerRadius: Space.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Space.sm)
                    .strokeBorder(isCurrent ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.separator), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide the series of this study" : "Show the series of this study. Right-click a thumbnail to open it beside the current images.")
    }
}

struct SeriesThumbnail: View {
    let stack: SeriesStack
    let isShown: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ZStack {
                Color.black
                if let thumbnail = stack.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: Space.xs))
            .overlay {
                RoundedRectangle(cornerRadius: Space.xs)
                    .strokeBorder(isShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            Text(stack.title)
                .font(.caption)
                .lineLimit(2)
            Text("\(stack.modality) · ^[\(stack.count) image](inflect: true)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        // Drawn when the cell first shows, at the cell's size in pixels.
        .task {
            await stack.makeThumbnail(maxPixels: CGSize(width: SeriesStrip.width * displayScale, height: Self.height * displayScale))
        }
    }

    static let height: CGFloat = 96
}

/// Text in the four corners, like a radiology workstation.
struct ViewportOverlay: View {
    let viewport: Viewport
    let study: Study
    var level: OverlayLevel = .full

    var body: some View {
        if level != .hidden { content }
    }

    private var content: some View {
        ZStack {
            corners
            if let edges = viewport.edges {
                VStack {
                    Text(edges.top)
                    Spacer()
                    Text(edges.bottom)
                }
                .padding(.vertical, Space.sm)
                HStack {
                    Text(edges.left)
                    Spacer()
                    Text(edges.right)
                }
                .padding(.horizontal, Space.sm)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 1, x: 0, y: 1)
    }

    private var corners: some View {
        VStack {
            HStack(alignment: .top) {
                corner([level == .full ? study.displayName : nil, level == .full ? study.patientID : nil, shownDate.map { $0.formatted(date: .numeric, time: .omitted) }], alignment: .leading)
                Spacer()
                corner([shownDescription, viewport.source?.title], alignment: .trailing)
            }
            Spacer()
            HStack(alignment: .bottom) {
                corner(bottomLeft, alignment: .leading)
                Spacer()
                corner(bottomRight, alignment: .trailing)
            }
        }
        .padding(Space.sm)
    }

    /// Study metadata follows the series displayed in each viewport.
    var shownDescription: String {
        viewport.baseStack?.studyDescription ?? study.studyDescription
    }

    /// The date of the study this viewport shows, which may be a prior.
    private var shownDate: Date? {
        if let stack = viewport.baseStack, stack.studyUID != nil { return stack.studyDate }
        return study.studyDate
    }

    private var bottomLeft: [String?] {
        guard viewport.count > 0 else { return [] }
        var lines = [String(localized: "Im \(viewport.shownIndex + 1)/\(viewport.count)")]
        if let source = viewport.source as? ReformatSource {
            if source.mode.isProjection { lines.append("\(String(localized: source.mode.title)) \(Int(source.slab)) mm") }
            for warning in source.volume.warnings {
                switch warning {
                case .gaps(let n): lines.append(String(localized: "\(n) gaps between slices"))
                case .unevenSpacing: lines.append(String(localized: "Uneven slice spacing"))
                }
            }
        }
        if let location = viewport.shownLocation, viewport.count > 1 {
            lines.append(String(localized: "Pos \(location.formatted(.number.precision(.fractionLength(1)))) mm"))
        }
        if viewport.syncOffset != 0 && viewport.stack != nil && abs(viewport.syncOffset) >= 0.05 {
            lines.append(String(localized: "Sync Δ \(viewport.syncOffset.formatted(.number.precision(.fractionLength(1)))) mm"))
        }
        if let thickness = viewport.slice?.sliceThickness, thickness > 0 {
            lines.append(String(localized: "Thk \(thickness.formatted(.number.precision(.fractionLength(1)))) mm"))
        }
        return lines
    }

    private var bottomRight: [String?] {
        var lines: [String?] = []
        if let window = viewport.effectiveWindow {
            lines.append(String(localized: "WL \(Int(window.center.rounded())) WW \(Int(window.width.rounded()))"))
        }
        lines.append(String(localized: "Zoom \(Int((viewport.zoom * 100).rounded()))%"))
        let degrees = Int((viewport.freeAngle * 180 / .pi).rounded()) % 360
        if degrees != 0 { lines.append(String(localized: "Rot \(degrees)°")) }
        if viewport.isPlaying {
            lines.append(String(localized: "▶ \(Int(viewport.framesPerSecond.rounded())) fps"))
        }
        return lines
    }

    private func corner(_ lines: [String?], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(lines.compactMap { $0 }.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
    }
}

/// Catches right-clicks and lets every other event through to the views below.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown || event.type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

/// Opens the slab and MIP controls for the active reformatted plane.
/// Catches ⌘W in the viewer window before the window closes: the viewer
/// closes one viewport (or leaves MPR or 3D) and only lets the window close
/// when one viewport is left.
struct CloseKeyCatcher: NSViewRepresentable {
    let close: () -> Bool
    /// Called once when the window itself closes, to free what it holds.
    var windowClosed: () -> Void = {}
    /// The window this view joined, or nil when it left.
    var attached: (NSWindow?) -> Void = { _ in }
    var exitedFullScreen: () -> Void = {}
    /// Tab outside a text field: the next overlay level.
    var tab: () -> Void = {}

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.close = close
        view.windowClosed = windowClosed
        view.attached = attached
        view.exitedFullScreen = exitedFullScreen
        view.tab = tab
    }

    final class CatcherView: NSView {
        var close: () -> Bool = { false }
        var windowClosed: () -> Void = {}
        var attached: (NSWindow?) -> Void = { _ in }
        var exitedFullScreen: () -> Void = {}
        var tab: () -> Void = {}
        private var monitor: Any?
        private var closeObserver: (any NSObjectProtocol)?
        private var fullScreenObserver: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
            if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver); self.fullScreenObserver = nil }
            attached(window)
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
            fullScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.exitedFullScreen() }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // The key view loop takes Tab before the menu sees it, so the window handles it here.
                if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                   !(window.firstResponder is NSText) {
                    self.tab()
                    return nil
                }
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "w" else { return event }
                return self.close() ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // The monitor goes away in viewDidMoveToWindow when the view leaves its window.
    }
}

/// The series strip in full screen: hidden until the pointer reaches the
/// window's left edge, then over the images until the pointer leaves it.
struct SeriesReveal: View {
    let viewer: ViewerModel
    let current: Study
    let others: [Study]
    @State private var revealed = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: Space.xs)
                .contentShape(Rectangle())
                .onHover { if $0 { revealed = true } }
            if revealed {
                SeriesStrip(viewer: viewer, current: current, others: others)
                    .frame(width: SeriesStrip.width)
                    .overlay(alignment: .trailing) { Divider() }
                    .shadow(radius: Space.sm)
                    .onHover { if !$0 { revealed = false } }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.default, value: revealed)
    }
}
