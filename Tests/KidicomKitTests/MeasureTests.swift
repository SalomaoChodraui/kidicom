import CoreGraphics
import Foundation
import Testing
@testable import KidicomKit

@Suite("Measure")
struct MeasureTests {
    @Test("Distance uses column spacing for x and row spacing for y")
    func distance() {
        let mm = Calibration.millimeters(row: 0.5, column: 0.25)
        #expect(Measure.distance(.zero, CGPoint(x: 40, y: 0), calibration: mm) == 10)
        #expect(Measure.distance(.zero, CGPoint(x: 0, y: 40), calibration: mm) == 20)
        #expect(Measure.distance(.zero, CGPoint(x: 3, y: 4), calibration: .pixels) == 5)
    }

    @Test("Angle is measured in physical space")
    func angle() {
        let square = Calibration.millimeters(row: 1, column: 1)
        #expect(abs(Measure.angle(CGPoint(x: 10, y: 0), vertex: .zero, CGPoint(x: 0, y: 10), calibration: square) - 90) < 1e-9)
        #expect(abs(Measure.angle(CGPoint(x: 10, y: 0), vertex: .zero, CGPoint(x: 10, y: 10), calibration: square) - 45) < 1e-9)
        // Pixels twice as tall as wide: (10, 10) in pixels is 10 x 20 mm, not 45 degrees.
        let tall = Calibration.millimeters(row: 2, column: 1)
        let tilted = Measure.angle(CGPoint(x: 10, y: 0), vertex: .zero, CGPoint(x: 10, y: 10), calibration: tall)
        #expect(abs(tilted - atan(2) * 180 / .pi) < 1e-9)
    }

    @Test("Ultrasound regions calibrate in centimeters when every point is inside")
    func ultrasound() {
        let region = UltrasoundRegion(minX: 100, minY: 50, maxX: 700, maxY: 550, deltaX: 0.01, deltaY: 0.01, unitsX: 3, unitsY: 3)
        let inside = [CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100)]
        #expect(Calibration.best(pixelSpacing: [], regions: [region], points: inside) == .millimeters(row: 0.1, column: 0.1))
        #expect(Measure.distance(inside[0], inside[1], calibration: .millimeters(row: 0.1, column: 0.1)) == 10)
        #expect(Calibration.best(pixelSpacing: [], regions: [region], points: [CGPoint(x: 10, y: 10)]) == .pixels)
        #expect(Calibration.best(pixelSpacing: [0.7, 0.7], regions: [region], points: inside) == .millimeters(row: 0.7, column: 0.7))
    }

    @Test("Regions are read from the ultrasound sequence")
    func readRegions() throws {
        var item = DicomWriter()
        item.element(.regionLocationMinX0, .UL, le32(10))
        item.element(.regionLocationMinY0, .UL, le32(20))
        item.element(.regionLocationMaxX1, .UL, le32(500))
        item.element(.regionLocationMaxY1, .UL, le32(400))
        item.us(.physicalUnitsXDirection, 3)
        item.us(.physicalUnitsYDirection, 3)
        var dx = Data(); withUnsafeBytes(of: (0.02).bitPattern.littleEndian) { dx.append(contentsOf: $0) }
        item.element(.physicalDeltaX, .FD, dx)
        item.element(.physicalDeltaY, .FD, dx)
        var file = DicomWriter()
        file.sequence(.sequenceOfUltrasoundRegions, items: [item])
        let regions = UltrasoundRegion.regions(in: try DicomParser.parse(file.build()).dataset)
        #expect(regions == [UltrasoundRegion(minX: 10, minY: 20, maxX: 500, maxY: 400, deltaX: 0.02, deltaY: 0.02, unitsX: 3, unitsY: 3)])
    }
}

@Suite("Viewport geometry")
struct GeometryTests {
    func roundTrip(_ g: ViewportGeometry) {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: 12), CGPoint(x: 99, y: 49)] {
            let back = g.toImage(g.toView(p))
            #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
        }
    }

    @Test("Image center sits at view center plus pan")
    func center() {
        let g = ViewportGeometry(imageSize: CGSize(width: 100, height: 50), viewSize: CGSize(width: 400, height: 400), pan: CGSize(width: 10, height: -5))
        #expect(g.scale == 4)
        #expect(g.toView(CGPoint(x: 50, y: 25)) == CGPoint(x: 210, y: 195))
        #expect(g.toView(.zero) == CGPoint(x: 10, y: 95))
    }

    @Test("Rotation right moves the image's top-left corner to the top-right")
    func rotation() {
        let g = ViewportGeometry(imageSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100), quarterTurns: 1)
        let corner = g.toView(.zero)
        #expect(abs(corner.x - 100) < 1e-9 && abs(corner.y) < 1e-9)
    }

    @Test("Every transform converts back and forth", arguments: 0 ..< 16)
    func transforms(_ code: Int) {
        roundTrip(ViewportGeometry(
            imageSize: CGSize(width: 100, height: 50), viewSize: CGSize(width: 300, height: 200), zoom: 1.7,
            pan: CGSize(width: 13, height: -8), quarterTurns: code % 4, flipHorizontal: code & 4 != 0, flipVertical: code & 8 != 0
        ))
    }
}
