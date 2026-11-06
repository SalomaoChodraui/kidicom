import Foundation

/// Which frames to decode ahead while the person looks at one.
public enum PrefetchPlan {
    /// Frames around `index`, nearest first, most of them in the direction of
    /// the scroll. With no direction (a series just shown), as many on each
    /// side. `wraps` for a cine, which loops back to the first frame.
    ///
    /// - Parameter budget: the most frames worth decoding, from what the
    ///   frame cache holds; the plan never asks for more.
    public static func indices(around index: Int, direction: Int, count: Int, wraps: Bool = false,
                               ahead: Int = 10, behind: Int = 3, still: Int = 6, budget: Int = .max) -> [Int] {
        guard count > 1, (0 ..< count).contains(index) else { return [] }
        let lead = direction < 0 ? -1 : 1
        let leadCount = direction == 0 ? still : ahead
        let trailCount = direction == 0 ? still : behind
        // The way the scroll goes first: two ahead for each one behind.
        let ratio = direction == 0 ? 1 : 2
        let room = max(0, min(budget, count - 1))
        var out: [Int] = []
        var seen: Set<Int> = [index]
        func add(_ offset: Int) {
            var i = index + offset
            if wraps { i = ((i % count) + count) % count }
            guard (0 ..< count).contains(i), seen.insert(i).inserted else { return }
            out.append(i)
        }
        var l = 1, t = 1
        while (l <= leadCount || t <= trailCount) && out.count < room {
            for _ in 0 ..< ratio where l <= leadCount {
                add(lead * l)
                l += 1
            }
            if t <= trailCount {
                add(-lead * t)
                t += 1
            }
        }
        return Array(out.prefix(room))
    }

    /// True when a frame waiting to be prefetched is no longer near enough to
    /// `index` to be worth decoding.
    public static func isStale(_ candidate: Int, around index: Int, count: Int, wraps: Bool = false, reach: Int = 16) -> Bool {
        var distance = abs(candidate - index)
        if wraps && count > 0 { distance = min(distance, count - distance) }
        return distance > reach
    }
}

/// Finds the slice nearest a position along the normal. Built once per
/// series: when positions run one way without repeats, a binary search;
/// otherwise (repeats, gaps, mixed order) a scan of every slice.
public struct LocationIndex: Sendable {
    private let locations: [Double?]
    /// +1 ascending, -1 descending, 0 when a binary search does not apply.
    private let direction: Int

    public init(_ locations: [Double?]) {
        self.locations = locations
        var direction = 0
        if locations.count >= 2, locations.allSatisfy({ $0 != nil }) {
            let values = locations.map { $0! }
            if zip(values, values.dropFirst()).allSatisfy({ $0 < $1 }) { direction = 1 }
            else if zip(values, values.dropFirst()).allSatisfy({ $0 > $1 }) { direction = -1 }
        }
        self.direction = direction
    }

    public var usesBinarySearch: Bool { direction != 0 }

    /// The index of the slice whose location is nearest `target`; the lowest
    /// index on a tie. Nil when no slice has a location.
    public func nearest(to target: Double) -> Int? {
        guard direction != 0 else { return linear(target) }
        let n = locations.count
        // First index whose location is at or past the target, going the series' way.
        var low = 0, high = n
        while low < high {
            let mid = (low + high) / 2
            let value = locations[mid]!
            if direction > 0 ? value < target : value > target { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == n { return n - 1 }
        let before = abs(locations[low - 1]! - target), after = abs(locations[low]! - target)
        return after < before ? low : low - 1
    }

    private func linear(_ target: Double) -> Int? {
        var best: Int?, distance = Double.infinity
        for (i, location) in locations.enumerated() {
            if let location {
                let d = abs(location - target)
                if d < distance { distance = d; best = i }
            }
        }
        return best
    }
}
