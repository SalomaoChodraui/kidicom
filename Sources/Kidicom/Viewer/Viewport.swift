import CoreGraphics
import Foundation
import KidicomKit

/// What one viewport shows: a series, the current frame, window, zoom, pan.
@Observable
final class Viewport: Identifiable {
    let id = UUID()
    private(set) var stack: SeriesStack?
    private(set) var index = 0
    /// The person's window; nil follows each frame's own default.
    var window: Window? { didSet { render() } }
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// Clockwise quarter turns of the displayed image.
    var quarterTurns = 0
    /// Mirrors, applied before the rotation.
    var flipHorizontal = false
    var flipVertical = false
    private(set) var image: CGImage?
    private(set) var slice: DecodedSlice?

    @ObservationIgnored private var renderTask: Task<Void, Never>?

    func show(_ stack: SeriesStack, at index: Int? = nil) {
        if self.stack?.id != stack.id {
            self.stack = stack
            window = nil
            resetView()
        }
        go(to: index ?? stack.count / 2)
    }

    var count: Int { stack?.count ?? 0 }

    var effectiveWindow: Window? { window ?? slice?.defaultWindow }

    func go(to newIndex: Int) {
        guard let stack, stack.count > 0 else { return }
        index = min(max(0, newIndex), stack.count - 1)
        if let hit = stack.cached(index) {
            slice = hit
            render()
        } else {
            renderTask?.cancel()
            let target = index
            renderTask = Task {
                guard let loaded = await stack.load(target), !Task.isCancelled, self.index == target else { return }
                self.slice = loaded
                self.render()
            }
        }
        stack.prefetch(around: index)
    }

    func step(_ delta: Int) { go(to: index + delta) }

    /// Left-drag window/level: right widens, left narrows, up raises the
    /// level. Width changes by a factor, so a long drag never collapses it
    /// and the feel is the same for CT (thousands) and ultrasound (256).
    func adjustWindow(dx: CGFloat, dy: CGFloat) {
        guard let current = effectiveWindow else { return }
        let width = min(100_000, max(2, current.width * exp(Double(dx) * 0.004)))
        let center = current.center - Double(dy) * current.width * 0.002
        window = Window(center: center, width: width)
    }

    /// Presets are in Hounsfield units, so they apply to grayscale only;
    /// 0 (file default) works on every image.
    func apply(_ preset: WindowPreset) {
        if slice?.isColor == true && preset != .fileDefault { return }
        window = preset.window
    }

    func resetView() {
        zoom = 1
        pan = .zero
        quarterTurns = 0
        flipHorizontal = false
        flipVertical = false
    }

    func rotate(clockwise: Bool) {
        quarterTurns = ((quarterTurns + (clockwise ? 1 : -1)) % 4 + 4) % 4
    }

    /// Mirrors the image as seen on screen, whatever the rotation.
    func flip(horizontal: Bool) {
        // After an odd number of turns, the screen's horizontal is the image's vertical.
        if horizontal != (quarterTurns % 2 == 1) { flipHorizontal.toggle() } else { flipVertical.toggle() }
    }

    /// Patient direction letters on the screen edges, when the image has geometry.
    var edges: Orientation.Edges? {
        guard let stack, stack.slices.indices.contains(index) else { return nil }
        return Orientation.edges(stack.slices[index].orientation, quarterTurns: quarterTurns,
                                 flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    func reset() {
        window = nil
        resetView()
    }

    var location: Double? { stack.flatMap { $0.slices.indices.contains(index) ? $0.slices[index].location : nil } }

    private func render() {
        guard let slice, let window = effectiveWindow else { image = nil; return }
        image = Renderer.image(slice.frame, width: slice.width, height: slice.height, window: window, inverted: slice.inverted)
    }
}
