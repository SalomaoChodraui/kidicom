import CoreGraphics
import Foundation
import KidicomKit
import Synchronization
import SwiftUI
import simd

/// One plane of an oblique MPR as something a viewport can scroll: the
/// index walks along the plane's normal, through the volume.
final class ReformatSource: FrameSource {
    /// Strong, so a picture still loading never outlives its volume. The
    /// space holds no source back, so nothing cycles.
    let space: MPRSpace
    /// 0 acquired plane, 1 and 2 the reformats, as `VolumePlane` orders them.
    let planeIndex: Int
    let id: String
    let modality: String
    let defaultWindow: VOIWindow
    /// Slab thickness in mm and how to combine it (S-022): MIP, MinIP, or mean.
    private(set) var slab: Double = 0
    private(set) var mode: SlabMode = .single
    private var cache: [Int: DecodedSlice] = [:]
    /// Cached indexes, least recently used first.
    private var recent: [Int] = []
    /// About 32 MB of pictures, 8 to 24 of them: scrolling back finds the last ones.
    private static let cacheBytes = 32_000_000

    init(space: MPRSpace, planeIndex: Int, seriesID: String, modality: String, window: VOIWindow) {
        self.space = space
        self.planeIndex = planeIndex
        id = "\(seriesID)#\(planeIndex)"
        self.modality = modality
        defaultWindow = window
    }

    var volume: Volume { space.volume }
    var plane: ObliquePlane { space.planes[planeIndex] }

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

    /// Position along the normal for an index, in volume mm.
    func position(_ index: Int) -> Double { range.start + Double(index) * range.step }

    /// The index whose plane passes through the frame's center.
    var centerIndex: Int {
        let r = range
        return min(max(0, Int(((simd_dot(space.center, plane.normal) - r.start) / r.step).rounded())), r.count - 1)
    }

    func setSlab(_ mm: Double, mode: SlabMode) {
        guard mm != slab || mode != self.mode else { return }
        slab = mm
        self.mode = mode
        invalidate()
    }

    /// Bumped whenever the plane turns or the slab changes, so a picture
    /// computed for an older plane never lands in the cache.
    private(set) var generation = 0

    /// The plane turned: drop pictures of the old one.
    func invalidate() {
        cache = [:]
        recent = []
        generation += 1
    }

    func cached(_ index: Int) -> DecodedSlice? {
        guard let hit = cache[index] else { return nil }
        touch(index)
        return hit
    }

    private func touch(_ index: Int) {
        if let at = recent.lastIndex(of: index) { recent.remove(at: at) }
        recent.append(index)
    }

    private func remember(_ slice: DecodedSlice, at index: Int) {
        cache[index] = slice
        touch(index)
        let limit = min(24, max(8, Self.cacheBytes / max(1, slice.width * slice.height * MemoryLayout<Float>.size)))
        while recent.count > limit { cache[recent.removeFirst()] = nil }
    }

    func load(_ index: Int) async -> DecodedSlice? {
        if let hit = cached(index) { return hit }
        let started = generation
        let image = await Self.render(volume, plane, position(index), slab, mode, space.outside)
        // Cancelled midway (the viewport moved to another series, or the slab changed): the picture is incomplete.
        if Task.isCancelled { return nil }
        let slice = DecodedSlice(frame: .grayscale(image.values), width: image.width, height: image.height, inverted: false,
                                 defaultWindow: defaultWindow, pixelSpacing: image.pixelSpacing,
                                 sliceThickness: mode.isProjection ? slab : nil)
        guard started == generation else { return slice }   // the plane moved meanwhile: show it, don't keep it
        remember(slice, at: index)
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
        let stop = StopFlag()
        return await withTaskCancellationHandler {
            volume.reslice(plane, at: t, slab: slab, mode: mode, outside: outside, isCancelled: { stop.isSet })
        } onCancel: {
            stop.set()
        }
    }
}

/// Set from a task's cancellation handler, read by the reslice's worker threads.
nonisolated private final class StopFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}

