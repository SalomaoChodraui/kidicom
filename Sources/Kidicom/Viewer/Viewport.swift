import CoreGraphics
import Foundation
import KidicomKit

/// What one viewport shows: a series, the current frame, window, zoom, pan.
@Observable
final class Viewport: Identifiable {
    let id = UUID()
    private(set) var source: (any FrameSource)?
    /// The source when it is a series of files.
    var stack: SeriesStack? { source as? SeriesStack }
    private(set) var index = 0
    /// The person's window; nil follows each frame's own default.
    var window: VOIWindow? {
        didSet {
            render()
            if !quietWindow { onWindowChange?(window) }
        }
    }
    /// Called when the person changes the window (MPR keeps planes in sync).
    @ObservationIgnored var onWindowChange: ((VOIWindow?) -> Void)?
    /// Called after the person moves to another frame (scroll sync, S-031).
    @ObservationIgnored var onScroll: ((Viewport) -> Void)?
    /// Called after Shift-scroll moved this viewport alone, to keep its new offset.
    @ObservationIgnored var onAdjust: ((Viewport) -> Void)?
    /// mm added to this viewport's slice location when scrolling in sync.
    var syncOffset: Double = 0
    @ObservationIgnored private var quietWindow = false

    func setWindowQuietly(_ newValue: VOIWindow?) {
        quietWindow = true
        window = newValue
        quietWindow = false
    }
    var zoom: CGFloat = 1 { didSet { if !quietView && zoom != oldValue { onViewChange?(self) } } }
    var pan: CGSize = .zero { didSet { if !quietView && pan != oldValue { onViewChange?(self) } } }
    /// Called when the person zooms or pans (Sync Zoom).
    @ObservationIgnored var onViewChange: ((Viewport) -> Void)?
    @ObservationIgnored private var quietView = false

    /// Copies zoom and pan without telling the others again.
    func setViewQuietly(zoom: CGFloat, pan: CGSize) {
        quietView = true
        self.zoom = zoom
        self.pan = pan
        quietView = false
    }
    /// Clockwise quarter turns of the displayed image.
    var quarterTurns = 0
    /// Mirrors, applied before the rotation.
    var flipHorizontal = false
    var flipVertical = false
    private(set) var image: CGImage?
    private(set) var slice: DecodedSlice?

    // Measurements (S-013, S-014); see Measurements.swift.
    var tool: MeasureTool = .navigate
    var measurements: [Measurement] = []
    var draft: Measurement?
    var selected: UUID?
    @ObservationIgnored var dragging: (UUID, Int)?

    /// Where the current image sits in a view of this size.
    func geometry(in size: CGSize) -> ViewportGeometry? {
        guard let slice, size.width > 0 else { return nil }
        return ViewportGeometry(imageSize: CGSize(width: slice.width, height: slice.height), viewSize: size, zoom: zoom,
                                pan: pan, quarterTurns: quarterTurns, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    private(set) var isPlaying = false

    /// Frames per second for cine: Frame Time, then Cine Rate, then 30.
    var framesPerSecond: Double {
        if let ms = slice?.frameTime, ms > 0 { return min(120, 1000 / ms) }
        if let rate = slice?.cineRate, rate > 0 { return min(120, rate) }
        return 30
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard count > 1, !isPlaying else { return }
        isPlaying = true
        playTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled, let self, self.isPlaying {
                deadline += .milliseconds(Int(1000 / self.framesPerSecond))
                try? await clock.sleep(until: deadline)
                if Task.isCancelled || !self.isPlaying { break }
                self.go(to: (self.index + 1) % max(1, self.count))
                // Fell behind (slow decode): restart the schedule from now.
                if clock.now > deadline + .milliseconds(200) { deadline = clock.now }
            }
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    func show(_ stack: any FrameSource, at index: Int? = nil) {
        if source?.id != stack.id {
            pause()
            measurements = []
            draft = nil
            renderTask?.cancel()
            slice = nil
            image = nil
            source = stack
            window = nil
            resetView()
        }
        go(to: index ?? stack.count / 2)
    }

    var count: Int { source?.count ?? 0 }

    var effectiveWindow: VOIWindow? { window ?? slice?.defaultWindow }

    func go(to newIndex: Int) {
        guard let stack = source, stack.count > 0 else { return }
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

    /// A move by the person: scroll, keys, cine. Others follow when synced.
    func step(_ delta: Int) {
        go(to: index + delta)
        onScroll?(self)
    }

    /// Shift-scroll: move this viewport alone and keep the new alignment.
    func stepAlone(_ delta: Int) {
        go(to: index + delta)
        onAdjust?(self)
    }

    /// Left-drag window/level: right widens, left narrows, up raises the
    /// level. Width changes by a factor, so a long drag never collapses it
    /// and the feel is the same for CT (thousands) and ultrasound (256).
    func adjustWindow(dx: CGFloat, dy: CGFloat) {
        guard let current = effectiveWindow else { return }
        let width = min(100_000, max(2, current.width * exp(Double(dx) * 0.004)))
        let center = current.center - Double(dy) * current.width * 0.002
        window = VOIWindow(center: center, width: width)
    }

    /// Presets are in Hounsfield units, so they apply to grayscale only;
    /// 0 (file default) works on every image.
    func apply(_ preset: WindowPreset) {
        if slice?.isColor == true && preset != .fileDefault { return }
        window = WindowPresets.shared.window(for: preset)
    }

    /// Empties the viewport (its slot closed with ⌘W).
    func clear() {
        pause()
        renderTask?.cancel()
        source = nil
        slice = nil
        image = nil
        window = nil
        measurements = []
        draft = nil
        syncOffset = 0
        resetView()
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
        guard let source else { return nil }
        return Orientation.edges(source.orientation(index), quarterTurns: quarterTurns,
                                 flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    func reset() {
        window = nil
        resetView()
    }

    var location: Double? { source?.location(index) }

    /// Draws the current frame again after the source changed it (slab, MIP).
    func reload() {
        slice = nil
        go(to: index)
    }

    private func render() {
        guard let slice, let window = effectiveWindow else { image = nil; return }
        image = Renderer.image(slice.frame, width: slice.width, height: slice.height, window: window, inverted: slice.inverted)
    }
}
