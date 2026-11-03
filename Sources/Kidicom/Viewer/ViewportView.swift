import AppKit
import KidicomKit
import SwiftUI

/// The image area of one viewport, with the mouse and keyboard of a
/// radiology viewer: wheel and arrows scroll, left-drag window/level,
/// right-drag zoom, middle-drag or Command-drag pan, pinch or Option-wheel zoom.
struct ViewportView: NSViewRepresentable {
    let viewport: Viewport
    var isActive: Bool
    var onActivate: () -> Void

    func makeNSView(context: Context) -> ViewportNSView {
        let view = ViewportNSView()
        view.viewport = viewport
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        view.viewport = viewport
        view.onActivate = onActivate
        view.update(image: viewport.image)
    }
}

final class ViewportNSView: NSView {
    var viewport: Viewport?
    var onActivate: () -> Void = {}
    private let imageLayer = CALayer()
    private var scrollRemainder: CGFloat = 0
    private var zoomAnchor: CGPoint?
    private var imageSize = CGSize.zero
    /// Last pointer position in view coordinates. Deltas come from positions,
    /// because some event sources (tablets, synthetic input) leave deltaX at 0.
    private var lastPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Zoom and pan never draw outside the viewport.
        layer?.masksToBounds = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func update(image: CGImage?) {
        imageLayer.contents = image
        if let image { imageSize = CGSize(width: image.width, height: image.height) }
        layoutImage()
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    /// Fits the image, then applies zoom, pan, flips, and rotation around its center.
    private func layoutImage() {
        guard let viewport, imageSize.width > 0, bounds.width > 0 else { imageLayer.bounds = .zero; return }
        let turned = viewport.quarterTurns % 2 == 1
        let shown = turned ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        let fit = min(bounds.width / shown.width, bounds.height / shown.height) * viewport.zoom
        imageLayer.bounds = CGRect(x: 0, y: 0, width: imageSize.width * fit, height: imageSize.height * fit)
        imageLayer.position = CGPoint(x: bounds.midX + viewport.pan.width, y: bounds.midY + viewport.pan.height)
        var transform = CATransform3DMakeRotation(CGFloat(viewport.quarterTurns) * .pi / 2, 0, 0, 1)
        transform = CATransform3DScale(transform, viewport.flipHorizontal ? -1 : 1, viewport.flipVertical ? -1 : 1, 1)
        imageLayer.transform = transform
    }

    // MARK: Mouse

    private func delta(_ event: NSEvent) -> CGSize {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastPoint = point }
        guard let last = lastPoint else { return .zero }
        return CGSize(width: point.x - last.x, height: point.y - last.y)
    }

    private func begin(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate()
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        begin(event)
        if event.clickCount == 2 { viewport?.reset() }
    }

    override func rightMouseDown(with event: NSEvent) {
        begin(event)
        zoomAnchor = lastPoint
    }

    override func otherMouseDown(with event: NSEvent) {
        begin(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewport else { return }
        let d = delta(event)
        if event.modifierFlags.contains(.command) {
            viewport.pan.width += d.width
            viewport.pan.height += d.height
        } else {
            viewport.adjustWindow(dx: d.width, dy: d.height)
        }
    }

    /// Right-drag zooms around the point where the drag started: up zooms
    /// in, down zooms out.
    override func rightMouseDragged(with event: NSEvent) {
        zoom(by: exp(-delta(event).height * 0.01), around: zoomAnchor)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let d = delta(event)
        viewport?.pan.width += d.width
        viewport?.pan.height += d.height
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewport else { return }
        if event.modifierFlags.contains(.option) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, around: convert(event.locationInWindow, from: nil))
            return
        }
        // Trackpads send many small deltas, wheels a few large ones.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
        scrollRemainder += event.scrollingDeltaY / unit
        let steps = Int(scrollRemainder)
        if steps != 0 {
            viewport.step(-steps)
            scrollRemainder -= CGFloat(steps)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    /// Zooms keeping the image point under `anchor` in place.
    private func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        guard let viewport else { return }
        let old = viewport.zoom
        let new = min(20, max(0.1, old * factor))
        guard new != old else { return }
        if let anchor {
            let applied = new / old
            let center = CGPoint(x: bounds.midX + viewport.pan.width, y: bounds.midY + viewport.pan.height)
            let moved = CGPoint(x: anchor.x - (anchor.x - center.x) * applied, y: anchor.y - (anchor.y - center.y) * applied)
            viewport.pan = CGSize(width: moved.x - bounds.midX, height: moved.y - bounds.midY)
        }
        viewport.zoom = new
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let viewport else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .upArrow: viewport.step(-1)
        case .downArrow: viewport.step(1)
        case .pageUp: viewport.step(-10)
        case .pageDown: viewport.step(10)
        case .home: viewport.go(to: 0)
        case .end: viewport.go(to: viewport.count - 1)
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            if let digit = Int(key), let preset = WindowPreset(rawValue: digit) {
                viewport.apply(preset)
            } else if key == " " {
                viewport.togglePlay()
            } else if key == "r" {
                viewport.rotate(clockwise: true)
            } else if key == "R" {
                viewport.rotate(clockwise: false)
            } else if key == "h" {
                viewport.flip(horizontal: true)
            } else if key == "v" {
                viewport.flip(horizontal: false)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
