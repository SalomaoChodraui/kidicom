import Foundation

/// One decoded slice for building a volume.
public struct VolumeSlice: Sendable {
    public var values: [Float]
    public var width: Int
    public var height: Int
    /// Image Position (Patient) of the first pixel, in mm.
    public var position: [Double]
    /// Image Orientation (Patient): row then column direction cosines.
    public var orientation: [Double]
    /// Pixel Spacing: row spacing, then column spacing, in mm.
    public var pixelSpacing: [Double]

    public init(values: [Float], width: Int, height: Int, position: [Double], orientation: [Double], pixelSpacing: [Double]) {
        self.values = values
        self.width = width
        self.height = height
        self.position = position
        self.orientation = orientation
        self.pixelSpacing = pixelSpacing
    }
}

public enum VolumeError: Error, Equatable, Sendable {
    case tooFewSlices(Int)
    case missingGeometry
    case mixedOrientations
    case mixedSizes
}

/// Something odd about a volume, shown in the viewport overlay.
public enum VolumeWarning: Equatable, Sendable {
    /// Slices missing: spacing jumps to more than 1.5 times the usual step.
    case gaps(Int)
    /// Spacing varies by more than 10 percent.
    case unevenSpacing
}

/// A stack of parallel slices as one 3D grid of modality values.
/// Axis i follows the image rows' direction (columns of pixels), j the
/// columns' direction, k the slice normal, from the lowest position up.
public struct Volume: Sendable {
    public let width: Int      // i
    public let height: Int     // j
    public let depth: Int      // k
    /// mm between voxel centers along i, j, k.
    public let spacing: (i: Double, j: Double, k: Double)
    /// Patient position of voxel (0, 0, 0), in mm.
    public let origin: [Double]
    public let rowDirection: [Double]
    public let columnDirection: [Double]
    public let normal: [Double]
    /// x fastest, then y, then slice.
    public let voxels: [Float16]
    /// Gaps or uneven spacing found while building, for the overlay.
    public let warnings: [VolumeWarning]

    public var count: Int { width * height * depth }

    @inline(__always)
    public func value(_ i: Int, _ j: Int, _ k: Int) -> Float {
        Float(voxels[(k * height + j) * width + i])
    }

    /// Builds a volume from slices in any order. Slices must share size and
    /// orientation; spacing between them comes from their positions.
    public static func build(_ input: [VolumeSlice]) throws -> Volume {
        guard input.count >= 3 else { throw VolumeError.tooFewSlices(input.count) }
        guard let first = input.first, first.orientation.count == 6,
              input.allSatisfy({ $0.position.count == 3 && $0.orientation.count == 6 }) else {
            throw VolumeError.missingGeometry
        }
        let row = Array(first.orientation[0 ..< 3]), column = Array(first.orientation[3 ..< 6])
        let normal = cross(row, column)
        for slice in input where !sameDirection(Array(slice.orientation[0 ..< 3]), row) || !sameDirection(Array(slice.orientation[3 ..< 6]), column) {
            _ = slice
            throw VolumeError.mixedOrientations
        }
        guard input.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.values.count >= $0.width * $0.height }) else {
            throw VolumeError.mixedSizes
        }

        // Order by position along the normal; drop exact duplicates.
        var slices = input.sorted { dot($0.position, normal) < dot($1.position, normal) }
        slices = slices.enumerated().filter { index, slice in
            index == 0 || abs(dot(slice.position, normal) - dot(slices[index - 1].position, normal)) > 1e-3
        }.map(\.element)
        guard slices.count >= 3 else { throw VolumeError.tooFewSlices(slices.count) }

        let locations = slices.map { dot($0.position, normal) }
        let gaps = zip(locations.dropFirst(), locations).map { $0 - $1 }
        let step = gaps.sorted()[gaps.count / 2]
        var warnings: [VolumeWarning] = []
        let missing = gaps.filter { $0 > step * 1.5 }.count
        if missing > 0 {
            warnings.append(.gaps(missing))
        } else if gaps.contains(where: { abs($0 - step) > step * 0.1 }) {
            warnings.append(.unevenSpacing)
        }

        let width = first.width, height = first.height, plane = width * height
        var voxels = [Float16](repeating: 0, count: plane * slices.count)
        voxels.withUnsafeMutableBufferPointer { out in
            for (k, slice) in slices.enumerated() {
                slice.values.withUnsafeBufferPointer { values in
                    let base = k * plane
                    for p in 0 ..< plane { out[base + p] = Float16(values[p]) }
                }
            }
        }
        let spacing = first.pixelSpacing.count >= 2 ? first.pixelSpacing : [1, 1]
        return Volume(
            width: width, height: height, depth: slices.count,
            spacing: (i: spacing[1], j: spacing[0], k: step),
            origin: slices[0].position, rowDirection: row, columnDirection: column, normal: normal,
            voxels: voxels, warnings: warnings
        )
    }

    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

    static func sameDirection(_ a: [Double], _ b: [Double]) -> Bool { dot(a, b) > 0.999 }

    init(width: Int, height: Int, depth: Int, spacing: (i: Double, j: Double, k: Double), origin: [Double],
         rowDirection: [Double], columnDirection: [Double], normal: [Double], voxels: [Float16], warnings: [VolumeWarning]) {
        self.width = width
        self.height = height
        self.depth = depth
        self.spacing = spacing
        self.origin = origin
        self.rowDirection = rowDirection
        self.columnDirection = columnDirection
        self.normal = normal
        self.voxels = voxels
        self.warnings = warnings
    }
}
