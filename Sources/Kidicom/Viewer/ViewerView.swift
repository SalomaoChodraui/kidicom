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
        return allStudies.filter { $0.patientID == study.patientID && $0.uid != study.uid && !$0.isOffline }
    }

    init(studyUID: UUID) {
        self.studyUID = studyUID
        _studies = Query(filter: #Predicate<Study> { $0.uid == studyUID })
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
            SeriesStrip(viewer: viewer, current: study, others: priors(of: study))
                .frame(width: 184)
            Divider()
            ViewportGrid(viewer: viewer, study: study)
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
        .inspector(isPresented: Bindable(viewer).showsTags) {
            TagInspector(viewport: viewer.active)
                .inspectorColumnWidth(min: 400, ideal: 600, max: 1000)
        }
        .toolbar {
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
                }
                .help("Open a prior study of this patient beside the current one, and set what scrolls together")
            }
            ToolbarItem {
                Picker("Tool", selection: Bindable(viewer).tool) {
                    ForEach(MeasureTool.allCases) { tool in
                        Label { Text(tool.title) } icon: { Image(systemName: tool.symbol) }.tag(tool)
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
            ToolbarItem {
                PlanePicker(viewer: viewer)
            }
            ToolbarItem {
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
                    Button("Reset View") { viewer.active?.reset() }
                        .keyboardShortcut("r", modifiers: .command)
                } label: {
                    Label("Orientation", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .menuIndicator(.hidden)
                .help("Plane, rotate, or flip the active viewport (⌃1 to ⌃3, ⌃R, ⌃L, H, V); ⌘R resets the view")
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { viewer.mpr != nil }, set: { _ in viewer.toggleMPR() })) {
                    Label("MPR", systemImage: "square.stack.3d.up")
                }
                .help(viewer.mpr == nil ? "Reformat the active series in three planes (MPR)" : "Leave MPR")
                .disabled(viewer.mpr == nil && viewer.mprCandidate == nil || viewer.buildProgress != nil)
            }
            ToolbarItem {
                SlabControl(viewer: viewer)
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { viewer.volume3D != nil }, set: { _ in viewer.toggle3D() })) {
                    Label("3D", systemImage: "cube")
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
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("Layout", selection: Bindable(viewer).layout) {
                        ForEach(ViewerLayout.allCases) { layout in
                            Label(layout.title, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label("Layout", systemImage: viewer.layout.symbol)
                }
                .menuIndicator(.hidden)
                .help("Split the image area into up to four viewports")
            }
        }
        .navigationTitle(study.displayName)
        .navigationSubtitle(study.studyDescription)
        // The patient and study show on the image; the toolbar needs the room.
        .toolbar(removing: .title)
        .background(CloseKeyCatcher { viewer.closeActiveViewport() })
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
            .frame(height: 96)
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
    }
}

/// Text in the four corners, like a radiology workstation.
struct ViewportOverlay: View {
    let viewport: Viewport
    let study: Study

    var body: some View {
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
                corner([study.displayName, study.patientID, shownDate.map { $0.formatted(date: .numeric, time: .omitted) }], alignment: .leading)
                Spacer()
                corner([study.studyDescription, viewport.source?.title], alignment: .trailing)
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

    /// The date of the study this viewport shows, which may be a prior.
    private var shownDate: Date? {
        if let stack = viewport.baseStack, stack.studyUID != nil { return stack.studyDate }
        return study.studyDate
    }

    private var bottomLeft: [String?] {
        guard viewport.count > 0 else { return [] }
        var lines = [String(localized: "Im \(viewport.index + 1)/\(viewport.count)")]
        if let source = viewport.source as? ReformatSource {
            if source.mode.isProjection { lines.append("\(String(localized: source.mode.title)) \(Int(source.slab)) mm") }
            for warning in source.volume.warnings {
                switch warning {
                case .gaps(let n): lines.append(String(localized: "\(n) gaps between slices"))
                case .unevenSpacing: lines.append(String(localized: "Uneven slice spacing"))
                }
            }
        }
        if let location = viewport.location, viewport.count > 1 {
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

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.close = close
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.close = close }

    final class CatcherView: NSView {
        var close: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "w" else { return event }
                return self.close() ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // The monitor goes away in viewDidMoveToWindow when the view leaves its window.
    }
}
