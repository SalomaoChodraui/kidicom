import Foundation
import Testing
@testable import KidicomKit

/// Times a slab reslice on a CT-sized volume. Opt-in: BENCH=1.
@Suite struct SlabBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
    func slabSpeed() {
        let w = 512, h = 512, d = 400
        var voxels = [Float16](repeating: 0, count: w * h * d)
        for i in voxels.indices { voxels[i] = Float16(Float(i % 997)) }
        let volume = Volume(width: w, height: h, depth: d, spacing: (i: 0.7, j: 0.7, k: 0.625), origin: [0, 0, 0],
                            rowDirection: [1, 0, 0], columnDirection: [0, 1, 0], normal: [0, 0, 1],
                            voxels: voxels, warnings: [])
        let frame = MPRFrame(volume: volume)
        for (name, plane) in zip(["axial", "coronal", "sagittal"], frame.planes) {
            for (slab, mode) in [(0.0, SlabMode.single), (10, .mip), (30, .mip), (30, .mean)] {
                let start = Date()
                let runs = 3
                for _ in 0 ..< runs { _ = volume.reslice(plane, at: 100, slab: slab, mode: mode, outside: 0) }
                let ms = Date().timeIntervalSince(start) / Double(runs) * 1000
                print("BENCH \(name) \(mode.rawValue) \(Int(slab))mm: \(Int(ms)) ms")
            }
        }
    }
}
