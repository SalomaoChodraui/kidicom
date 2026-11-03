import KidicomKit
import SwiftData
import SwiftUI

/// The viewer window for one study: the series strip and the viewport.
struct ViewerView: View {
    let studyUID: UUID
    @Query private var studies: [Study]
    @State private var viewer = ViewerModel()

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
            SeriesStrip(viewer: viewer)
                .frame(width: 148)
            Divider()
            ViewportGrid(viewer: viewer, study: study)
        }
        .inspector(isPresented: Bindable(viewer).showsTags) {
            TagInspector(viewport: viewer.active)
                .inspectorColumnWidth(min: 400, ideal: 600, max: 1000)
        }
        .toolbar {
            ToolbarItem {
                Picker("Tool", selection: Bindable(viewer).tool) {
                    ForEach(MeasureTool.allCases) { tool in
                        Label { Text(tool.title) } icon: { Image(systemName: tool.symbol) }.tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Left button: window/level, measure a distance, or measure an angle (Esc returns to window/level)")
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
                Menu {
                    Button("Rotate Right") { viewer.active?.rotate(clockwise: true) }
                    Button("Rotate Left") { viewer.active?.rotate(clockwise: false) }
                    Divider()
                    Button("Flip Horizontal") { viewer.active?.flip(horizontal: true) }
                    Button("Flip Vertical") { viewer.active?.flip(horizontal: false) }
                    Divider()
                    Button("Reset View") { viewer.active?.reset() }
                } label: {
                    Label("Orientation", systemImage: "rotate.right")
                }
                .help("Rotate or flip the active viewport (R, Shift-R, H, V)")
            }
            ToolbarItem {
                Button("DICOM Tags", systemImage: "info.circle") { viewer.showsTags.toggle() }
                    .keyboardShortcut("i")
                    .help("Show the DICOM tags of the image (⌘I)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: Bindable(viewer).layout) {
                    ForEach(ViewerLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Split the image area into up to four viewports")
            }
        }
        .navigationTitle(study.displayName)
        .navigationSubtitle(study.studyDescription)
        .task(id: study.uid) { viewer.load(study) }
    }
}

/// Thumbnails of the study's series. Click shows one; drag it to a viewport.
struct SeriesStrip: View {
    let viewer: ViewerModel

    var body: some View {
        ScrollView {
            VStack(spacing: Space.sm) {
                ForEach(viewer.stacks) { stack in
                    Button { viewer.show(stack) } label: {
                        SeriesThumbnail(stack: stack, isShown: viewer.active?.stack?.id == stack.id)
                    }
                    .buttonStyle(.plain)
                    .draggable(stack.id)
                    .help(Text("Show \(stack.title) (\(stack.count) images)"))
                }
            }
            .padding(Space.sm)
        }
        .background(.background.secondary)
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
                corner([study.displayName, study.patientID, study.studyDate.map { $0.formatted(date: .numeric, time: .omitted) }], alignment: .leading)
                Spacer()
                corner([study.studyDescription, viewport.stack?.title], alignment: .trailing)
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

    private var bottomLeft: [String?] {
        guard viewport.count > 0 else { return [] }
        var lines = [String(localized: "Im \(viewport.index + 1)/\(viewport.count)")]
        if let location = viewport.location, viewport.count > 1 {
            lines.append(String(localized: "Pos \(location.formatted(.number.precision(.fractionLength(1)))) mm"))
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
