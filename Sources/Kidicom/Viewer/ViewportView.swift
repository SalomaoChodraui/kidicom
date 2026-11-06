import AppKit
import KidicomKit
import SwiftUI

/// The image area of one viewport, with the mouse and keyboard of a
/// radiology viewer: wheel and arrows scroll, left-drag window/level,
/// right-drag zoom, middle-drag or Command-drag pan, pinch or Option-wheel zoom.
/// MPR mouse handling the viewer supplies: tilt by a reference line, move
/// by the crossing. Points are in image pixels; scale is view points per pixel.
struct MPRMouse {
    var hit: (CGPoint, CGFloat) -> ViewerModel.MPRDrag? = { _, _ in nil }
    var begin: (CGPoint, CGFloat) -> ViewerModel.MPRDrag? = { _, _ in nil }
    var drag: (CGPoint) -> Void = { _ in }
    var end: () -> Void = {}
}

struct ViewportView: NSViewRepresentable {
    let viewport: Viewport
    var isActive: Bool
    var onActivate: () -> Void
    var onEscape: () -> Void = {}
    var onClick: (CGPoint) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onTool: (MeasureTool) -> Void = { _ in }
    var mpr = MPRMouse()

    func makeNSView(context: Context) -> ViewportNSView {
        let view = ViewportNSView()
        view.viewport = viewport
        view.onActivate = onActivate
        view.onEscape = onEscape
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onTool = onTool
        view.mpr = mpr
        return view
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        view.viewport = viewport
        view.onActivate = onActivate
        view.onEscape = onEscape
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onTool = onTool
        view.mpr = mpr
        view.setTool(viewport.tool)
        _ = (viewport.zoom, viewport.pan, viewport.quarterTurns, viewport.flipHorizontal, viewport.flipVertical, viewport.freeAngle)
        view.update(image: viewport.image)
    }
}

final class ViewportNSView: NSView {
    var viewport: Viewport?
    var onActivate: () -> Void = {}
    var onEscape: () -> Void = {}
    /// A left click without a drag, in image pixels.
    var onClick: (CGPoint) -> Void = { _ in }
    /// Double-click: maximize in a split layout, reset in a single one.
    var onDoubleClick: () -> Void = {}
    /// A tool's key was pressed in the viewport.
    var onTool: (MeasureTool) -> Void = { _ in }
    private var dragged = false
    private var scrollDrag: CGFloat = 0
    /// Rotate tool: the angle when the drag began and the turn so far.
    private var rotateBase: Double = 0
    private var rotateAccumulator: Double = 0
    private var tool: MeasureTool = .navigate
    var mpr = MPRMouse()
    /// True while the left button tilts or moves the MPR planes.
    private var mprDragging = false
    private var hoverCursor: NSCursor?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func cursor(for drag: ViewerModel.MPRDrag?) -> NSCursor? {
        switch drag {
        case .move: ToolCursor.symbol("arrow.up.and.down.and.arrow.left.and.right")
        case .rotate: ToolCursor.rotate
        case nil: nil
        }
    }

    /// Over a reference line the pointer turns into the tilt icon, over the crossing into move.
    override func mouseMoved(with event: NSEvent) {
        if let viewport, viewport.placingRuler, let (point, _) = imagePoint(event) {
            viewport.pointerMoved(to: point)
            return
        }
        guard tool == .navigate, let (point, scale) = imagePoint(event) else { return }
        let hover = cursor(for: mpr.hit(point, scale))
        if let hover { hover.set() } else if hoverCursor != nil { ToolCursor.cursor(for: tool).set() }
        hoverCursor = hover
    }

