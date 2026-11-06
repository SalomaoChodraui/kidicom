import Foundation
import Testing
import simd
@testable import KidicomKit

/// Times the oblique reslice the app uses on a CT-sized volume. Opt-in:
/// `BENCH=1 swift test -c release --filter SlabBenchmark`.
@Suite struct SlabBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["BENCH"] == "1"

    @Test(.enabled(if: SlabBenchmark.enabled))
    func slabSpeed() {
        let w = 512, h = 512, d = 400
        var voxels = [Float16](repeating: 0, count: w * h * d)
        for i in voxels.indices { voxels[i] = Float16(Float(i % 997)) }
        let volume = Volume(width: w, height: h, depth: d, spacing: (i: 0.7, j: 0.7, k: 0.625), origin: [0, 0, 0],
                            rowDirection: [1, 0, 0], columnDirection: [0, 1, 0], normal: [0, 0, 1],
                            voxels: voxels, warnings: [])
        let straight = MPRFrame(volume: volume)
        var aroundAxial = straight
        aroundAxial.rotate(around: 0, by: .pi / 6)      // coronal and sagittal tilt 30 degrees
        var aroundCoronal = straight
        aroundCoronal.rotate(around: 1, by: .pi / 6)    // axial tilts 30 degrees
        let planes: [(String, ObliquePlane)] = [
            ("axial", straight.planes[0]), ("coronal", straight.planes[1]), ("sagittal", straight.planes[2]),
            ("axial30", aroundCoronal.planes[0]), ("coronal30", aroundAxial.planes[1]), ("sagittal30", aroundAxial.planes[2]),
        ]
        let modes: [(Double, SlabMode)] = [(0, .single), (10, .mip), (30, .mip), (30, .mean)]
        var checksum: Double = 0
        for (name, plane) in planes {
            // The middle of the volume, so every sample lands inside.
            let t = simd_dot(volume.physicalCenter, plane.normal)
            for (slab, mode) in modes {
                func run() -> Double {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let image = volume.reslice(plane, at: t, slab: slab, mode: mode, outside: 0)
                    let ns = DispatchTime.now().uptimeNanoseconds - start
                    // Touch the pixels so the work cannot be optimized away.
                    for i in stride(from: 0, to: image.values.count, by: 61) { checksum += Double(image.values[i]) }
                    return Double(ns) / 1e6
                }
                for _ in 0 ..< 3 { _ = run() }
                let times = (0 ..< 15).map { _ in run() }.sorted()
                let median = times[times.count / 2], p90 = times[Int(Double(times.count - 1) * 0.9)]
                let label = "\(name) \(mode.rawValue)\(mode == .single ? "" : String(Int(slab)))"
                print("BENCH", label.padding(toLength: 20, withPad: " ", startingAt: 0),
                      String(format: "median %7.2f ms  p90 %7.2f ms  max %7.2f ms", median, p90, times.last ?? 0))
            }
        }
        print("BENCH checksum \(checksum)")
        #expect(checksum > 0)
    }
}
