import Foundation
import Testing
@testable import KidicomKit

@Suite("Render")
struct RenderTests {
    @Test("Vector windowing matches the DICOM linear function")
    func windowing() {
        let window = VOIWindow(center: 40, width: 400)
        let values: [Float] = [-1000, -160, -100, 0, 40, 100, 239, 240, 3000]
        let fast = Renderer.gray8(values, window: window, inverted: false)
        let slow = values.map { window.gray($0) }
        for (a, b) in zip(fast, slow) { #expect(abs(Int(a) - Int(b)) <= 1) }
        let inverted = Renderer.gray8(values, window: window, inverted: true)
        for (a, b) in zip(inverted, slow) { #expect(abs(Int(a) - (255 - Int(b))) <= 1) }
    }

    @Test("Color frames get brightness and contrast per channel")
    func colorWindow() {
        let rgba: [UInt8] = [10, 128, 250, 255]
        #expect(Renderer.color(rgba, window: VOIWindow(center: 128, width: 256)) == rgba)
        let narrow = Renderer.color(rgba, window: VOIWindow(center: 128, width: 64))
        #expect(narrow[0] == 0 && narrow[2] == 255 && narrow[3] == 255)
        #expect(abs(Int(narrow[1]) - 129) <= 2)
    }

    @Test("Axial slices sort from head to feet by position, not by number")
    func axialOrder() {
        let axial = [1.0, 0, 0, 0, 1, 0]
        let items = [
            SliceOrder.Item(instanceNumber: 1, position: [0, 0, -10], orientation: axial),
            SliceOrder.Item(instanceNumber: 2, position: [0, 0, 10], orientation: axial),
            SliceOrder.Item(instanceNumber: 3, position: [0, 0, 0], orientation: axial),
        ]
        #expect(SliceOrder.order(items) == [1, 2, 0])
        #expect(SliceOrder.location(position: [0, 0, -10], orientation: axial) == -10)
    }

    @Test("Without positions, images sort by instance number")
    func byNumber() {
        let items = [3, 1, 2].map { SliceOrder.Item(instanceNumber: $0, position: [], orientation: []) }
        #expect(SliceOrder.order(items) == [1, 2, 0])
    }

    @Test("Same position keeps instance order")
    func samePosition() {
        let axial = [1.0, 0, 0, 0, 1, 0]
        let items = [2, 1].map { SliceOrder.Item(instanceNumber: $0, position: [0, 0, 5], orientation: axial) }
        #expect(SliceOrder.order(items) == [1, 0])
    }
}

@Suite("Orientation")
struct OrientationTests {
    let axial = [1.0, 0, 0, 0, 1, 0]

    @Test("Axial image: patient right on screen left, anterior on top")
    func axialEdges() {
        #expect(Orientation.edges(axial) == .init(top: "A", bottom: "P", left: "R", right: "L"))
    }

    @Test("Sagittal and coronal")
    func others() {
        #expect(Orientation.edges([0, 1, 0, 0, 0, -1]) == .init(top: "H", bottom: "F", left: "A", right: "P"))
        #expect(Orientation.edges([1, 0, 0, 0, 0, -1]) == .init(top: "H", bottom: "F", left: "R", right: "L"))
    }

    @Test("Rotation and flips move the letters")
    func transforms() {
        #expect(Orientation.edges(axial, quarterTurns: 1) == .init(top: "R", bottom: "L", left: "P", right: "A"))
        #expect(Orientation.edges(axial, quarterTurns: 4) == Orientation.edges(axial))
        #expect(Orientation.edges(axial, quarterTurns: -1) == Orientation.edges(axial, quarterTurns: 3))
        #expect(Orientation.edges(axial, flipHorizontal: true) == .init(top: "A", bottom: "P", left: "L", right: "R"))
        #expect(Orientation.edges(axial, flipVertical: true) == .init(top: "P", bottom: "A", left: "R", right: "L"))
    }

    @Test("Oblique images get two letters, strongest first")
    func oblique() {
        let c = 0.8, s = 0.6
        #expect(Orientation.edges([c, s, 0, 0, 0, -1])?.right == "LP")
        #expect(Orientation.edges([1, 0, 0])  == nil)
    }
}

@Suite("Free rotation")
struct FreeRotationTests {
    @Test("Any-angle letters match the quarter-turn rule", arguments: 0 ..< 16)
    func matchesQuarterTurns(_ code: Int) {
        let orientations: [[Double]] = [[1, 0, 0, 0, 1, 0], [0, 1, 0, 0, 0, -1], [1, 0, 0, 0, 0, -1]]
        for o in orientations {
            let turns = code % 4, h = code & 4 != 0, v = code & 8 != 0
            #expect(Orientation.edges(o, angle: Double(turns) * .pi / 2, flipHorizontal: h, flipVertical: v)
                    == Orientation.quarterTurnEdges(o, quarterTurns: turns, flipHorizontal: h, flipVertical: v))
        }
    }

    @Test("A 30 degree turn of an axial image puts two letters on the edges")
    func thirtyDegrees() {
        let e = Orientation.edges([1, 0, 0, 0, 1, 0], angle: .pi / 6)
        // Turned 30° clockwise, the top edge looks mostly anterior and a little toward patient right.
        #expect(e?.top == "AR")
        #expect(e?.right == "LA")
    }

    @Test("Free rotation converts back and forth")
    func geometry() {
        let g = ViewportGeometry(imageSize: CGSize(width: 100, height: 60), viewSize: CGSize(width: 300, height: 300),
                                 zoom: 1.3, pan: CGSize(width: 8, height: -4), quarterTurns: 1, flipHorizontal: true, freeAngle: 0.37)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 51, y: 17), CGPoint(x: 99, y: 59)] {
            let back = g.toImage(g.toView(p))
            #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
        }
    }
}
