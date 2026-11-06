import Foundation
import Testing
import simd
@testable import KidicomKit

/// Times the oblique reslice the app uses on a CT-sized volume, against the
/// plain loop it replaced (ResliceReference.swift). Opt-in:
/// `BENCH=1 swift test -c release --filter SlabBenchmark`.
@Suite struct SlabBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["BENCH"] == "1"

    @Test(.enabled(if: SlabBenchmark.enabled))
    func slabSpeed() {
        // BENCH_W=500 shows the cost of slices a power of two apart (512 x 512),
        // which share cache sets: an axial plane tilted 30 degrees runs 2.5 times faster.
        let w = Int(ProcessInfo.processInfo.environment["BENCH_W"] ?? "") ?? 512, h = 512, d = 400
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
                func run(_ reference: Bool) -> Double {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let image = reference
                        ? volume.referenceReslice(plane, at: t, slab: slab, mode: mode, outside: 0)
                        : volume.reslice(plane, at: t, slab: slab, mode: mode, outside: 0)
                    let ns = DispatchTime.now().uptimeNanoseconds - start
                    // Touch the pixels so the work cannot be optimized away.
                    for i in stride(from: 0, to: image.values.count, by: 61) { checksum += Double(image.values[i]) }
                    return Double(ns) / 1e6
                }
                for _ in 0 ..< 3 { _ = run(true); _ = run(false) }
                // Interleaved, so both see the same machine load.
                var before: [Double] = [], after: [Double] = []
                for _ in 0 ..< 15 { before.append(run(true)); after.append(run(false)) }
                func stats(_ times: [Double]) -> (median: Double, p90: Double) {
                    let t = times.sorted()
                    return (t[t.count / 2], t[Int(Double(t.count - 1) * 0.9)])
                }
                let b = stats(before), a = stats(after)
                let label = "\(name) \(mode.rawValue)\(mode == .single ? "" : String(Int(slab)))"
                print("BENCH", label.padding(toLength: 20, withPad: " ", startingAt: 0),
                      String(format: "before %7.2f ms (p90 %7.2f)  after %7.2f ms (p90 %7.2f)  %5.1fx", b.median, b.p90, a.median, a.p90, b.median / a.median))
            }
        }
        print("BENCH checksum \(checksum)")
        #expect(checksum > 0)
    }
}
