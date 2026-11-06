import Foundation

/// Patient direction letters on the four edges of an image, from Image
/// Orientation (Patient), after the viewer's rotation and flips.
public enum Orientation {
    public struct Edges: Equatable, Sendable {
        public var top: String
        public var bottom: String
        public var left: String
        public var right: String

        public init(top: String, bottom: String, left: String, right: String) {
            self.top = top
            self.bottom = bottom
            self.left = left
            self.right = right
        }
    }

    /// - Parameters:
    ///   - orientation: the six direction cosines (row, then column).
    ///   - quarterTurns: clockwise rotations of the displayed image.
    ///   - flipHorizontal: mirror left and right, applied before rotating.
    ///   - flipVertical: mirror top and bottom, applied before rotating.
    public static func edges(_ orientation: [Double], quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) -> Edges? {
        edges(orientation, angle: Double(quarterTurns) * .pi / 2, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    /// Edge letters for any clockwise rotation in radians: each edge gets the
    /// patient direction that points toward it on screen.
    public static func edges(_ orientation: [Double], angle: Double, flipHorizontal: Bool = false, flipVertical: Bool = false) -> Edges? {
        guard orientation.count == 6 else { return nil }
        let row = Array(orientation[0 ..< 3]), column = Array(orientation[3 ..< 6])
        // Screen direction (y down) to image direction: undo the rotation, then the flips.
        func toward(_ sx: Double, _ sy: Double) -> String {
            let c = cos(-angle), s = sin(-angle)
            var ix = sx * c - sy * s, iy = sx * s + sy * c
            if flipHorizontal { ix = -ix }
            if flipVertical { iy = -iy }
            return letters((0 ..< 3).map { ix * row[$0] + iy * column[$0] })
        }
        return Edges(top: toward(0, -1), bottom: toward(0, 1), left: toward(-1, 0), right: toward(1, 0))
    }

    static func quarterTurnEdges(_ orientation: [Double], quarterTurns: Int, flipHorizontal: Bool, flipVertical: Bool) -> Edges? {
        guard orientation.count == 6 else { return nil }
        let row = Array(orientation[0 ..< 3]), column = Array(orientation[3 ..< 6])
        var e = Edges(top: letters(column.map { -$0 }), bottom: letters(column), left: letters(row.map { -$0 }), right: letters(row))
        if flipHorizontal { swap(&e.left, &e.right) }
        if flipVertical { swap(&e.top, &e.bottom) }
        for _ in 0 ..< ((quarterTurns % 4) + 4) % 4 {
            // A clockwise turn moves the left edge to the top.
            e = Edges(top: e.left, bottom: e.right, left: e.bottom, right: e.top)
        }
        return e
    }

    /// Letters for a patient direction, strongest first: x is L+/R-, y is
    /// P+/A-, z is H+/F-. Components under 0.25 are left out.
    static func letters(_ v: [Double]) -> String {
        let axes: [(Double, String, String)] = [(v[0], "L", "R"), (v[1], "P", "A"), (v[2], "H", "F")]
        return axes
            .filter { abs($0.0) >= 0.25 }
            .sorted { abs($0.0) > abs($1.0) }
            .map { $0.0 > 0 ? $0.1 : $0.2 }
            .joined()
    }
}
