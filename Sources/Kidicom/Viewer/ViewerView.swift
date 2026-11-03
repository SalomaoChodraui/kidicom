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
            ZStack {
                Color.black
                if let viewport = viewer.active {
                    ViewportView(viewport: viewport, isActive: true) {}
                        .overlay { ViewportOverlay(viewport: viewport, study: study).allowsHitTesting(false) }
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, let stack = viewer.stacks.first(where: { $0.id == id }) else { return false }
                            viewport.show(stack)
                            return true
                        }
                }
            }
        }
        .navigationTitle(study.displayName)
        .navigationSubtitle(study.studyDescription)
        .task(id: study.uid) { viewer.load(study) }
    }
}

@Observable
final class ViewerModel {
    private(set) var stacks: [SeriesStack] = []
    private(set) var viewports: [Viewport] = [Viewport()]
    var activeIndex = 0

    var active: Viewport? { viewports.indices.contains(activeIndex) ? viewports[activeIndex] : nil }

    func load(_ study: Study) {
        guard stacks.isEmpty else { return }
        stacks = study.series.sorted { ($0.number, $0.seriesDescription) < ($1.number, $1.seriesDescription) }
            .map(SeriesStack.init(series:))
            .filter { $0.count > 0 }
        // Start on the series with the most images, not the scout.
        if let main = stacks.max(by: { $0.count < $1.count }) { viewports[0].show(main) }
        for stack in stacks { Task { await stack.makeThumbnail() } }
    }

    func show(_ stack: SeriesStack) {
        active?.show(stack)
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
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 1, x: 0, y: 1)
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
        if let window = viewport.effectiveWindow, viewport.slice?.isColor == false {
            lines.append(String(localized: "WL \(Int(window.center.rounded())) WW \(Int(window.width.rounded()))"))
        }
        lines.append(String(localized: "Zoom \(Int((viewport.zoom * 100).rounded()))%"))
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
