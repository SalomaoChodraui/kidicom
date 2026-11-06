import CoreGraphics
import Foundation

/// Decides when a viewport draws its picture. A request for what is on
/// screen already is dropped, many requests before the next draw become
/// one, one draw runs at a time, and a draw started before `clear()`
/// never reaches the screen. Not thread-safe: use it from one actor.
public struct RenderGate<Key: Equatable, Input> {
    /// One draw to do: what to draw and from which inputs.
    public struct Job {
        public let key: Key
        public let input: Input
        fileprivate let epoch: Int
    }

    /// What the picture on screen was drawn from.
    public private(set) var shown: Key?
    private var wanted: (key: Key, input: Input)?
    private var running = false
    private var flushPending = false
    private var epoch = 0

    public init() {}

    /// Asks for a picture of `key`. True when the caller must schedule a
    /// flush; false when one is scheduled, a draw is running (it picks up
    /// the newest request when it ends), or `key` is on screen already.
    public mutating func request(_ key: Key, _ input: Input) -> Bool {
        wanted = (key, input)
        if flushPending || running || key == shown { return false }
        flushPending = true
        return true
    }

    /// The next draw, or nil when there is nothing new or a draw runs.
    /// Call it when the flush runs and again after each `finish`.
    public mutating func next() -> Job? {
        flushPending = false
        guard !running, let wanted, wanted.key != shown else { return nil }
        running = true
        return Job(key: wanted.key, input: wanted.input, epoch: epoch)
    }

    /// Ends a draw. True when its picture should go on screen: it was not
    /// cleared meanwhile. Draws run one after another, so a finished draw
    /// is always newer than the picture on screen.
    public mutating func finish(_ job: Job) -> Bool {
        running = false
        guard job.epoch == epoch else { return false }
        shown = job.key
        return true
    }

    /// The viewport emptied: forget what is on screen and drop a draw in flight.
    public mutating func clear() {
        epoch += 1
        shown = nil
        wanted = nil
    }
}

public extension Frame {
    /// True when both hold the very same pixel buffer, so one picture
    /// drawn from either is the same. Cheap: compares storage, not pixels.
    func sharesStorage(with other: Frame) -> Bool {
        switch (self, other) {
        case let (.grayscale(a), .grayscale(b)):
            a.count == b.count && a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress } }
        case let (.color(a), .color(b)):
            a.count == b.count && a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress } }
        default:
            false
        }
    }
}

public extension Renderer {
    /// Frames this large draw on `queue`; smaller ones cost less than the
    /// trip to another thread and back, and draw where they are asked.
    /// Color costs about five times gray per pixel.
    static func drawsInBackground(_ frame: Frame, width: Int, height: Int) -> Bool {
        let cost = width * height * (frame.isColor ? 5 : 1)
        return cost > 1024 * 1024
    }

    /// The executor for large frames: concurrent, so synced viewports draw side by side.
    private static let queue = DispatchQueue(label: "Kidicom.render", qos: .userInteractive, attributes: .concurrent)

    /// `image(_:width:height:window:inverted:)` on the render queue.
    static func imageInBackground(_ frame: Frame, width: Int, height: Int, window: VOIWindow, inverted: Bool) async -> CGImage? {
        await withCheckedContinuation { done in
            queue.async {
                done.resume(returning: image(frame, width: width, height: height, window: window, inverted: inverted))
            }
        }
    }
}

extension Frame {
    var isColor: Bool {
        if case .color = self { return true }
        return false
    }
}