/// The volume and the three planes through one point, shared by the
/// reformats of an MPR or a single plane. The center and the planes'
/// directions are observed apart: a scroll moves only the center, so views
/// that read only the directions (plane names, edge letters) stay put.
@Observable
final class MPRSpace {
    let volume: Volume
    let outside: Float
    @ObservationIgnored private var frame: MPRFrame

    init(volume: Volume) {
        self.volume = volume
        frame = MPRFrame(volume: volume)
        outside = volume.floorValue
    }

    /// Where the three planes cross, in volume mm.
    var center: SIMD3<Double> {
        get {
            access(keyPath: \.center)
            return frame.center
        }
        set {
            withMutation(keyPath: \.center) { frame.center = newValue }
        }
    }

    var planes: [ObliquePlane] {
        access(keyPath: \.planes)
        return frame.planes
    }

    var isTilted: Bool {
        access(keyPath: \.planes)
        return frame.isTilted
    }

    func rotate(around fixed: Int, by angle: Double) {
        withMutation(keyPath: \.planes) { frame.rotate(around: fixed, by: angle) }
    }

    func resetRotation() {
        withMutation(keyPath: \.planes) { frame.resetRotation() }
    }
}

/// An MPR session: its space, the three reformats, and what the viewer
/// showed before, to restore on exit. The sources point at the space, never
/// back at the session.
final class MPRSession {
    let space: MPRSpace
    var sources: [ReformatSource] = []
    let seriesID: String
    let previousLayout: ViewerLayout
    let previousSources: [(any FrameSource)?]
    let previousIndexes: [Int]

    var volume: Volume { space.volume }

    init(volume: Volume, seriesID: String, previousLayout: ViewerLayout, previousSources: [(any FrameSource)?], previousIndexes: [Int]) {
        space = MPRSpace(volume: volume)
        self.seriesID = seriesID
        self.previousLayout = previousLayout
        self.previousSources = previousSources
        self.previousIndexes = previousIndexes
    }
}

extension SeriesStack {
    /// Stacks every frame into a volume. The geometry is checked and ordered
    /// first, from the slice positions; then one decode per core fills the
    /// volume, each frame dropped once copied. Frames the viewer already
    /// decoded are reused.
    func buildVolume(progress: @escaping @MainActor (Double) -> Void) async throws -> Volume {
        let refs = slices
        let geometry = refs.map { SliceGeometry(position: $0.position, orientation: $0.orientation) }
        var ready: [Int: SlicePixels] = [:]
        for index in refs.indices {
            if let hit = cached(index), case .grayscale(let values) = hit.frame {
                ready[index] = SlicePixels(values: values, width: hit.width, height: hit.height, pixelSpacing: hit.pixelSpacing)
            }
        }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Self.assemble(geometry, refs, ready, cancelled, progress)
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Runs the blocking build on a GCD queue, off Swift's cooperative threads.
    nonisolated private static func assemble(_ geometry: [SliceGeometry], _ refs: [SliceRef], _ ready: [Int: SlicePixels],
                                             _ cancelled: CancelFlag, _ progress: @escaping @MainActor (Double) -> Void) async throws -> Volume {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Volume.build(geometry: geometry, isCancelled: { cancelled.isCancelled }, progress: { done, total in
                        Task { @MainActor in progress(Double(done) / Double(total)) }
                    }, decode: { index in
                        ready[index] ?? pixels(refs[index])
                    })
                })
            }
        }
    }

    /// Only what a volume needs from a frame: grayscale values, size, and spacing.
    nonisolated private static func pixels(_ ref: SliceRef) -> SlicePixels? {
        guard let file = try? DicomParser.parse(contentsOf: ref.url),
              let descriptor = try? file.pixelDescriptor,
              case .grayscale(let values)? = try? file.frame(ref.frame) else { return nil }
        var spacing = file.dataset.numbers(.pixelSpacing)
        if spacing.count < 2 { spacing = file.dataset.numbers(.imagerPixelSpacing) }
        return SlicePixels(values: values, width: descriptor.columns, height: descriptor.rows, pixelSpacing: spacing)
    }
}

/// Set from a task's cancellation handler, read by the build's threads.
nonisolated final class CancelFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
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
                // Reads the center and the planes, so it redraws when either moves.
                let center = mine.canvasPoint(session.space.center, at: viewport.index)
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
