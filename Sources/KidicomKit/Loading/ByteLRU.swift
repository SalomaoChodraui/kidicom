import Foundation

/// A least recently used cache with a budget in bytes. Reading a value makes
/// it the most recent; inserting past the budget drops the least recent
/// values. The newest value always stays, even when it alone is over budget,
/// so the frame on screen is never thrown away.
public struct ByteLRU<Key: Hashable, Value> {
    private struct Node {
        var value: Value
        var cost: Int
        /// Toward the most recent.
        var newer: Key?
        /// Toward the least recent.
        var older: Key?
    }

    private var nodes: [Key: Node] = [:]
    private var newest: Key?
    private var oldest: Key?
    public private(set) var totalCost = 0
    public var limit: Int {
        didSet { trim(to: limit) }
    }

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }

    public func contains(_ key: Key) -> Bool { nodes[key] != nil }

    /// The value without changing its place in the order.
    public func peek(_ key: Key) -> Value? { nodes[key]?.value }

    /// The value, now the most recent.
    public mutating func value(for key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToNewest(key)
        return node.value
    }

    /// Keys from the most recent to the least recent.
    public var orderedKeys: [Key] {
        var out: [Key] = []
        var cursor = newest
        while let key = cursor {
            out.append(key)
            cursor = nodes[key]?.older
        }
        return out
    }

    /// Stores a value as the most recent and drops old ones past the budget.
    public mutating func insert(_ value: Value, cost: Int, for key: Key) {
        if nodes[key] != nil { remove(key) }
        let cost = max(0, cost)
        nodes[key] = Node(value: value, cost: cost, newer: nil, older: newest)
        if let newest { nodes[newest]?.newer = key }
        newest = key
        if oldest == nil { oldest = key }
        totalCost += cost
        trim(to: limit)
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        if let newer = node.newer { nodes[newer]?.older = node.older } else { newest = node.older }
        if let older = node.older { nodes[older]?.newer = node.newer } else { oldest = node.newer }
        totalCost -= node.cost
        return node.value
    }

    public mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in nodes.keys where shouldRemove(key) { remove(key) }
    }

    public mutating func removeAll() {
        nodes = [:]
        newest = nil
        oldest = nil
        totalCost = 0
    }

    /// Drops the least recent values until the total fits `budget`, keeping
    /// at least the newest one.
    public mutating func trim(to budget: Int) {
        while totalCost > budget, nodes.count > 1, let oldest { remove(oldest) }
    }

    private mutating func moveToNewest(_ key: Key) {
        guard newest != key, let node = nodes[key] else { return }
        // Unlink.
        if let newer = node.newer { nodes[newer]?.older = node.older }
        if let older = node.older { nodes[older]?.newer = node.newer } else { oldest = node.newer }
        // Link at the front.
        nodes[key]?.older = newest
        nodes[key]?.newer = nil
        if let newest { nodes[newest]?.newer = key }
        newest = key
    }
}


/// How many bytes of decoded frames to keep in memory, for a Mac with this
/// much RAM: a sixteenth of it, between 256 MiB and 2 GiB (1 GiB on 16 GB).
public func frameCacheBudget(physicalMemory: UInt64) -> Int {
    let mib = 1 << 20
    let share = Int(min(physicalMemory / 16, UInt64(Int.max)))
    return min(2048 * mib, max(256 * mib, share))
}
