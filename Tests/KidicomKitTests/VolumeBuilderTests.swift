import Darwin
import Foundation
import Synchronization
import Testing
@testable import KidicomKit

@Suite("Volume builder")
struct VolumeBuilderTests {
    let axial = [1.0, 0, 0, 0, 1, 0]

    /// A 4x3 image per slice whose value encodes the input order and pixel.
    func slices(_ zs: [Double]) -> [VolumeSlice] {
        zs.enumerated().map { n, z in
            VolumeSlice(values: (0 ..< 12).map { Float(100 * n + $0) }, width: 4, height: 3,
                        position: [0, 0, z], orientation: axial, pixelSpacing: [2, 1])
        }
    }

    func incremental(_ input: [VolumeSlice], workers: Int = 4, unreadable: Set<Int> = []) throws -> Volume {
        try Volume.build(geometry: input.map { SliceGeometry(position: $0.position, orientation: $0.orientation) }, workers: workers) { i in
            unreadable.contains(i) ? nil
                : SlicePixels(values: input[i].values, width: input[i].width, height: input[i].height, pixelSpacing: input[i].pixelSpacing)
        }
    }

    func same(_ a: Volume, _ b: Volume) -> Bool {
        a.width == b.width && a.height == b.height && a.depth == b.depth && a.spacing == b.spacing && a.origin == b.origin
            && a.rowDirection == b.rowDirection && a.columnDirection == b.columnDirection && a.normal == b.normal
            && a.voxels == b.voxels && a.warnings == b.warnings
    }

    @Test("Builds the same volume as Volume.build, in any input order", arguments: [
        [0.0, 3, 6, 9], [9.0, 0, 6, 3], [0.0, 3, 6, 15, 18], [0.0, 3, 6.5, 9], [5.0, 4, 3, 2, 1, 0, 7, 6],
    ])
    func matches(_ zs: [Double]) throws {
        let input = slices(zs)
        for workers in [1, 3, 8] {
            #expect(same(try incremental(input, workers: workers), try Volume.build(input)))
        }
    }

    @Test("Duplicate positions keep one slice, as Volume.build does")
    func duplicates() throws {
        let input = slices([0, 3, 3, 6, 9])
        let built = try incremental(input)
        #expect(built.depth == 4)
        #expect(built.warnings == (try Volume.build(input)).warnings)
    }

    @Test("Slices that don't decode are left out, like before")
    func unreadable() throws {
        let input = slices([0, 3, 6, 9, 12])
        let built = try incremental(input, unreadable: [1, 4])
        let reference = try Volume.build([input[0], input[2], input[3]])
        #expect(same(built, reference))
        // The lowest slice failing still works: the next one sets the size.
        #expect(same(try incremental(input, unreadable: [0]), try Volume.build(Array(input.dropFirst()))))
        #expect(throws: VolumeError.tooFewSlices(2)) { try incremental(input, unreadable: [0, 1, 2]) }
    }

    @Test("Geometry errors come before any decoding")
    func refused() {
        var mixed = slices([0, 3, 6])
        mixed[1].orientation = [0, 1, 0, 0, 0, -1]
        #expect(throws: VolumeError.mixedOrientations) { try incremental(mixed) }
        #expect(throws: VolumeError.tooFewSlices(2)) { try incremental(slices([0, 3])) }
        var missing = slices([0, 3, 6])
        missing[2].position = []
        #expect(throws: VolumeError.missingGeometry) { try incremental(missing) }
        var sizes = slices([0, 3, 6, 9])
        sizes[2] = VolumeSlice(values: [Float](repeating: 0, count: 20), width: 5, height: 4, position: [0, 0, 6], orientation: axial, pixelSpacing: [2, 1])
        #expect(throws: VolumeError.mixedSizes) { try incremental(sizes) }
    }

    @Test("Cancelling stops the build")
    func cancelled() {
        let input = slices((0 ..< 40).map(Double.init))
        let calls = Atomic<Int>(0)
        #expect(throws: CancellationError.self) {
            try Volume.build(geometry: input.map { SliceGeometry(position: $0.position, orientation: $0.orientation) }, workers: 2,
                             isCancelled: { calls.load(ordering: .relaxed) > 5 }) { i in
                calls.add(1, ordering: .relaxed)
                return SlicePixels(values: input[i].values, width: 4, height: 3, pixelSpacing: [2, 1])
            }
        }
        #expect(calls.load(ordering: .relaxed) < 40)
    }
}

/// Peak memory and time of building a 512x512x400 volume, the old way (every
/// slice decoded and kept, then stacked) and the incremental way. Opt-in: BENCH=1.
@Suite struct VolumeBuildBenchmark {
    static let w = 512, h = 512, d = 400

    /// A stand-in for decoding: a fresh Float array per slice, as the decoder makes.
    static func decode(_ k: Int) -> [Float] {
        var values = [Float](repeating: 0, count: w * h)
        for p in values.indices { values[p] = Float((p &+ k * 31) % 2000) - 1000 }
        return values
    }

    /// Current and lifetime-peak physical footprint of this process, in bytes.
    static func footprint() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak)) : (0, 0)
    }

    /// Runs `work`; returns the footprint peak above the start in MiB, and seconds.
    /// The peak is the process's lifetime peak, so run one path per process (BENCH_PATH).
    static func measure(_ work: () throws -> Volume) rethrows -> (peak: Int, seconds: Double, depth: Int) {
        let base = footprint().now
        let start = Date()
        let volume = try work()
        let seconds = Date().timeIntervalSince(start)
        return ((footprint().peak - base) >> 20, seconds, volume.depth)
    }

    /// BENCH_PATH=old or new picks one path; without it both run and only the time compares.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
    func peakMemory() throws {
        let geometry = (0 ..< Self.d).map { SliceGeometry(position: [0, 0, Double($0) * 0.625], orientation: [1, 0, 0, 0, 1, 0]) }
        let path = ProcessInfo.processInfo.environment["BENCH_PATH"]
        if path != "old" {
            let new = try Self.measure {
                try Volume.build(geometry: geometry.reversed()) { k in
                    SlicePixels(values: Self.decode(Self.d - 1 - k), width: Self.w, height: Self.h, pixelSpacing: [0.7, 0.7])
                }
            }
            print("BENCH volume build new: peak +\(new.peak) MiB, \(Int(new.seconds * 1000)) ms, depth \(new.depth)")
        }
        if path != "new" {
            // The old path: every slice decoded in parallel and kept, then stacked.
            let old = try Self.measure {
                let decoded = Mutex<[VolumeSlice]>([])
                DispatchQueue.concurrentPerform(iterations: Self.d) { k in
                    let slice = VolumeSlice(values: Self.decode(k), width: Self.w, height: Self.h, position: geometry[k].position,
                                            orientation: geometry[k].orientation, pixelSpacing: [0.7, 0.7])
                    decoded.withLock { $0.append(slice) }
                }
                return try Volume.build(decoded.withLock { $0 })
            }
            print("BENCH volume build old: peak +\(old.peak) MiB, \(Int(old.seconds * 1000)) ms, depth \(old.depth)")
        }
    }
}
