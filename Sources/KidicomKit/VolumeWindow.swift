import Foundation

public extension Volume {
    /// A window for the 3D view of MR and other non-CT series: hides air and
    /// noise, from 20 to 90 percent of the 95th percentile of up to 200 000
    /// evenly spaced voxels.
    func automaticWindow() -> VOIWindow {
        let stride = max(1, count / 200_000)
        var samples: [Float] = []
        samples.reserveCapacity(count / stride + 1)
        voxels.withUnsafeBufferPointer { v in
            for i in Swift.stride(from: 0, to: v.count, by: stride) { samples.append(Float(v[i])) }
        }
        let high = samples.isEmpty ? 1 : Double(Selection.nthSmallest(&samples, Int(Double(samples.count - 1) * 0.95)))
        return VOIWindow(center: high * 0.55, width: max(2, high * 0.7))
    }
}

public enum Selection {
    /// The value at index `k` once `values` is sorted, without sorting it all
    /// (quickselect, linear on average). Reorders `values`.
    public static func nthSmallest(_ values: inout [Float], _ k: Int) -> Float {
        precondition(values.indices.contains(k))
        return values.withUnsafeMutableBufferPointer { v in
            var low = 0, high = v.count - 1
            while low < high {
                // Median of three as the pivot keeps sorted input linear.
                let mid = low + (high - low) / 2
                if v[mid] < v[low] { v.swapAt(mid, low) }
                if v[high] < v[low] { v.swapAt(high, low) }
                if v[high] < v[mid] { v.swapAt(high, mid) }
                let pivot = v[mid]
                var i = low, j = high
                while i <= j {
                    while v[i] < pivot { i += 1 }
                    while pivot < v[j] { j -= 1 }
                    if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
                }
                if k <= j { high = j } else if k >= i { low = i } else { return v[k] }
            }
            return v[k]
        }
    }
}
