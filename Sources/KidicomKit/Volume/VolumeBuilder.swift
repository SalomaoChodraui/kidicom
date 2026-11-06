import Foundation
import Synchronization

/// Where one slice sits, known before its pixels are decoded.
public struct SliceGeometry: Sendable {
    /// Image Position (Patient) of the first pixel, in mm.
    public var position: [Double]
    /// Image Orientation (Patient): row then column direction cosines.
    public var orientation: [Double]

    public init(position: [Double], orientation: [Double]) {
        self.position = position
        self.orientation = orientation
    }
}

/// The decoded pixels of one slice, for `Volume.build(geometry:decode:)`.
public struct SlicePixels: Sendable {
    public var values: [Float]
    public var width: Int
    public var height: Int
    /// Pixel Spacing: row spacing, then column spacing, in mm.
    public var pixelSpacing: [Double]

    public init(values: [Float], width: Int, height: Int, pixelSpacing: [Double]) {
        self.values = values
        self.width = width
        self.height = height
        self.pixelSpacing = pixelSpacing
    }
}

/// Order, spacing, and warnings of a stack of slices, from geometry alone,
/// with the same rules as `Volume.build(_:)`.
public struct VolumePlan: Sendable, Equatable {
    /// Input indexes in volume order, lowest position first, duplicates dropped.
    public let order: [Int]
    public let row: [Double]
    public let column: [Double]
    public let normal: [Double]
    /// mm between slices: the median gap.
    public let step: Double
    public let warnings: [VolumeWarning]

    public init(_ geometry: [SliceGeometry]) throws {
        guard geometry.count >= 3 else { throw VolumeError.tooFewSlices(geometry.count) }
        guard let first = geometry.first, first.orientation.count == 6,
              geometry.allSatisfy({ $0.position.count == 3 && $0.orientation.count == 6 }) else {
            throw VolumeError.missingGeometry
        }
        let row = Array(first.orientation[0 ..< 3]), column = Array(first.orientation[3 ..< 6])
        let normal = Volume.cross(row, column)
        if geometry.contains(where: {
            !Volume.sameDirection(Array($0.orientation[0 ..< 3]), row) || !Volume.sameDirection(Array($0.orientation[3 ..< 6]), column)
        }) {
            throw VolumeError.mixedOrientations
        }

        let sorted = geometry.indices.sorted { Volume.dot(geometry[$0].position, normal) < Volume.dot(geometry[$1].position, normal) }
        let sortedLocations = sorted.map { Volume.dot(geometry[$0].position, normal) }
        let kept = sorted.indices.filter { $0 == 0 || abs(sortedLocations[$0] - sortedLocations[$0 - 1]) > 1e-3 }
        guard kept.count >= 3 else { throw VolumeError.tooFewSlices(kept.count) }

        let locations = kept.map { sortedLocations[$0] }
        let gaps = zip(locations.dropFirst(), locations).map { $0 - $1 }
        let step = gaps.sorted()[gaps.count / 2]
        var warnings: [VolumeWarning] = []
        let missing = gaps.filter { $0 > step * 1.5 }.count
        if missing > 0 {
            warnings.append(.gaps(missing))
        } else if gaps.contains(where: { abs($0 - step) > step * 0.1 }) {
            warnings.append(.unevenSpacing)
        }
        order = kept.map { sorted[$0] }
        self.row = row
        self.column = column
        self.normal = normal
        self.step = step
        self.warnings = warnings
    }
}

