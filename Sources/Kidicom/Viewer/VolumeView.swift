import KidicomKit
import MetalKit
import SwiftUI
import simd

/// The 3D view: left-drag follows the viewer's tool (Window/Level sets the
/// window, any other tool rotates); Shift or ⌘ swaps the two. Right-drag
/// zooms, wheel-button drag pans, double-click resets.
struct VolumeView: NSViewRepresentable {
    let session: VolumeSession
    /// ⌘C: the rendering, its size in points, and pixels per point.
    var onCopy: (CGImage, CGSize, CGFloat) -> Void = { _, _, _ in }

    func makeNSView(context: Context) -> VolumeMTKView {
        let view = VolumeMTKView(frame: .zero, device: session.renderer.device)
        view.session = session
        view.onCopy = onCopy
        view.delegate = session.renderer
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return view
    }

    func updateNSView(_ view: VolumeMTKView, context: Context) {
        session.renderer.camera = session.camera
        view.onCopy = onCopy
        view.toolWindows = session.tool == .navigate
        view.needsDisplay = true
    }
}

final class VolumeMTKView: MTKView {
    var session: VolumeSession?
    var onCopy: (CGImage, CGSize, CGFloat) -> Void = { _, _, _ in }

    /// Edit > Copy (⌘C): the volume as shown.
    @objc func copy(_ sender: Any?) {
        let scale = window?.backingScaleFactor ?? 2
        guard let session, bounds.width >= 1, bounds.height >= 1,
              let image = session.renderer.renderImage(width: Int(bounds.width * scale), height: Int(bounds.height * scale)) else {
            return NSSound.beep()
        }
        onCopy(image, bounds.size, scale)
    }
    private var last: CGPoint?
    private var idle: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    /// True when the viewer's tool is Window/Level.
    var toolWindows = false {
        didSet { if toolWindows != oldValue { updateMode() } }
    }
    private var modifierHeld = false {
        didSet { if modifierHeld != oldValue { updateMode() } }
    }
    /// Left-drag sets the window: the tool, swapped while Shift or ⌘ is held.
    private var windowMode: Bool { toolWindows != modifierHeld }

    private func updateMode() {
        window?.invalidateCursorRects(for: self)
        if window?.isKeyWindow == true, let point = window?.mouseLocationOutsideOfEventStream,
           bounds.contains(convert(point, from: nil)) {
            currentCursor.set()
        }
    }
    private var currentCursor: NSCursor { windowMode ? ToolCursor.cursor(for: .navigate) : ToolCursor.rotate }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    override func flagsChanged(with event: NSEvent) {
        modifierHeld = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        super.flagsChanged(with: event)
    }

    override func mouseUp(with event: NSEvent) { currentCursor.set() }
    override func rightMouseUp(with event: NSEvent) { currentCursor.set() }
    override func otherMouseUp(with event: NSEvent) { currentCursor.set() }

    /// ⌘R resets the camera, like the 2D views.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            session?.resetCamera()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The tool keys work here as in 2D: the Window/Level key makes
    /// left-drag set the window, the Scroll and Rotate keys make it turn the volume.
    override func keyDown(with event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let tool = ToolKeys.shared.tool(for: key), tool == .navigate || tool == .scroll || tool == .rotate {
            session?.onTool(tool)
        } else {
            super.keyDown(with: event)
        }
    }

    private func begin(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        last = convert(event.locationInWindow, from: nil)
    }

    private func delta(_ event: NSEvent) -> CGSize {
        let p = convert(event.locationInWindow, from: nil)
        defer { last = p }
        guard let last else { return .zero }
        return CGSize(width: p.x - last.x, height: p.y - last.y)
    }

    /// Low resolution while dragging; full a moment after the last move.
    private func interacting() {
        session?.renderer.interactive = true
        idle?.cancel()
        idle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.session?.renderer.interactive = false
            self.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        begin(event)
        if event.clickCount == 2 { session?.resetCamera() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }
        let d = delta(event)
        interacting()
        let swapped = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if toolWindows != swapped {
            session.adjustWindow(dx: d.width, dy: -d.height)
        } else {
            session.rotate(dx: Float(d.width), dy: Float(d.height))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        begin(event)
        ToolCursor.zoom.set()
    }

    override func rightMouseDragged(with event: NSEvent) {
        interacting()
        session?.zoom(by: exp(Float(delta(event).height) * 0.01))
    }

    override func otherMouseDown(with event: NSEvent) {
        begin(event)
        ToolCursor.pan.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        interacting()
        let d = delta(event)
        session?.panBy(dx: Float(d.width / max(bounds.height, 1)), dy: Float(d.height / max(bounds.height, 1)))
    }

    override func scrollWheel(with event: NSEvent) {
        interacting()
        session?.zoom(by: 1 + Float(event.scrollingDeltaY) * 0.01)
    }

    override func magnify(with event: NSEvent) {
        interacting()
        session?.zoom(by: 1 + Float(event.magnification))
    }
}

/// A 3D view of one volume: camera, look, and the renderer.
@Observable
final class VolumeSession {
    let volume: Volume
    let title: String
    @ObservationIgnored let renderer: VolumeRenderer
    var camera: VolumeCamera
    /// The viewer's left-button tool: Window/Level sets the window, any
    /// other rotates.
    var tool: MeasureTool = .scroll
    /// Picks a tool from a key pressed in the 3D view.
    @ObservationIgnored var onTool: (MeasureTool) -> Void = { _ in }
    /// The 2D window when 3D opened, for the Current Window preset.
    let currentWindow: VOIWindow
    /// A window from the volume's own values, for MR and other non-CT series.
    let automaticWindow: VOIWindow

