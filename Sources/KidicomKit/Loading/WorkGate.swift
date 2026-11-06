import Foundation

/// Runs at most `limit` jobs at once and starts waiting jobs by priority,
/// highest first, then in arrival order. A job can also have a lower
/// ceiling: it starts only while fewer than that many jobs run, which keeps
/// slots free for the frame on screen while prefetch runs.
///
/// A job cancelled while it waits never runs and returns nil.
public actor WorkGate {
    public nonisolated let limit: Int

    private struct Waiter {
        let id: UUID
        var priority: Int
        var ceiling: Int
        let order: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var running = 0
    private var waiting: [Waiter] = []
    private var arrivals = 0

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Jobs started and not finished.
    public var runningCount: Int { running }
    /// Jobs waiting for a slot.
    public var waitingCount: Int { waiting.count }

    public func run<T: Sendable>(
        id: UUID = UUID(), priority: Int, ceiling: Int? = nil,
        _ operation: @Sendable () async -> T
    ) async -> T? {
        let ceiling = min(limit, max(1, ceiling ?? limit))
        guard await admit(id: id, priority: priority, ceiling: ceiling) else { return nil }
        defer { finish() }
        return await operation()
    }

    /// Raises a waiting job's priority, and its ceiling if given; a job
    /// already running is left alone.
    public func promote(_ id: UUID, to priority: Int, ceiling: Int? = nil) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[i].priority = max(waiting[i].priority, priority)
        if let ceiling { waiting[i].ceiling = max(waiting[i].ceiling, min(limit, ceiling)) }
        startWaiting()
    }

    private func admit(id: UUID, priority: Int, ceiling: Int) async -> Bool {
        if Task.isCancelled { return false }
        if running < ceiling && waiting.isEmpty {
            running += 1
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                arrivals += 1
                waiting.append(Waiter(id: id, priority: priority, ceiling: ceiling, order: arrivals, continuation: continuation))
                startWaiting()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).continuation.resume(returning: false)
    }

    private func finish() {
        running -= 1
        startWaiting()
    }

    /// Starts the best waiting jobs that fit.
    private func startWaiting() {
        while true {
            var best: Int?
            for (i, w) in waiting.enumerated() where running < w.ceiling {
                if let b = best {
                    let current = waiting[b]
                    if w.priority > current.priority || (w.priority == current.priority && w.order < current.order) { best = i }
                } else {
                    best = i
                }
            }
            guard let best else { return }
            running += 1
            waiting.remove(at: best).continuation.resume(returning: true)
        }
    }
}
