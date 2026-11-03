import CoreGraphics
import Foundation
import KidicomKit
import SwiftUI
import simd

/// One plane of an oblique MPR as something a viewport can scroll: the
/// index walks along the plane's normal, through the volume.
final class ReformatSource: FrameSource {
    unowned let session: MPRSession
    /// 0 acquired plane, 1 and 2 the reformats, as `VolumePlane` orders them.
    let planeIndex: Int
    let id: String
    let modality: String
    let defaultWindow: VOIWindow
    /// Slab thickness in mm and how to combine it (S-022).
    private(set) var slab: Double = 0
    private(set) var mode: SlabMode = .single
    private var cache: [Int: DecodedSlice] = [:]

    init(session: MPRSession, planeIndex: Int, seriesID: String, modality: String, window: VOIWindow) {
        self.session = session
        self.planeIndex = planeIndex
        id = "\(seriesID)#\(planeIndex)"
        self.modality = modality
        defaultWindow = window
    }

    var volume: Volume { session.volume }
    var plane: ObliquePlane { session.frame.planes[planeIndex] }

    /// Axial, Coronal, Sagittal by the plane's real direction; Oblique once tilted off them.
    var title: String {
        let o = orientation(0)
        return Self.name(PatientPlane(orientation: o))
    }

    static func name(_ plane: PatientPlane) -> String {
        switch plane {
        case .axial: String(localized: "Axial")
        case .coronal: String(localized: "Coronal")
        case .sagittal: String(localized: "Sagittal")
        case .oblique: String(localized: "Oblique")
        }
    }

    private var range: (start: Double, step: Double, count: Int) { volume.obliqueRange(plane.normal) }
    var count: Int { range.count }
    var isMIP: Bool { mode == .mip }

    /// Position along the normal for an index, in volume mm.
    func position(_ index: Int) -> Double { range.start + Double(index) * range.step }

    /// The index whose plane passes through the frame's center.
    var centerIndex: Int {
        let r = range
        return min(max(0, Int(((simd_dot(session.frame.center, plane.normal) - r.start) / r.step).rounded())), r.count - 1)
    }

    func setSlab(_ mm: Double, mip: Bool) {
        slab = mm
        mode = mip ? .mip : .single
        cache = [:]
    }

    /// The plane turned: drop pictures of the old one.
    func invalidate() { cache = [:] }

    func cached(_ index: Int) -> DecodedSlice? { cache[index] }

    func load(_ index: Int) async -> DecodedSlice? {
        if let hit = cache[index] { return hit }
        let image = await Self.render(volume, plane, position(index), slab, mode, session.outside)
        let slice = DecodedSlice(frame: .grayscale(image.values), width: image.width, height: image.height, inverted: false,
                                 defaultWindow: defaultWindow, pixelSpacing: image.pixelSpacing,
                                 sliceThickness: mode == .mip ? slab : nil)
        if cache.count > 8 { cache.removeAll() }
        cache[index] = slice
        return slice
    }

    func prefetch(around index: Int) {}

    func location(_ index: Int) -> Double? {
        let n = plane.normal, t = position(index)
        let point = volume.physicalCenter + (t - simd_dot(volume.physicalCenter, n)) * n
        return simd_dot(volume.patientPoint(point), volume.patientDirection(n))
    }

    func orientation(_ index: Int) -> [Double] {
        let r = volume.patientDirection(plane.across), c = volume.patientDirection(plane.down)
        return [r.x, r.y, r.z, c.x, c.y, c.z]
    }

    func fileURL(_ index: Int) -> URL? { nil }

    /// Canvas pixel of a volume point on this plane at an index.
    func canvasPoint(_ p: SIMD3<Double>, at index: Int) -> SIMD2<Double> {
        volume.canvasPoint(p, on: plane, at: position(index))
    }

    func volumePoint(_ pixel: SIMD2<Double>, at index: Int) -> SIMD3<Double> {
        volume.volumePoint(pixel, on: plane, at: position(index))
    }

    @concurrent
    nonisolated static func render(_ volume: Volume, _ plane: ObliquePlane, _ t: Double, _ slab: Double, _ mode: SlabMode, _ outside: Float) async -> ResliceImage {
        volume.reslice(plane, at: t, slab: slab, mode: mode, outside: outside)
    }
}

/// An MPR session: the volume, the three planes through one point, and
/// what the viewer showed before, to restore on exit.
@Observable
final class MPRSession {
    let volume: Volume
    var frame: MPRFrame
    @ObservationIgnored let outside: Float
    @ObservationIgnored var sources: [ReformatSource] = []
    @ObservationIgnored let seriesID: String
    @ObservationIgnored let previousLayout: ViewerLayout
    @ObservationIgnored let previousSources: [(any FrameSource)?]
    @ObservationIgnored let previousIndexes: [Int]

    init(volume: Volume, seriesID: String, previousLayout: ViewerLayout, previousSources: [(any FrameSource)?], previousIndexes: [Int]) {
        self.volume = volume
        frame = MPRFrame(volume: volume)
        outside = volume.floorValue
        self.seriesID = seriesID
        self.previousLayout = previousLayout
        self.previousSources = previousSources
        self.previousIndexes = previousIndexes
    }
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

/// Reference lines of the other two MPR planes over a viewport: they cross
/// at the frame's center. Drag a line to tilt, drag the crossing to move.
struct CrosshairOverlay: View {
    let viewer: ViewerModel
    let viewport: Viewport

    var body: some View {
        GeometryReader { proxy in
            if let session = viewer.mpr, let mine = viewport.source as? ReformatSource,
               let geometry = viewport.geometry(in: proxy.size) {
                let _ = session.frame   // redraw when the planes move
                let center = mine.canvasPoint(session.frame.center, at: viewport.index)
                let reach = Double(max(mine.plane.width, mine.plane.height)) * 2
                ForEach(session.sources.filter { $0 !== mine }, id: \.planeIndex) { other in
                    let d = ViewerModel.lineDirection(of: other, in: mine)
                    let a = CGPoint(x: center.x - d.x * reach, y: center.y - d.y * reach)
                    let b = CGPoint(x: center.x + d.x * reach, y: center.y + d.y * reach)
                    Path { path in
                        path.move(to: geometry.toView(a))
                        path.addLine(to: geometry.toView(b))
                    }
                    .stroke(CrosshairOverlay.color(other.planeIndex).opacity(0.85), lineWidth: 1)
                }
                Circle()
                    .stroke(.white.opacity(0.7), lineWidth: 1)
                    .frame(width: Space.md, height: Space.md)
                    .position(geometry.toView(CGPoint(x: center.x, y: center.y)))  // grid: ok drawn in image coordinates
            }
        }
        .allowsHitTesting(false)
    }

    static func color(_ planeIndex: Int) -> Color {
        switch planeIndex {
        case 0: .yellow
        case 1: .green
        default: .cyan
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
