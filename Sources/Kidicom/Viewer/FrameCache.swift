import Dispatch
import Foundation
import KidicomKit

/// Decoded frames of every open series in every window, under one budget in
/// bytes. The least recently viewed frames go first; memory pressure from
/// the system empties it down to what is on screen.
final class FrameCache {
    static let shared = FrameCache(budget: frameCacheBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory))

    struct Key: Hashable {
        let owner: UUID
        let index: Int
    }

    private var frames: ByteLRU<Key, DecodedSlice>
    private var pressure: DispatchSourceMemoryPressure?

    init(budget: Int) {
        frames = ByteLRU(limit: budget)
    }

    var budget: Int {
        get { frames.limit }
        set { frames.limit = newValue }
    }
    var totalBytes: Int { frames.totalCost }
    var count: Int { frames.count }

    /// The frame, now the most recently used.
    func frame(_ owner: UUID, _ index: Int) -> DecodedSlice? {
        frames.value(for: Key(owner: owner, index: index))
    }

    func contains(_ owner: UUID, _ index: Int) -> Bool {
        frames.contains(Key(owner: owner, index: index))
    }

    func store(_ slice: DecodedSlice, owner: UUID, index: Int) {
        startWatchingPressure()
        frames.insert(slice, cost: slice.byteCount, for: Key(owner: owner, index: index))
    }

    /// Drops every frame of one series.
    func removeAll(of owner: UUID) {
        frames.removeAll { $0.owner == owner }
    }

    func frameCount(of owner: UUID) -> Int {
        frames.orderedKeys.reduce(0) { $0 + ($1.owner == owner ? 1 : 0) }
    }

    /// The system is short of memory: keep a quarter on a warning, only the
    /// newest frame when critical. Viewports keep the frame they show.
    func relieve(critical: Bool) {
        frames.trim(to: critical ? 0 : frames.limit / 4)
        FrameReaderCache.shared.removeAll()
    }

    private func startWatchingPressure() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { self?.relieve(critical: critical) }
        }
        source.activate()
        pressure = source
    }
}

extension DecodedSlice {
    /// Bytes held by the decoded pixels.
    var byteCount: Int {
        switch frame {
        case .grayscale(let values): values.count * MemoryLayout<Float>.stride
        case .color(let rgba): rgba.count
        }
    }
}
