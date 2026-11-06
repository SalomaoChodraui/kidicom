import Foundation
import Testing
import simd
@testable import KidicomKit

/// The fast reslice kernels against the plain loop in ResliceReference.swift.
@Suite("Reslice kernels")
struct ResliceKernelTests {
    /// A small volume with uneven sizes and spacing and values that change
    /// in every direction, so a wrong neighbor or fraction shows.
    static func volume(spacing: (i: Double, j: Double, k: Double) = (0.7, 0.9, 1.3)) -> Volume {
        let w = 23, h = 19, d = 17
        var voxels = [Float16](repeating: 0, count: w * h * d)
        for k in 0 ..< d {
            for j in 0 ..< h {
                for i in 0 ..< w {
                    let v = 400 * sin(Double(i) * 0.7 + Double(j) * 0.3) + 300 * cos(Double(k) * 0.9 - Double(i) * 0.2) + Double((i * 7 + j * 13 + k * 29) % 50)
                    voxels[(k * h + j) * w + i] = Float16(Float(v))
                }
            }
        }
        return Volume(width: w, height: h, depth: d, spacing: spacing, origin: [-10, 20, 5],
                      rowDirection: [1, 0, 0], columnDirection: [0, 1, 0], normal: [0, 0, 1], voxels: voxels, warnings: [])
    }

    /// Straight planes, then planes turned by several angles around each
    /// axis and around two axes at once.
    static func frames(_ volume: Volume) -> [(String, MPRFrame)] {
        let straight = MPRFrame(volume: volume)
        var out = [("straight", straight)]
        for axis in 0 ..< 3 {
            for degrees in [1.0, 30, 45, 90, 137] {
                var f = straight
                f.rotate(around: axis, by: degrees * .pi / 180)
                out.append(("turned \(Int(degrees)) around \(axis)", f))
            }
        }
        var double = straight
        double.rotate(around: 0, by: 0.4)
        double.rotate(around: 1, by: -0.7)
        out.append(("double oblique", double))
        return out
    }

    /// Positions along the normal: the middle, slice positions the viewer
    /// scrolls through (which land on voxel centers), both edges, and past
    /// both ends.
    static func positions(_ volume: Volume, _ plane: ObliquePlane) -> [Double] {
        let range = volume.obliqueRange(plane.normal)
        let mid = simd_dot(volume.physicalCenter, plane.normal)
        let every = max(1, range.count / 5)
        let scroll = (Array(stride(from: 0, to: range.count, by: every)) + [1, range.count - 1]).map { range.start + Double($0) * range.step }
        return [mid, mid + 0.37, range.start - range.step * 3, range.start + range.step * (Double(range.count) + 2)] + scroll
    }

    static let slabs: [(Double, SlabMode)] = [(0, .single), (3, .mip), (10, .mip), (3, .minip), (10, .minip), (3, .mean), (10, .mean), (40, .mean)]

    func compare(_ volume: Volume) {
        var worst: Float = 0, images = 0
        // A few Float roundings of the data range: the kernels may interpolate
        // the axes in another order than the plain loop.
        let range = volume.voxels.map { abs(Float($0)) }.max() ?? 1
        let tolerance = 1e-5 * range
        for (name, frame) in Self.frames(volume) {
            for plane in frame.planes {
                for t in Self.positions(volume, plane) {
                    for (slab, mode) in Self.slabs {
                        let fast = volume.reslice(plane, at: t, slab: slab, mode: mode, outside: -5000)
                        let reference = volume.referenceReslice(plane, at: t, slab: slab, mode: mode, outside: -5000)
                        images += 1
                        #expect(fast.width == reference.width && fast.height == reference.height)
                        #expect(fast.orientation == reference.orientation && fast.position == reference.position)
                        #expect(fast.location == reference.location && fast.pixelSpacing == reference.pixelSpacing)
                        var edges = 0
                        var diff: Float = 0
                        for (a, b) in zip(fast.values, reference.values) {
                            if (a == -5000) != (b == -5000) { edges += 1 }
                            diff = max(diff, abs(a - b))
                        }
                        worst = max(worst, diff)
                        #expect(edges == 0, "\(name) t=\(t) \(mode) \(slab): \(edges) pixels inside in one and outside in the other")
                        #expect(diff <= tolerance, "\(name) t=\(t) \(mode) \(slab): differs by \(diff)")
                    }
                }
            }
        }
        #expect(images > 500)
        print("Reslice kernels: \(images) images, worst difference \(worst) of \(range)")
    }

    @Test("Straight and tilted planes match the plain loop in every mode")
    func matchesReference() {
        compare(Self.volume())
    }

    @Test("Isotropic voxels, where slab steps land exactly on slices, match too")
    func matchesReferenceIsotropic() {
        compare(Self.volume(spacing: (1, 1, 1)))
    }

    @Test("Tilted planes give exactly the plain loop's values")
    func tiltedExact() {
        let volume = Self.volume()
        var frame = MPRFrame(volume: volume)
        frame.rotate(around: 0, by: 0.5)
        frame.rotate(around: 2, by: 0.3)
        for plane in frame.planes {
            let t = simd_dot(volume.physicalCenter, plane.normal)
            for (slab, mode) in Self.slabs {
                let fast = volume.reslice(plane, at: t, slab: slab, mode: mode, outside: 0)
                let reference = volume.referenceReslice(plane, at: t, slab: slab, mode: mode, outside: 0)
                #expect(fast.values == reference.values)
            }
        }
    }

    @Test("A cancelled reslice stops and asks no more than once per row on each core")
    func cancellation() {
        let volume = Self.volume()
        let frame = MPRFrame(volume: volume)
        var tilted = frame
        tilted.rotate(around: 0, by: 0.5)
        let asked = Counter()
        for plane in [frame.planes[1], tilted.planes[1]] {
            let t = simd_dot(volume.physicalCenter, plane.normal)
            let image = volume.reslice(plane, at: t, slab: 10, mode: .mip, outside: 0) { asked.bump(); return true }
            #expect(image.width == plane.width && image.height == plane.height)
            #expect(image.values.count == plane.width * plane.height)
        }
        // Each band asks once, sees true, and stops.
        #expect(asked.value > 0 && asked.value <= 2 * ProcessInfo.processInfo.activeProcessorCount * 4)
        // Never cancelled: the same image as without the closure.
        let plane = tilted.planes[2], t = simd_dot(volume.physicalCenter, plane.normal)
        #expect(volume.reslice(plane, at: t, slab: 10, mode: .mean, outside: 0) { false }.values
            == volume.reslice(plane, at: t, slab: 10, mode: .mean, outside: 0).values)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