    /// The pointer follows the left-button tool.
    func setTool(_ newTool: MeasureTool) {
        guard newTool != tool else { return }
        tool = newTool
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ToolCursor.cursor(for: tool))
    }

    /// While a drag does something else than the tool (zoom, pan), the
    /// pointer shows it; afterwards it goes back to the tool's.
    private func showDuring(_ cursor: NSCursor) { cursor.set() }
    private func restoreCursor() { ToolCursor.cursor(for: tool).set() }
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
        guard let geometry = viewport?.geometry(in: bounds.size) else { imageLayer.bounds = .zero; return }
        imageLayer.bounds = CGRect(x: 0, y: 0, width: geometry.imageSize.width * geometry.scale, height: geometry.imageSize.height * geometry.scale)
        imageLayer.position = geometry.center
        var transform = CATransform3DMakeRotation(geometry.angle, 0, 0, 1)
        transform = CATransform3DScale(transform, geometry.flipHorizontal ? -1 : 1, geometry.flipVertical ? -1 : 1, 1)
        imageLayer.transform = transform
    }

    private func imagePoint(_ event: NSEvent) -> (CGPoint, CGFloat)? {
        guard let geometry = viewport?.geometry(in: bounds.size) else { return nil }
        return (geometry.toImage(convert(event.locationInWindow, from: nil)), geometry.scale)
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

    /// True while the left button draws or moves a measurement.
    private var measuring = false

    override func mouseDown(with event: NSEvent) {
        begin(event)
        dragged = false
        guard let viewport else { return }
        rotateBase = viewport.freeAngle
        rotateAccumulator = 0
        if tool == .navigate, !event.modifierFlags.contains(.command), event.clickCount == 1,
           let (point, scale) = imagePoint(event), let drag = mpr.begin(point, scale) {
            mprDragging = true
            cursor(for: drag)?.set()
            return
        }
        if let (point, scale) = imagePoint(event), !event.modifierFlags.contains(.command) {
            viewport.pointerDown(at: point, scale: scale)
            measuring = viewport.dragging != nil
        }
        if !measuring && event.clickCount == 2 { onDoubleClick() }
    }

    override func mouseUp(with event: NSEvent) {
        if mprDragging {
            mprDragging = false
            mpr.end()
            restoreCursor()
            return
        }
        restoreCursor()
        if measuring, let (_, scale) = imagePoint(event) {
            viewport?.pointerUp(scale: scale)
        } else if !dragged, event.clickCount == 1, let (point, _) = imagePoint(event) {
            onClick(point)
        }
        measuring = false
    }

    override func rightMouseDown(with event: NSEvent) {
        begin(event)
        zoomAnchor = lastPoint
        showDuring(ToolCursor.zoom)
    }

    override func rightMouseUp(with event: NSEvent) { restoreCursor() }

    override func otherMouseUp(with event: NSEvent) { restoreCursor() }

    override func otherMouseDown(with event: NSEvent) {
        begin(event)
        showDuring(ToolCursor.pan)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewport else { return }
        dragged = true
        if mprDragging {
            if let (point, _) = imagePoint(event) { mpr.drag(point) }
            return
        }
        if measuring, let (point, scale) = imagePoint(event) {
            viewport.pointerDragged(to: point, scale: scale)
            return
        }
        let d = delta(event)
        if viewport.tool == .rotate && !event.modifierFlags.contains(.command) {
            // Turn by the change in the pointer's angle around the viewport center.
            let point = convert(event.locationInWindow, from: nil)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let previous = CGPoint(x: point.x - d.width, y: point.y - d.height)
            let before = atan2(previous.y - center.y, previous.x - center.x)
            let after = atan2(point.y - center.y, point.x - center.x)
            var turn = Double(after - before)
            if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
            rotateAccumulator += turn
            if event.modifierFlags.contains(.shift) {
                // Shift: steps of 15 degrees.
                let step = Double.pi / 12
                viewport.freeAngle = ((rotateBase + rotateAccumulator) / step).rounded() * step
            } else {
                viewport.freeAngle = rotateBase + rotateAccumulator
            }
            return
        }
        if viewport.tool == .scroll && !event.modifierFlags.contains(.command) {
            // Scroll tool: four points of drag per image, down goes forward.
            scrollDrag += d.height
            let steps = Int(scrollDrag / 4)
            if steps != 0 {
                viewport.step(steps)
                scrollDrag -= CGFloat(steps) * 4
            }
            return
        }
        if event.modifierFlags.contains(.command) {
            showDuring(ToolCursor.pan)
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
        // Trackpads send many small deltas, wheels a few large ones. With
        // Shift held, macOS turns a mouse wheel into horizontal scrolling.
        let alone = event.modifierFlags.contains(.shift)
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : (alone ? event.scrollingDeltaX : 0)
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
        scrollRemainder += raw / unit
        let steps = Int(scrollRemainder)
        if steps != 0 {
            alone ? viewport.stepAlone(-steps) : viewport.step(-steps)
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

    /// ⌘R resets the whole view: window, zoom, pan, rotation, flips.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            viewport?.reset()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let viewport else { return super.keyDown(with: event) }
        if event.keyCode == 53 {  // Escape
            viewport.cancelDraft()
            onEscape()
            return
        }
        switch event.specialKey {
        case .delete, .deleteForward, .backspace: viewport.deleteSelected()
        case .upArrow: event.modifierFlags.contains(.shift) ? viewport.stepAlone(-1) : viewport.step(-1)
        case .downArrow: event.modifierFlags.contains(.shift) ? viewport.stepAlone(1) : viewport.step(1)
        case .pageUp: viewport.step(-10)
        case .pageDown: viewport.step(10)
        case .home: viewport.step(-viewport.index)
        case .end: viewport.step(viewport.count - 1 - viewport.index)
        default:
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if event.modifierFlags.contains(.control) && (key == "r" || key == "l") {
                viewport.rotate(clockwise: key == "r")   // ⌃R right, ⌃L left
            } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let tool = ToolKeys.shared.tool(for: key) {
                onTool(tool)
            } else if let digit = Int(key), let preset = WindowPreset(rawValue: digit) {
                viewport.apply(preset)
            } else if key == " " {
                viewport.togglePlay()
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
