import CoreGraphics
import Foundation

/// How to turn image pixels into millimeters.
public enum Calibration: Equatable, Sendable {
    /// Row and column spacing in mm (Pixel Spacing is row, then column).
    case millimeters(row: Double, column: Double)
    /// No calibration: lengths stay in pixels.
    case pixels

    /// The calibration for points in one image: Pixel Spacing (or Imager
    /// Pixel Spacing), else the ultrasound region that holds every point.
    public static func best(pixelSpacing: [Double], regions: [UltrasoundRegion], points: [CGPoint]) -> Calibration {
        if pixelSpacing.count >= 2, pixelSpacing[0] > 0, pixelSpacing[1] > 0 {
            return .millimeters(row: pixelSpacing[0], column: pixelSpacing[1])
        }
        for region in regions where region.isCentimeters && points.allSatisfy(region.contains) {
            return .millimeters(row: region.deltaY * 10, column: region.deltaX * 10)
        }
        return .pixels
    }

    func physical(_ p: CGPoint) -> (Double, Double) {
        switch self {
        case .millimeters(let row, let column): (Double(p.x) * column, Double(p.y) * row)
        case .pixels: (Double(p.x), Double(p.y))
        }
    }
}

/// One calibrated area of an ultrasound image (Sequence of Ultrasound Regions).
public struct UltrasoundRegion: Equatable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    /// Physical size of one pixel, in the region's units.
    public var deltaX: Double, deltaY: Double
    public var unitsX: Int, unitsY: Int

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double, deltaX: Double, deltaY: Double, unitsX: Int, unitsY: Int) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        self.deltaX = deltaX; self.deltaY = deltaY; self.unitsX = unitsX; self.unitsY = unitsY
    }

    /// Units 3 is centimeters for both axes (a 2D tissue region).
    public var isCentimeters: Bool { unitsX == 3 && unitsY == 3 && deltaX > 0 && deltaY > 0 }

    public func contains(_ p: CGPoint) -> Bool {
        Double(p.x) >= minX && Double(p.x) <= maxX + 1 && Double(p.y) >= minY && Double(p.y) <= maxY + 1
    }

    public static func regions(in dataset: DicomDataset) -> [UltrasoundRegion] {
        dataset.sequence(.sequenceOfUltrasoundRegions).compactMap { item in
            guard let minX = item.number(.regionLocationMinX0), let minY = item.number(.regionLocationMinY0),
                  let maxX = item.number(.regionLocationMaxX1), let maxY = item.number(.regionLocationMaxY1),
                  let dx = item.number(.physicalDeltaX), let dy = item.number(.physicalDeltaY) else { return nil }
            return UltrasoundRegion(minX: minX, minY: minY, maxX: maxX, maxY: maxY, deltaX: abs(dx), deltaY: abs(dy),
                                    unitsX: item.int(.physicalUnitsXDirection) ?? 0, unitsY: item.int(.physicalUnitsYDirection) ?? 0)
        }
    }
}

public enum Measure {
    /// Length between two image points, in mm or pixels.
    public static func distance(_ a: CGPoint, _ b: CGPoint, calibration: Calibration) -> Double {
        let (ax, ay) = calibration.physical(a), (bx, by) = calibration.physical(b)
        return ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
    }

    /// The angle at `vertex` between the arms to `a` and `c`, in degrees,
    /// measured in physical space so non-square pixels are right.
    public static func angle(_ a: CGPoint, vertex: CGPoint, _ c: CGPoint, calibration: Calibration) -> Double {
        let (ax, ay) = calibration.physical(a), (vx, vy) = calibration.physical(vertex), (cx, cy) = calibration.physical(c)
        let u = (ax - vx, ay - vy), w = (cx - vx, cy - vy)
        let lengths = (u.0 * u.0 + u.1 * u.1).squareRoot() * (w.0 * w.0 + w.1 * w.1).squareRoot()
        guard lengths > 0 else { return 0 }
        let cosine = max(-1, min(1, (u.0 * w.0 + u.1 * w.1) / lengths))
        return acos(cosine) * 180 / .pi
    }
}
