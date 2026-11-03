import AppKit
import KidicomKit
import SwiftUI

/// The image area of one viewport, with the mouse and keyboard of a
/// radiology viewer: wheel and right-drag scroll, left-drag window/level,
/// middle-drag or Command-drag pan, pinch or Option-wheel zoom.
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
        view.update(image: viewport.image, zoom: viewport.zoom, pan: viewport.pan)
    }
}

final class ViewportNSView: NSView {
    var viewport: Viewport?
    var onActivate: () -> Void = {}
    private let imageLayer = CALayer()
    private var scrollRemainder: CGFloat = 0
    private var dragRemainder: CGFloat = 0
    private var imageSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func update(image: CGImage?, zoom: CGFloat, pan: CGSize) {
        imageLayer.contents = image
        if let image { imageSize = CGSize(width: image.width, height: image.height) }
        layoutImage(zoom: zoom, pan: pan)
    }

    override func layout() {
        super.layout()
        layoutImage(zoom: viewport?.zoom ?? 1, pan: viewport?.pan ?? .zero)
    }

    private func layoutImage(zoom: CGFloat, pan: CGSize) {
        guard imageSize.width > 0, bounds.width > 0 else { imageLayer.frame = .zero; return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height) * zoom
        let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        imageLayer.frame = CGRect(
            x: (bounds.width - size.width) / 2 + pan.width,
            y: (bounds.height - size.height) / 2 + pan.height,
            width: size.width, height: size.height
        )
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate()
        if event.clickCount == 2 { viewport?.reset() }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate()
        dragRemainder = 0
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewport else { return }
        if event.modifierFlags.contains(.command) {
            viewport.pan.width += event.deltaX
            viewport.pan.height += event.deltaY
        } else {
            viewport.adjustWindow(dx: event.deltaX, dy: event.deltaY)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        // Four points of drag per frame, so a long series fits in one sweep.
        dragRemainder += event.deltaY
        let steps = Int(dragRemainder / 4)
        if steps != 0 {
            viewport?.step(steps)
            dragRemainder -= CGFloat(steps) * 4
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        viewport?.pan.width += event.deltaX
        viewport?.pan.height += event.deltaY
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewport else { return }
        if event.modifierFlags.contains(.option) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01)
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
        zoom(by: 1 + event.magnification)
    }

    private func zoom(by factor: CGFloat) {
        guard let viewport else { return }
        viewport.zoom = min(20, max(0.1, viewport.zoom * factor))
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
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), let preset = WindowPreset(rawValue: digit) {
                viewport.apply(preset)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
