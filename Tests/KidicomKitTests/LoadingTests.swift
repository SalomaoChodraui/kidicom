import Foundation
import Testing
@testable import KidicomKit

@Suite("Frame cache")
struct ByteLRUTests {
    @Test("drops the least recently used past the budget, and reading counts as use")
    func lru() {
        var cache = ByteLRU<Int, String>(limit: 30)
        cache.insert("a", cost: 10, for: 1)
        cache.insert("b", cost: 10, for: 2)
        cache.insert("c", cost: 10, for: 3)
        #expect(cache.value(for: 1) == "a")   // 1 is now the newest
        cache.insert("d", cost: 10, for: 4)
        #expect(cache.contains(1) && !cache.contains(2) && cache.contains(3) && cache.contains(4))
        #expect(cache.totalCost == 30)
        #expect(cache.orderedKeys == [4, 1, 3])
    }

    @Test("peek leaves the order alone")
    func peek() {
        var cache = ByteLRU<Int, Int>(limit: 20)
        cache.insert(1, cost: 10, for: 1)
        cache.insert(2, cost: 10, for: 2)
        #expect(cache.peek(1) == 1)
        cache.insert(3, cost: 10, for: 3)
        #expect(!cache.contains(1))
    }

    @Test("a value bigger than the whole budget stays alone, and a new one replaces it")
    func oversized() {
        var cache = ByteLRU<Int, Int>(limit: 100)
        cache.insert(1, cost: 40, for: 1)
        cache.insert(2, cost: 500, for: 2)
        #expect(cache.count == 1 && cache.contains(2) && cache.totalCost == 500)
        cache.insert(3, cost: 10, for: 3)
        #expect(cache.count == 1 && cache.contains(3) && cache.totalCost == 10)
    }

    @Test("replacing, removing and trimming keep the total right")
    func bookkeeping() {
        var cache = ByteLRU<String, Int>(limit: 1000)
        for i in 0 ..< 10 { cache.insert(i, cost: 10, for: "k\(i)") }
        cache.insert(99, cost: 50, for: "k3")
        #expect(cache.totalCost == 140 && cache.count == 10)
        cache.remove("k0")
        cache.removeAll { $0 == "k1" || $0 == "k2" }
        #expect(cache.totalCost == 110 && cache.count == 7)
        cache.trim(to: 60)
        #expect(cache.totalCost <= 60 && cache.contains("k3"))
        cache.limit = 0
        #expect(cache.count == 1)
        cache.removeAll()
        #expect(cache.isEmpty && cache.totalCost == 0)
    }

    @Test("the budget follows the Mac's memory")
    func budget() {
        let gib: UInt64 = 1 << 30
        #expect(frameCacheBudget(physicalMemory: 16 * gib) == 1 << 30)
        #expect(frameCacheBudget(physicalMemory: 2 * gib) == 256 << 20)
        #expect(frameCacheBudget(physicalMemory: 128 * gib) == 2 << 30)
    }
}

@Suite("Prefetch")
struct PrefetchTests {
    @Test("scrolling forward decodes mostly ahead, nearest first")
    func forward() {
        let plan = PrefetchPlan.indices(around: 50, direction: 1, count: 200, ahead: 6, behind: 2)
        #expect(plan == [51, 52, 49, 53, 54, 48, 55, 56])
    }

    @Test("scrolling back decodes mostly behind")
    func backward() {
        let plan = PrefetchPlan.indices(around: 50, direction: -1, count: 200, ahead: 4, behind: 1)
        #expect(plan == [49, 48, 51, 47, 46])
    }

    @Test("a series just shown decodes both sides alike")
    func still() {
        #expect(PrefetchPlan.indices(around: 5, direction: 0, count: 100, still: 2) == [6, 4, 7, 3])
    }

    @Test("stays inside the series, or wraps for a cine")
    func edges() {
        #expect(PrefetchPlan.indices(around: 9, direction: 1, count: 10, ahead: 3, behind: 1) == [8])
        #expect(PrefetchPlan.indices(around: 9, direction: 1, count: 10, wraps: true, ahead: 3, behind: 1) == [0, 1, 8, 2])
        #expect(PrefetchPlan.indices(around: 0, direction: 1, count: 1) == [])
    }

    @Test("never asks for more frames than the cache holds")
    func budget() {
        #expect(PrefetchPlan.indices(around: 50, direction: 1, count: 200, budget: 3).count == 3)
        #expect(PrefetchPlan.indices(around: 50, direction: 1, count: 200, budget: 0).isEmpty)
    }

    @Test("a frame far from the current one is stale")
    func stale() {
        #expect(!PrefetchPlan.isStale(60, around: 50, count: 200, reach: 16))
        #expect(PrefetchPlan.isStale(80, around: 50, count: 200, reach: 16))
        #expect(!PrefetchPlan.isStale(1, around: 198, count: 200, wraps: true, reach: 16))
    }
}

@Suite("Nearest slice")
struct LocationIndexTests {
    /// The scan the viewer used before.
    func linear(_ locations: [Double?], _ target: Double) -> Int? {
        var best: Int?, distance = Double.infinity
        for (i, l) in locations.enumerated() {
            if let l, abs(l - target) < distance { distance = abs(l - target); best = i }
        }
        return best
    }

