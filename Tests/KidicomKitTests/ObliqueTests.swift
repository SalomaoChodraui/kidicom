import Foundation
import Testing
import simd
@testable import KidicomKit

@Suite("Oblique MPR")
struct ObliqueTests {
    /// 8x8x8 voxels of 1 mm, value = 100k + 10j + i.
    func cube() throws -> Volume {
        var slices: [VolumeSlice] = []
        for k in 0 ..< 8 {
            var values: [Float] = []
            for p in 0 ..< 64 { values.append(Float(100 * k + 10 * (p / 8) + p % 8)) }
            slices.append(VolumeSlice(values: values, width: 8, height: 8, position: [0, 0, Double(k)],
                                      orientation: [1, 0, 0, 0, 1, 0], pixelSpacing: [1, 1]))
        }
        return try Volume.build(slices)
    }

    @Test("Straight planes match the reformats pixel for pixel")
    func straight() throws {
        let volume = try cube()
        let frame = MPRFrame(volume: volume)
        for (index, plane) in VolumePlane.allCases.enumerated() {
            let reference = volume.reslice(plane, at: 3)
            let oblique = frame.planes[index]
            let n = oblique.normal
            let range = volume.obliqueRange(n)
            // Position 3 along this plane's normal, counted the way the reformat counts it.
            let t = range.start + Double(plane == .native ? 3 : (n.y < 0 || n.x < 0 ? range.count - 1 - 3 : 3)) * range.step
            let image = volume.reslice(oblique, at: t, outside: volume.floorValue)
            #expect(image.width == reference.width && image.height == reference.height)
            let diff = zip(image.values, reference.values).map { abs($0 - $1) }.max() ?? 1
            #expect(diff < 1e-3, "\(plane) differs by \(diff)")
        }
    }

    @Test("Rotation keeps the three planes perpendicular and leaves the fixed one alone")
    func rotation() throws {
        var frame = MPRFrame(volume: try cube())
        let fixed = frame.planes[0]
        frame.rotate(around: 0, by: .pi / 7)
        #expect(frame.planes[0] == fixed)
        let n = frame.planes.map(\.normal)
        #expect(abs(simd_dot(n[0], n[1])) < 1e-9 && abs(simd_dot(n[0], n[2])) < 1e-9 && abs(simd_dot(n[1], n[2])) < 1e-9)
        #expect(frame.isTilted)
        frame.resetRotation()
        #expect(!frame.isTilted)
    }

    @Test("A plane tilted 45 degrees samples along the diagonal")
    func diagonal() throws {
        let volume = try cube()
        var frame = MPRFrame(volume: volume)
        frame.rotate(around: 0, by: .pi / 4)          // turn the coronal and sagittal planes in the axial plane
        let plane = frame.planes[1]
        let image = volume.reslice(plane, at: simd_dot(frame.center, plane.normal), outside: -1)
        // The middle row runs through the volume center: i and j change together along it.
        let row = image.height / 2
        let values = (0 ..< image.width).map { image.values[row * image.width + $0] }.filter { $0 >= 0 }
        #expect(values.count >= 6)
        let steps = zip(values.dropFirst(), values).map { $0 - $1 }
        // Each pixel moves √½ mm in i and in j: about 0.7 + 7.1 per pixel, one direction.
        #expect(steps.allSatisfy { abs(abs($0) - 7.78) < 0.8 })
    }

    @Test("Canvas points and volume points convert back and forth")
    func canvas() throws {
        let volume = try cube()
        var frame = MPRFrame(volume: volume)
        frame.rotate(around: 2, by: 0.3)
        let plane = frame.planes[0]
        let t = simd_dot(frame.center, plane.normal)
        let pixel = SIMD2(2.5, 4.25)
        let back = volume.canvasPoint(volume.volumePoint(pixel, on: plane, at: t), on: plane, at: t)
        #expect(simd_length(back - pixel) < 1e-9)
    }

    @Test("A thick MIP is at least as bright as the plane itself")
    func mip() throws {
        let volume = try cube()
        var frame = MPRFrame(volume: volume)
        frame.rotate(around: 0, by: 0.4)
        let plane = frame.planes[2]
        let t = simd_dot(frame.center, plane.normal)
        let thin = volume.reslice(plane, at: t, outside: -1)
        let thick = volume.reslice(plane, at: t, slab: 4, mode: .mip, outside: -1)
        #expect(zip(thick.values, thin.values).allSatisfy { $0 >= $1 - 1e-4 })
        #expect(thick.values.reduce(0, +) > thin.values.reduce(0, +))
        let low = volume.reslice(plane, at: t, slab: 4, mode: .minip, outside: -1)
        let mean = volume.reslice(plane, at: t, slab: 4, mode: .mean, outside: -1)
        #expect(zip(low.values, thin.values).allSatisfy { $0 <= $1 + 1e-4 })
        #expect(zip(zip(low.values, mean.values), thick.values).allSatisfy { $0.0 <= $0.1 + 1e-4 && $0.1 <= $1 + 1e-4 })
    }
}
