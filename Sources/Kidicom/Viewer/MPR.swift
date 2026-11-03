import CoreGraphics
import Foundation
import KidicomKit
import SwiftUI

/// One plane of a volume as something a viewport can scroll.
final class ReformatSource: FrameSource {
    let volume: Volume
    let plane: VolumePlane
    let id: String
    let title: String
    let modality: String
    let defaultWindow: VOIWindow
    /// Slab thickness in mm and how to combine it (S-022).
    private(set) var slab: Double = 0
    private(set) var mode: SlabMode = .single
    private var cache: [Int: DecodedSlice] = [:]

    init(volume: Volume, plane: VolumePlane, seriesID: String, modality: String, window: VOIWindow) {
        self.volume = volume
        self.plane = plane
        id = "\(seriesID)#\(plane.rawValue)"
        self.modality = modality
        defaultWindow = window
        title = Self.name(PatientPlane(orientation: volume.orientation(plane)))
    }

    static func name(_ plane: PatientPlane) -> String {
        switch plane {
        case .axial: String(localized: "Axial")
        case .coronal: String(localized: "Coronal")
        case .sagittal: String(localized: "Sagittal")
        case .oblique: String(localized: "Oblique")
        }
    }

    var count: Int { volume.count(plane) }
    var isMIP: Bool { mode == .mip }

    func setSlab(_ mm: Double, mip: Bool) {
        slab = mm
        mode = mip ? .mip : .single
        cache = [:]
    }

    func cached(_ index: Int) -> DecodedSlice? { cache[index] }

    func load(_ index: Int) async -> DecodedSlice? {
        if let hit = cache[index] { return hit }
        let image = await Self.render(volume, plane, index, slab, mode)
        let slice = DecodedSlice(frame: .grayscale(image.values), width: image.width, height: image.height, inverted: false,
                                 defaultWindow: defaultWindow, pixelSpacing: image.pixelSpacing,
                                 sliceThickness: mode == .mip ? slab : nil)
        if cache.count > 8 { cache.removeAll() }
        cache[index] = slice
        return slice
    }

    func prefetch(around index: Int) {}
    func location(_ index: Int) -> Double? { volume.location(plane, at: index) }
    func orientation(_ index: Int) -> [Double] { volume.orientation(plane) }
    func fileURL(_ index: Int) -> URL? { nil }

    @concurrent
    nonisolated static func render(_ volume: Volume, _ plane: VolumePlane, _ index: Int, _ slab: Double, _ mode: SlabMode) async -> ResliceImage {
        volume.reslice(plane, at: index, slab: slab, mode: mode)
    }
}

/// An MPR session: the volume, its three planes, and what the viewer
/// showed before, to restore on exit.
struct MPRSession {
    let volume: Volume
    let sources: [ReformatSource]
    let previousLayout: ViewerLayout
    let previousSources: [(any FrameSource)?]
    let previousIndexes: [Int]
}

extension SeriesStack {
    /// Decodes every frame and stacks them into a volume.
    func buildVolume(progress: @escaping @MainActor (Double) -> Void) async throws -> Volume {
        let refs = slices
        let total = refs.count
        var done = 0
        let built: [VolumeSlice] = await withTaskGroup(of: VolumeSlice?.self) { group in
            for ref in refs {
                group.addTask {
                    guard let decoded = await SeriesStack.decode(ref), case .grayscale(let values) = decoded.frame else { return nil }
                    return VolumeSlice(values: values, width: decoded.width, height: decoded.height, position: ref.position,
                                       orientation: ref.orientation, pixelSpacing: decoded.pixelSpacing)
                }
            }
            var out: [VolumeSlice] = []
            for await slice in group {
                if let slice { out.append(slice) }
                done += 1
                if done % 16 == 0 { progress(Double(done) / Double(total)) }
            }
            return out
        }
        return try await Self.stack(built)
    }

    @concurrent
    nonisolated static func stack(_ slices: [VolumeSlice]) async throws -> Volume {
        try Volume.build(slices)
    }
}

/// Reference lines of the other MPR planes over a viewport.
struct CrosshairOverlay: View {
    let viewer: ViewerModel
    let viewport: Viewport

    var body: some View {
        GeometryReader { proxy in
            if let session = viewer.mpr, let mine = viewport.source as? ReformatSource,
               let geometry = viewport.geometry(in: proxy.size) {
                ForEach(Array(session.sources.enumerated()), id: \.offset) { index, other in
                    if other !== mine, let line = session.volume.line(of: other.plane, at: viewer.viewports[index].index, in: mine.plane) {
                        let (a, b) = endpoints(line, geometry)
                        Path { path in
                            path.move(to: geometry.toView(a))
                            path.addLine(to: geometry.toView(b))
                        }
                        .stroke(CrosshairOverlay.color(other.plane).opacity(0.8), lineWidth: 1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func endpoints(_ line: (vertical: Bool, position: Double), _ g: ViewportGeometry) -> (CGPoint, CGPoint) {
        let p = CGFloat(line.position)
        return line.vertical
            ? (CGPoint(x: p, y: 0), CGPoint(x: p, y: g.imageSize.height))
            : (CGPoint(x: 0, y: p), CGPoint(x: g.imageSize.width, y: p))
    }

    static func color(_ plane: VolumePlane) -> Color {
        switch plane {
        case .native: .yellow
        case .alongRows: .green
        case .alongColumns: .cyan
        }
    }
}

/// Slab thickness and MIP for the active reformatted viewport.
struct SlabControls: View {
    let source: ReformatSource
    let viewport: Viewport
    @State private var mip = false
    @State private var thickness = 10.0

    var body: some View {
        Form {
            Toggle("Maximum Intensity Projection (MIP)", isOn: $mip)
            LabeledContent("Thickness") {
                HStack {
                    Slider(value: $thickness, in: 1 ... 50, step: 1)
                        .frame(width: 180)
                    Text("\(Int(thickness)) mm").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            .disabled(!mip)
        }
        .padding(Space.lg)
        .onAppear {
            mip = source.isMIP
            if source.slab > 0 { thickness = source.slab }
        }
        .onChange(of: mip) { apply() }
        .onChange(of: thickness) { apply() }
    }

    private func apply() {
        source.setSlab(thickness, mip: mip)
        viewport.reload()
    }
}
