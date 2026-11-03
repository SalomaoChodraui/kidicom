import KidicomKit
import MetalKit
import SwiftUI
import simd

/// The 3D view: left-drag rotates, right-drag zooms, wheel-button drag
/// pans, Shift-left-drag sets the window, double-click resets.
struct VolumeView: NSViewRepresentable {
    let session: VolumeSession

    func makeNSView(context: Context) -> VolumeMTKView {
        let view = VolumeMTKView(frame: .zero, device: session.renderer.device)
        view.session = session
        view.delegate = session.renderer
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return view
    }

    func updateNSView(_ view: VolumeMTKView, context: Context) {
        session.renderer.camera = session.camera
        view.needsDisplay = true
    }
}

final class VolumeMTKView: MTKView {
    var session: VolumeSession?
    private var last: CGPoint?
    private var idle: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

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
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
            session.adjustWindow(dx: d.width, dy: -d.height)
        } else {
            session.rotate(dx: Float(d.width), dy: Float(d.height))
        }
    }

    override func rightMouseDown(with event: NSEvent) { begin(event) }

    override func rightMouseDragged(with event: NSEvent) {
        interacting()
        session?.zoom(by: exp(Float(delta(event).height) * 0.01))
    }

    override func otherMouseDown(with event: NSEvent) { begin(event) }

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

    var body: some View {
        VolumeView(session: session)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(study.displayName)
                    Text(session.title)
                    Text(session.camera.preset.title)
                }
                .padding(Space.sm)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(localized: "WL \(Int(session.camera.window.center.rounded())) WW \(Int(session.camera.window.width.rounded()))"))
                    Text(String(localized: "Zoom \(Int((session.camera.zoom * 100).rounded()))%"))
                }
                .padding(Space.sm)
            }
            .overlay(alignment: .bottomLeading) {
                Text("Drag: rotate · Shift-drag or ⌘-drag: window/level · Right-drag: zoom · Wheel button: pan")
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(Space.sm)
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 1, x: 0, y: 1)
    }
}