    @Test("binary search finds what the scan finds, both ways, ties to the lower index")
    func matchesScan() {
        let ascending: [Double?] = stride(from: -60.0, through: 60, by: 2.5).map { $0 }
        let descending = Array(ascending.reversed())
        for locations in [ascending, descending] {
            let index = LocationIndex(locations)
            #expect(index.usesBinarySearch)
            for target in stride(from: -70.0, through: 70, by: 0.25) {
                #expect(index.nearest(to: target) == linear(locations, target), "target \(target)")
            }
        }
    }

    @Test("repeats, gaps and mixed order fall back to the scan")
    func fallback() {
        let cases: [[Double?]] = [[0, 0, 0, 1], [0, nil, 2, 3], [0, 3, 1, 2], [nil, nil], [5]]
        for locations in cases {
            let index = LocationIndex(locations)
            #expect(!index.usesBinarySearch || locations.count < 2)
            for target in [-1.0, 0, 0.4, 1.5, 2.6, 9] {
                #expect(index.nearest(to: target) == linear(locations, target))
            }
        }
        #expect(LocationIndex([]).nearest(to: 0) == nil)
    }
}

@Suite("Work gate")
struct WorkGateTests {
    @Test("never runs more than the limit at once")
    func limit() async {
        let gate = WorkGate(limit: 3)
        let peak = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    _ = await gate.run(priority: 0) {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await peak.leave()
                    }
                }
            }
        }
        #expect(await peak.max == 3)
        #expect(await gate.runningCount == 0)
    }

    @Test("starts the highest priority first, and a ceiling keeps a slot free")
    func priority() async throws {
        let gate = WorkGate(limit: 2)
        let log = Log()
        let release = Latch()
        // Hold one slot.
        let holder = Task { _ = await gate.run(priority: 0) { await release.wait() } }
        try await waitUntil { await gate.runningCount == 1 }
        // A low job with ceiling 1 cannot start while one runs.
        let low = Task { _ = await gate.run(priority: 0, ceiling: 1) { await log.add("low") } }
        try await waitUntil { await gate.waitingCount == 1 }
        // A display job still finds the free slot.
        _ = await gate.run(priority: 10) { await log.add("display") }
        let promoted = UUID()
        let later = Task { _ = await gate.run(id: promoted, priority: 0, ceiling: 1) { await log.add("promoted") } }
        try await waitUntil { await gate.waitingCount == 2 }
        await gate.promote(promoted, to: 5)
        await release.open()
        _ = await (holder.value, low.value, later.value)
        #expect(await log.items == ["display", "promoted", "low"])
    }

    @Test("a job cancelled while it waits does not run")
    func cancel() async throws {
        let gate = WorkGate(limit: 1)
        let release = Latch()
        let holder = Task { _ = await gate.run(priority: 0) { await release.wait() } }
        try await waitUntil { await gate.runningCount == 1 }
        let ran = Log()
        let waiter = Task { await gate.run(priority: 0) { await ran.add("ran"); return 1 } }
        try await waitUntil { await gate.waitingCount == 1 }
        waiter.cancel()
        #expect(await waiter.value == nil)
        await release.open()
        await holder.value
        #expect(await ran.items.isEmpty)
        #expect(await gate.waitingCount == 0)
    }

    func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out")
    }
}

private actor Counter {
    var now = 0, max = 0
    func enter() { now += 1; max = Swift.max(max, now) }
    func leave() { now -= 1 }
}

private actor Log {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

private actor Latch {
    var isOpen = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
    }
}

@Suite("Multiframe")
struct FrameReaderTests {
    @Test("every frame of a cine decodes the same with the offset table, without it, and through the reader")
    func frames() throws {
        for table in [true, false] {
            let file = try DicomParser.parse(rleCine(frames: 40, offsetTable: table))
            let reader = try FrameReader(file)
            for i in 0 ..< 40 {
                guard case .grayscale(let direct) = try file.frame(i), case .grayscale(let read) = try reader.frame(i) else {
                    Issue.record("not gray"); return
                }
                #expect(direct == read)
                #expect(read.allSatisfy { $0 == Float(i) })
            }
            #expect(throws: DicomError.self) { try reader.frame(40) }
        }
    }

    @Test("the reader cache keeps a few multiframe files and skips single frames")
    func cache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidicom-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FrameReaderCache(capacity: 2)
        var urls: [URL] = []
        for i in 0 ..< 3 {
            let url = dir.appendingPathComponent("cine\(i).dcm")
            try rleCine(frames: 4).write(to: url)
            urls.append(url)
        }
        let single = dir.appendingPathComponent("single.dcm")
        try grayImage(stored: [1, 2, 3, 4]).write(to: single)
        _ = try cache.reader(for: single)
        #expect(cache.count == 0)
        for url in urls { _ = try cache.reader(for: url) }
        #expect(cache.count == 2)
        guard case .grayscale(let values) = try cache.reader(for: urls[2]).frame(3) else { Issue.record("not gray"); return }
        #expect(values.first == 3)
    }
}