    init?(volume: Volume, title: String, window: VOIWindow, modality: String) {
        let preset: VolumePreset = modality == "CT" ? .bone : .automatic
        let automatic = Self.automaticWindow(volume)
        var camera = VolumeCamera()
        camera.preset = preset
        camera.window = preset.window ?? (preset == .automatic ? automatic : window)
        guard let renderer = VolumeRenderer(volume: volume, camera: camera) else { return nil }
        self.volume = volume
        self.title = title
        self.renderer = renderer
        self.camera = camera
        currentWindow = window
        automaticWindow = automatic
    }

    /// Hides air and noise: from 20 to 90 percent of the 95th percentile.
    static func automaticWindow(_ volume: Volume) -> VOIWindow {
        let stride = max(1, volume.count / 200_000)
        var samples: [Float] = []
        samples.reserveCapacity(volume.count / stride + 1)
        volume.voxels.withUnsafeBufferPointer { v in
            for i in Swift.stride(from: 0, to: v.count, by: stride) { samples.append(Float(v[i])) }
        }
        samples.sort()
        let high = Double(samples.isEmpty ? 1 : samples[Int(Double(samples.count - 1) * 0.95)])
        return VOIWindow(center: high * 0.55, width: max(2, high * 0.7))
    }

    func apply(_ preset: VolumePreset) {
        camera.preset = preset
        camera.window = preset.window ?? (preset == .automatic ? automaticWindow : currentWindow)
    }

    func rotate(dx: Float, dy: Float) {
        // Horizontal drag turns around the screen's vertical axis, vertical drag around the horizontal one.
        // The surface under the pointer follows it: drag right turns the front
        // to the right, drag up tilts the top away. dy grows upward here.
        let yaw = simd_quatf(angle: -dx * 0.01, axis: [0, 1, 0])
        let pitch = simd_quatf(angle: dy * 0.01, axis: [1, 0, 0])
        camera.rotation = simd_normalize(yaw * pitch * camera.rotation)
    }

    func zoom(by factor: Float) {
        camera.zoom = min(20, max(0.2, camera.zoom * factor))
    }

    func panBy(dx: Float, dy: Float) {
        camera.pan += SIMD2(dx, dy)
    }

    func adjustWindow(dx: CGFloat, dy: CGFloat) {
        let w = camera.window
        camera.window = VOIWindow(center: w.center - Double(dy) * w.width * 0.002, width: min(100_000, max(2, w.width * exp(Double(dx) * 0.004))))
    }

    func resetCamera() {
        let preset = camera.preset
        camera = VolumeCamera()
        apply(preset)
    }
}

/// The image area while 3D is on: the rendering, its overlay, and the presets.
struct VolumePane: View {
    let session: VolumeSession
    let study: Study
    var level: OverlayLevel = .full

    var body: some View {
        VolumeView(session: session, onCopy: { image, size, scale in
            ImageCopy.copy(image, size: size, scale: scale) { data(hints: false) }
        })
        .overlay { data(hints: true).allowsHitTesting(false) }
    }

    /// The text over the volume, as Tab leaves it. The mouse hints stay off copies.
    private func data(hints: Bool) -> some View {
        ZStack {
            if level != .hidden {
                VStack(alignment: .leading, spacing: 0) {
                    if level == .full { Text(study.displayName) }
                    Text(session.title)
                    Text(session.camera.preset.title)
                }
                .padding(Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(localized: "WL \(Int(session.camera.window.center.rounded())) WW \(Int(session.camera.window.width.rounded()))"))
                    Text(String(localized: "Zoom \(Int((session.camera.zoom * 100).rounded()))%"))
                }
                .padding(Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                if hints {
                    Text(session.tool == .navigate
                         ? "Drag: window/level · Shift-drag: rotate · Right-drag: zoom · Wheel button: pan"
                         : "Drag: rotate · Shift-drag: window/level · Right-drag: zoom · Wheel button: pan")
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(Space.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 1, x: 0, y: 1)
    }
}
