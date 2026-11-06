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
    /// The series behind a plane reformatted in this viewport (Coronal of an
    /// axial CT, say); nil while it shows the series itself.
    var reformatBase: SeriesStack?
    /// The series this viewport comes from, reformatted or not.
    var baseStack: SeriesStack? { stack ?? reformatBase }
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
    /// Called on ⌘R or double-click reset (MPR straightens its planes).
    @ObservationIgnored var onReset: (() -> Void)?
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
    /// Free rotation in radians (Rotate tool), on top of the quarter turns.
    var freeAngle: Double = 0
    private(set) var image: CGImage?
    private(set) var slice: DecodedSlice?

    // Measurements (S-013, S-014); see Measurements.swift.
    var tool: MeasureTool = .navigate
    var measurements: [Measurement] = []
    var draft: Measurement?
    var selected: UUID?
    @ObservationIgnored var dragging: (UUID, Int)?
    /// Last pointer position while an area is dragged whole.
    @ObservationIgnored var moveFrom: CGPoint?
    /// True while the click that ends a click-to-click ruler is down.
    @ObservationIgnored var endingRuler = false

    /// Where the current image sits in a view of this size.
    func geometry(in size: CGSize) -> ViewportGeometry? {
        guard let slice, size.width > 0 else { return nil }
        return ViewportGeometry(imageSize: CGSize(width: slice.width, height: slice.height), viewSize: size, zoom: zoom,
                                pan: pan, quarterTurns: quarterTurns, flipHorizontal: flipHorizontal, flipVertical: flipVertical,
                                freeAngle: freeAngle)
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
        if stack is SeriesStack { reformatBase = nil }
        if source?.id != stack.id {
            pause()
            measurements = []
            draft = nil
            cancelLoad()
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

    /// Bumped by every draw request; a result applies only if it is still the newest.
    @ObservationIgnored private var requestID = 0

    /// The request whose picture is on screen.
    @ObservationIgnored private var shownID = 0
    /// The source a frame is loading from; scrolling meanwhile queues only the newest frame.
    @ObservationIgnored private var loadingFrom: (any FrameSource)?
    @ObservationIgnored private var loadToken = 0

    func go(to newIndex: Int) {
        guard let stack = source, stack.count > 0 else { return }
        requestID += 1
        index = min(max(0, newIndex), stack.count - 1)
        if let hit = stack.cached(index) {
            slice = hit
            shownID = requestID
            render()
        } else if loadingFrom !== stack {
            cancelLoad()
            loadToken += 1
            loadingFrom = stack
            let token = loadToken
            renderTask = Task { await self.loadNewest(from: stack, token: token) }
        }
        stack.prefetch(around: index)
    }

    private func cancelLoad() {
        renderTask?.cancel()
        loadingFrom = nil
    }

    /// Loads one frame at a time and shows each one as it arrives, then the
    /// newest frame asked for meanwhile. A fast scroll through frames that
    /// take a while (MPR reformats) shows every frame it can, instead of
    /// throwing away each one that arrives after the next scroll step.
    private func loadNewest(from stack: any FrameSource, token: Int) async {
        defer { if loadToken == token { loadingFrom = nil } }
        while !Task.isCancelled, source === stack, shownID < requestID {
            let id = requestID, target = index
            guard let loaded = await stack.load(target) else { break }
            guard !Task.isCancelled, source === stack else { break }
            // A cached frame shown meanwhile is newer than this one.
            if shownID < id {
                slice = loaded
                shownID = id
                render()
            }
        }
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
        reformatBase = nil
        cancelLoad()
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
        freeAngle = 0
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
        return Orientation.edges(source.orientation(index), angle: Double(quarterTurns) * .pi / 2 + freeAngle,
                                 flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    func reset() {
        window = nil
        resetView()
        onReset?()
    }

    var location: Double? { source?.location(index) }

    /// Draws the current frame again after the source changed it (slab, MIP).
    func reload() {
        slice = nil
        go(to: index)
    }

    @ObservationIgnored private(set) var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    /// Redraws while the source keeps changing (tilting MPR planes): the
    /// old picture stays up, and only the newest request runs after the
    /// one in flight, so the view never goes black mid-drag.
    func refresh(to newIndex: Int) {
        guard let source, source.count > 0 else { return }
        index = min(max(0, newIndex), source.count - 1)
        if refreshing { refreshAgain = true; return }
        refreshing = true
        cancelLoad()
        Task {
            while true {
                refreshAgain = false
                requestID += 1
                let id = requestID, target = index
                let loaded = await source.load(target)
                // A newer request (scroll, slab, another series) wins over this one.
                guard id == requestID, self.source === source else { break }
                if let loaded {
                    self.slice = loaded
                    self.shownID = id
                    self.render()
                }
                if !refreshAgain { break }
            }
            refreshing = false
        }
    }

    private func render() {
        guard let slice, let window = effectiveWindow else { image = nil; return }
        image = Renderer.image(slice.frame, width: slice.width, height: slice.height, window: window, inverted: slice.inverted)
    }
}