public extension Volume {
    /// Builds a volume without holding every decoded slice at once: the
    /// geometry is checked and ordered first, the Float16 voxels are
    /// allocated once, and `workers` threads decode and copy one slice each,
    /// dropping its Float pixels right after. Same result and rules as
    /// `build(_:)`; a slice `decode` can't read is left out, as there.
    ///
    /// Blocks the calling thread; run it off the main thread.
    static func build(
        geometry: [SliceGeometry],
        workers: Int = ProcessInfo.processInfo.activeProcessorCount,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in },
        decode: @Sendable (Int) -> SlicePixels?
    ) throws -> Volume {
        var unreadable = Set<Int>()
        while true {
            let kept = geometry.indices.filter { !unreadable.contains($0) }
            let plan = try VolumePlan(kept.map { geometry[$0] })
            let order = plan.order.map { kept[$0] }
            switch try fill(plan, order: order, geometry: geometry, workers: workers,
                            isCancelled: isCancelled, progress: progress, decode: decode) {
            case .built(let volume):
                return volume
            case .unreadable(let failed):
                // Some slices didn't decode: plan again without them, as `build(_:)` would.
                unreadable.formUnion(failed)
            }
        }
    }

    private enum Pass {
        case built(Volume)
        /// Input indexes of slices that didn't decode.
        case unreadable([Int])
    }

    /// One pass over the plan.
    private static func fill(
        _ plan: VolumePlan, order: [Int], geometry: [SliceGeometry], workers: Int,
        isCancelled: @Sendable () -> Bool, progress: @Sendable (Int, Int) -> Void,
        decode: @Sendable (Int) -> SlicePixels?
    ) throws -> Pass {
        let total = order.count
        let failed = Mutex<[Int]>([])
        // The first readable slice sets the size; slices before it failed.
        var start = 0
        var first: SlicePixels?
        while start < total {
            if isCancelled() { throw CancellationError() }
            if let pixels = decode(order[start]) { first = pixels; break }
            failed.withLock { $0.append(order[start]) }
            start += 1
        }
        guard let first else { return .unreadable(failed.withLock { $0 }) }
        let width = first.width, height = first.height, plane = width * height
        guard first.values.count >= plane else { throw VolumeError.mixedSizes }

        let next = Atomic<Int>(start + 1)
        let done = Atomic<Int>(start + 1)
        let wrongSize = Atomic<Bool>(false)
        let stopped = Atomic<Bool>(false)
        var anyFailed = start > 0
        let voxels = try [Float16](unsafeUninitializedCapacity: plane * total) { buffer, initialized in
            initialized = 0
            guard let base = buffer.baseAddress else { return }
            nonisolated(unsafe) let out = base
            Self.convert(first.values, into: out + start * plane, count: plane)
            progress(start + 1, total)
            DispatchQueue.concurrentPerform(iterations: max(1, min(workers, total - start - 1))) { _ in
                while true {
                    if wrongSize.load(ordering: .relaxed) || stopped.load(ordering: .relaxed) { return }
                    if isCancelled() { stopped.store(true, ordering: .relaxed); return }
                    let k = next.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard k < total else { return }
                    guard let pixels = decode(order[k]) else {
                        failed.withLock { $0.append(order[k]) }
                        continue
                    }
                    guard pixels.width == width, pixels.height == height, pixels.values.count >= plane else {
                        wrongSize.store(true, ordering: .relaxed)
                        return
                    }
                    Self.convert(pixels.values, into: out + k * plane, count: plane)
                    let finished = done.wrappingAdd(1, ordering: .relaxed).newValue
                    if finished % 8 == 0 || finished == total { progress(finished, total) }
                }
            }
            if stopped.load(ordering: .relaxed) { throw CancellationError() }
            if wrongSize.load(ordering: .relaxed) { throw VolumeError.mixedSizes }
            anyFailed = anyFailed || !failed.withLock { $0.isEmpty }
            // Slots before `start` (and of failed slices) were never written: keep the array empty then.
            if !anyFailed { initialized = plane * total }
        }
        if anyFailed { return .unreadable(failed.withLock { $0 }) }

        // Every slice decoded, so `first` is the lowest one, at k = 0.
        let spacing = first.pixelSpacing.count >= 2 ? first.pixelSpacing : [1, 1]
        return .built(Volume(
            width: width, height: height, depth: total,
            spacing: (i: spacing[1], j: spacing[0], k: plan.step),
            origin: geometry[order[0]].position, rowDirection: plan.row, columnDirection: plan.column, normal: plan.normal,
            voxels: voxels, warnings: plan.warnings
        ))
    }

    @inline(__always)
    private static func convert(_ values: [Float], into out: UnsafeMutablePointer<Float16>, count: Int) {
        values.withUnsafeBufferPointer { source in
            guard let source = source.baseAddress else { return }
            for p in 0 ..< count { out[p] = Float16(source[p]) }
        }
    }
}
