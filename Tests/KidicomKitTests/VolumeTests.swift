import Foundation
import Testing
@testable import KidicomKit

@Suite("Volume")
struct VolumeTests {
    let axial = [1.0, 0, 0, 0, 1, 0]

    /// A 4x3 image per slice whose value encodes (i, j, k): 100k + 10j + i.
    func slices(_ zs: [Double], orientation: [Double]? = nil) -> [VolumeSlice] {
        zs.enumerated().map { k, z in
            VolumeSlice(values: (0 ..< 12).map { (p: Int) -> Float in Float(100 * k + 10 * (p / 4) + p % 4) }, width: 4, height: 3,
                        position: [0, 0, z], orientation: orientation ?? axial, pixelSpacing: [2, 1])
        }
    }

    @Test("Slices sort by position and spacing comes from positions")
    func build() throws {
        let volume = try Volume.build(slices([0, 3, 6, 9]).reversed())
        #expect(volume.depth == 4 && volume.width == 4 && volume.height == 3)
        #expect(volume.spacing.i == 1 && volume.spacing.j == 2 && volume.spacing.k == 3)
        #expect(volume.value(3, 2, 0) == 23)   // reversed input: k=0 is z=0, which was built as k=0
        #expect(volume.warnings.isEmpty)
    }

    @Test("Gaps and uneven spacing are reported")
    func warnings() throws {
        #expect(try Volume.build(slices([0, 3, 6, 15, 18])).warnings == [.gaps(1)])
        #expect(try Volume.build(slices([0, 3, 6.5, 9])).warnings == [.unevenSpacing])
    }

    @Test("Mixed orientations and too few slices are refused")
    func refused() {
        var mixed = slices([0, 3, 6])
        mixed[1].orientation = [0, 1, 0, 0, 0, -1]
        #expect(throws: VolumeError.mixedOrientations) { try Volume.build(mixed) }
        #expect(throws: VolumeError.tooFewSlices(2)) { try Volume.build(slices([0, 3])) }
    }

    @Test("Native slice is the acquired image")
    func native() throws {
        let volume = try Volume.build(slices([0, 1, 2]))
        let image = volume.reslice(.native, at: 1)
        let expected: [Float] = (0 ..< 12).map { (p: Int) -> Float in Float(100 + 10 * (p / 4) + p % 4) }
        #expect(image.values == expected)
        #expect(image.location == 1)
    }

    @Test("Reformats resample to square pixels with the top slice first")
    func reformat() throws {
        // in-plane spacing 1 (i) and 2 (j); slices 1 mm apart.
        let volume = try Volume.build(slices([0, 1, 2]))
        let rows = volume.reslice(.alongRows, at: 2)        // fixed j = 2
        #expect(rows.width == 4 && rows.height == 3)
        #expect(rows.values[0] == 200 + 20 + 0)              // top-left: k = 2, i = 0
        #expect(rows.values[2 * 4 + 3] == 0 + 20 + 3)        // bottom-right: k = 0, i = 3
        #expect(rows.orientation == [1, 0, 0, 0, 0, -1])
        let columns = volume.reslice(.alongColumns, at: 1)  // fixed i = 1, j across at 2 mm -> 5 columns of 1 mm
        #expect(columns.width == 5 && columns.height == 3)
        #expect(columns.values[1] == 200 + 5 + 1)            // halfway between j = 0 and j = 1
    }

    @Test("A coronal acquisition reformats with anterior up in axial and the head up in sagittal")
    func coronalAcquisition() throws {
        // Rows run to patient left, columns to the feet; the normal points posterior (+y).
        let coronal = [1.0, 0, 0, 0, 0, -1]
        let stack = (0 ..< 4).map { k in
            VolumeSlice(values: [Float](repeating: Float(k), count: 12), width: 4, height: 3,
                        position: [0, Double(k), 0], orientation: coronal, pixelSpacing: [1, 1])
        }
        let volume = try Volume.build(stack)
        let axial = volume.reslice(.alongRows, at: 1)
        #expect(Orientation.edges(axial.orientation) == .init(top: "A", bottom: "P", left: "R", right: "L"))
        #expect(axial.values[0] == 0)                                  // top row: the most anterior slice
        let sagittal = volume.reslice(.alongColumns, at: 1)
        #expect(Orientation.edges(sagittal.orientation) == .init(top: "H", bottom: "F", left: "A", right: "P"))
        #expect(sagittal.values[0] == 0)                               // left column: anterior
        #expect(volume.line(of: .native, at: 3, in: .alongRows)?.vertical == false)
        #expect(volume.index(of: .native, at: (x: 0, y: 3), in: .alongRows) == 3)
        #expect(volume.index(of: .native, at: (x: 2, y: 0), in: .alongColumns) == 2)
    }

    @Test("MIP takes the maximum across the slab")
    func mip() throws {
        let volume = try Volume.build(slices([0, 1, 2, 3, 4]))
        #expect(volume.reslice(.native, at: 2, slab: 2, mode: .mip).values[0] == 300)
        #expect(volume.reslice(.native, at: 2, slab: 1, mode: .mip).values[0] == 200)
        let single = volume.reslice(.alongRows, at: 1)
        let slab = volume.reslice(.alongRows, at: 1, slab: 4, mode: .mip)   // j 0...2 at 2 mm
        #expect(slab.values[0] == single.values[0] + 10)
    }

    @Test("MinIP takes the minimum and Mean the average across the slab")
    func minipAndMean() throws {
        let volume = try Volume.build(slices([0, 1, 2, 3, 4]))
        #expect(volume.reslice(.native, at: 2, slab: 2, mode: .minip).values[0] == 100)
        #expect(volume.reslice(.native, at: 2, slab: 2, mode: .mean).values[0] == 200)
        let single = volume.reslice(.alongRows, at: 1)
        #expect(volume.reslice(.alongRows, at: 1, slab: 4, mode: .minip).values[0] == single.values[0] - 10)
        #expect(volume.reslice(.alongRows, at: 1, slab: 4, mode: .mean).values[0] == single.values[0])
    }

    @Test("Reference lines and clicks agree")
    func lines() throws {
        let volume = try Volume.build(slices([0, 1, 2]))
        let line = volume.line(of: .native, at: 2, in: .alongRows)
        #expect(line?.vertical == false && line?.position == 0)
        #expect(volume.index(of: .native, at: (x: 0, y: 0), in: .alongRows) == 2)
        #expect(volume.index(of: .alongColumns, at: (x: 3, y: 1), in: .native) == 3)
    }
}
