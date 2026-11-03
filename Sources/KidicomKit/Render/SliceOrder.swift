import Foundation

/// Orders the images of a series along the patient, the way a radiologist
/// scrolls: by position projected on the slice normal, then by number.
public enum SliceOrder {
    public struct Item: Sendable {
        public var instanceNumber: Int
        public var position: [Double]
        public var orientation: [Double]

        public init(instanceNumber: Int, position: [Double], orientation: [Double]) {
            self.instanceNumber = instanceNumber
            self.position = position
            self.orientation = orientation
        }
    }

    /// Indexes into `items`, in scroll order.
    public static func order(_ items: [Item]) -> [Int] {
        let indexes = Array(items.indices)
        let normal = items.first.flatMap { normalOf($0.orientation) }
        let allPlaced = normal != nil && items.allSatisfy { $0.position.count == 3 }
        guard allPlaced, let normal else {
            return indexes.sorted { items[$0].instanceNumber < items[$1].instanceNumber }
        }
        let distance = items.map { dot($0.position, normal) }
        // Same distance (several echoes at one position): keep instance order.
        return indexes.sorted {
            abs(distance[$0] - distance[$1]) > 1e-4 ? distance[$0] > distance[$1] : items[$0].instanceNumber < items[$1].instanceNumber
        }
    }

    /// Distance along the normal, used for the "Pos" overlay and sync.
    public static func location(position: [Double], orientation: [Double]) -> Double? {
        guard position.count == 3, let normal = normalOf(orientation) else { return nil }
        return dot(position, normal)
    }

    static func normalOf(_ o: [Double]) -> [Double]? {
        guard o.count == 6 else { return nil }
        let n = [o[1] * o[5] - o[2] * o[4], o[2] * o[3] - o[0] * o[5], o[0] * o[4] - o[1] * o[3]]
        let length = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).squareRoot()
        guard length > 1e-6 else { return nil }
        return n.map { $0 / length }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
}
