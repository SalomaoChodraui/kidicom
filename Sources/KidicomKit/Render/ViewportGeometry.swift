import CoreGraphics
import Foundation

/// Where an image sits in a viewport: fit to the view, then flipped,
/// rotated in quarter turns, zoomed, and panned. Converts points between
/// image pixels and view points (y grows downward in both).
public struct ViewportGeometry: Equatable, Sendable {
    public var imageSize: CGSize
    public var viewSize: CGSize
    public var zoom: CGFloat = 1
    public var pan: CGSize = .zero
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init(imageSize: CGSize, viewSize: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero,
                quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.zoom = zoom
        self.pan = pan
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    /// View points per image pixel.
    public var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let turned = quarterTurns % 2 == 1
        let w = turned ? imageSize.height : imageSize.width
        let h = turned ? imageSize.width : imageSize.height
        return min(viewSize.width / w, viewSize.height / h) * zoom
    }

    public var center: CGPoint {
        CGPoint(x: viewSize.width / 2 + pan.width, y: viewSize.height / 2 + pan.height)
    }

    private var angle: CGFloat { CGFloat(quarterTurns) * .pi / 2 }

    public func toView(_ p: CGPoint) -> CGPoint {
        var x = (p.x - imageSize.width / 2) * scale
        var y = (p.y - imageSize.height / 2) * scale
        if flipHorizontal { x = -x }
        if flipVertical { y = -y }
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
    }

    public func toImage(_ v: CGPoint) -> CGPoint {
        let dx = v.x - center.x, dy = v.y - center.y
        let c = cos(angle), s = sin(angle)
        var x = dx * c + dy * s
        var y = -dx * s + dy * c
        if flipHorizontal { x = -x }
        if flipVertical { y = -y }
        return CGPoint(x: x / scale + imageSize.width / 2, y: y / scale + imageSize.height / 2)
    }
}
