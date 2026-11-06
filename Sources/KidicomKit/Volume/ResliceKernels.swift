import Foundation
import simd

// Kernels behind `Volume.reslice(_: ObliquePlane, ...)`. Both sample where
// the plain loop in Tests/KidicomKitTests/ResliceReference.swift does (bounds
// check per sample, trilinear, hit count, second pass): same positions, same
// edges, same `outside`. ResliceKernelTests compares them.
//
// - Axis-aligned planes (the planes an MPR opens on): every index-space
//   coordinate depends on one of column, row, or slab step only, so the
//   interpolation positions come from three small tables, the valid pixels
//   form one rectangle, and every valid pixel gets the same number of
//   samples. Each row interpolates every slice it crosses once, bilinear,
//   and the slab steps blend neighboring slices. The axes are interpolated
//   in another order than the plain loop, so values can differ by a Float
//   rounding.
// - Tilted planes: each row and slab step finds the stretch of pixels inside
//   the volume from the plane equation, then samples it without checks, with
//   the plain loop's arithmetic: the values are identical.
//
// Both write straight into the output, a band of rows per core.

/// How a slab combines its samples, so each kernel compiles once per mode.
protocol SlabCombine: SendableMetatype {
    static var initial: Float { get }
    static func add(_ accumulated: Float, _ sample: Float) -> Float
}

enum MaxCombine: SlabCombine {
    static var initial: Float { -.greatestFiniteMagnitude }
    @inline(__always) static func add(_ a: Float, _ s: Float) -> Float { max(a, s) }
}

enum MinCombine: SlabCombine {
    static var initial: Float { .greatestFiniteMagnitude }
    @inline(__always) static func add(_ a: Float, _ s: Float) -> Float { min(a, s) }
}

enum SumCombine: SlabCombine {
    static var initial: Float { 0 }
    @inline(__always) static func add(_ a: Float, _ s: Float) -> Float { a + s }
}

/// One oblique reslice in voxel index space: pixel (x, y) of slab step s
/// samples `origin + s * normal + y * down + x * across`.
struct ResliceGeometry: Sendable {
    var origin: SIMD3<Double>
    var across: SIMD3<Double>
    var down: SIMD3<Double>
    var normal: SIMD3<Double>
    /// Slab steps run from -half to half.
    var half: Int
    var width: Int
    var height: Int
    var mode: SlabMode

    /// The index axis (0 = i, 1 = j, 2 = k) a vector runs along, when it
    /// runs along exactly one.
    private static func axis(_ v: SIMD3<Double>) -> Int? {
        let nonzero = (0 ..< 3).filter { v[$0] != 0 }
        return nonzero.count == 1 ? nonzero[0] : nil
    }

    /// The axes across, down, and the normal run along, for a plane that
    /// follows the volume's axes exactly.
    var alignedAxes: (across: Int, down: Int, normal: Int)? {
        guard let a = Self.axis(across), let d = Self.axis(down), let n = Self.axis(normal),
              a != d, a != n, d != n else { return nil }
        return (a, d, n)
    }
}

/// Interpolation positions along one index axis for consecutive samples:
/// lower and upper neighbor (as element offsets) and the fraction between.
private struct AxisTable {
    var lower: [Int]
    var upper: [Int]
    var fraction: [Float]
    /// Samples inside the volume along this axis: `valid.lowerBound ..< valid.upperBound`.
    var valid: Range<Int>

    /// Sample `n` sits at `start + Double(first + n) * delta`, the exact
    /// arithmetic of the plain loop.
    init(start: Double, delta: Double, first: Int, samples: Int, count: Int, stride: Int) {
        lower = [Int](repeating: 0, count: samples)
        upper = [Int](repeating: 0, count: samples)
        fraction = [Float](repeating: 0, count: samples)
        var lo = samples, hi = 0
        for n in 0 ..< samples {
            let q = start + Double(first + n) * delta
            guard q >= 0, q <= Double(count - 1) else { continue }
            let i0 = Int(q), i1 = min(i0 + 1, count - 1)
            lower[n] = i0 * stride
            upper[n] = i1 * stride
            fraction[n] = Float(q - Double(i0))
            lo = min(lo, n)
            hi = n + 1
        }
        // The coordinate is monotonic in n, so the valid samples are one run.
        valid = lo < hi ? lo ..< hi : 0 ..< 0
    }
}

extension Volume {
    /// Output values of a reslice, `outside` where no sample landed in the
    /// volume. Stops early, leaving the rest unfinished, once `isCancelled`
    /// returns true.
    func resliceValues(_ g: ResliceGeometry, outside: Float, isCancelled: @Sendable () -> Bool) -> [Float] {
        switch g.mode {
        case .single, .mip: kernel(g, outside: outside, isCancelled: isCancelled, MaxCombine.self)
        case .minip: kernel(g, outside: outside, isCancelled: isCancelled, MinCombine.self)
        case .mean: kernel(g, outside: outside, isCancelled: isCancelled, SumCombine.self)
        }
    }

    private func kernel<C: SlabCombine>(_ g: ResliceGeometry, outside: Float, isCancelled: @Sendable () -> Bool, _: C.Type) -> [Float] {
        if let axes = g.alignedAxes {
            return alignedKernel(g, axes, outside: outside, isCancelled: isCancelled, C.self)
        }
        return tiltedKernel(g, outside: outside, isCancelled: isCancelled, C.self)
    }

    private static var bandsPerCore: Int { 4 }
    /// Slab steps a tilted plane samples together, pixel by pixel.
    private static var stepsTogether: Int { 8 }

    // MARK: Axis-aligned

    private func alignedKernel<C: SlabCombine>(_ g: ResliceGeometry, _ axes: (across: Int, down: Int, normal: Int),
                                               outside: Float, isCancelled: @Sendable () -> Bool, _: C.Type) -> [Float] {
        let w = g.width, h = g.height
        var out = [Float](repeating: outside, count: w * h)
        let counts = [width, height, depth], strides = [1, width, width * height]
        let across = AxisTable(start: g.origin[axes.across], delta: g.across[axes.across], first: 0, samples: w,
                               count: counts[axes.across], stride: strides[axes.across])
        let down = AxisTable(start: g.origin[axes.down], delta: g.down[axes.down], first: 0, samples: h,
                             count: counts[axes.down], stride: strides[axes.down])
        // Slab steps as slice numbers along the normal axis.
        let steps = AxisTable(start: g.origin[axes.normal], delta: g.normal[axes.normal], first: -g.half, samples: 2 * g.half + 1,
                              count: counts[axes.normal], stride: 1)
        guard !across.valid.isEmpty, !down.valid.isEmpty, !steps.valid.isEmpty else { return out }

        // Every slice some valid step blends, interpolated once per row.
        var firstSlice = Int.max, lastSlice = Int.min
        for s in steps.valid {
            firstSlice = min(firstSlice, steps.lower[s])
            lastSlice = max(lastSlice, steps.fraction[s] == 0 ? steps.lower[s] : steps.upper[s])
        }
        var needed = [Bool](repeating: false, count: lastSlice - firstSlice + 1)
        for s in steps.valid {
            needed[steps.lower[s] - firstSlice] = true
            // A zero fraction blends nothing of the upper slice: c0 + (c1 - c0) * 0 is c0.
            if steps.fraction[s] != 0 { needed[steps.upper[s] - firstSlice] = true }
        }
        let sliceStride = strides[axes.normal], sliceBase = firstSlice, isNeeded = needed
        let columns = across.valid, rows = down.valid, valid = steps.valid
        let span = columns.count, sliceCount = isNeeded.count
        let samplesPerPixel = Float(valid.count)
        let stepLower = valid.map { steps.lower[$0] - firstSlice }, stepUpper = valid.map { steps.upper[$0] - firstSlice }
        let stepFraction = valid.map { steps.fraction[$0] }
        let isMean = C.self == SumCombine.self
        let bands = max(1, min(rows.count, ProcessInfo.processInfo.activeProcessorCount * Self.bandsPerCore))

        voxels.withUnsafeBufferPointer { v in
            out.withUnsafeMutableBufferPointer { o in
                across.lower.withUnsafeBufferPointer { a0 in
                across.upper.withUnsafeBufferPointer { a1 in
                across.fraction.withUnsafeBufferPointer { fa in
                    nonisolated(unsafe) let v = v, o = o, a0 = a0, a1 = a1, fa = fa
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let firstRow = rows.lowerBound + band * rows.count / bands
                        let endRow = rows.lowerBound + (band + 1) * rows.count / bands
                        // One interpolated row per slice the slab crosses.
                        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: span * sliceCount)
                        defer { scratch.deallocate() }
                        let x0 = columns.lowerBound
                        for y in firstRow ..< endRow {
                            if isCancelled() { return }
                            let d0 = down.lower[y], d1 = down.upper[y], fd = down.fraction[y]
                            if sliceStride == 1 {
                                // Slices next to each other in memory (a sagittal plane): pixel by
                                // pixel, the slab innermost, so each cache line serves every slice.
                                let top = v.baseAddress! + sliceBase + d0, bottom = v.baseAddress! + sliceBase + d1
                                let target = o.baseAddress! + y * w + x0
                                for c in 0 ..< span {
                                    let lo = a0[x0 + c], hi = a1[x0 + c], f = fa[x0 + c]
                                    for slice in 0 ..< sliceCount where isNeeded[slice] {
                                        let p00 = Float(top[lo + slice]), p01 = Float(top[hi + slice])
                                        let p10 = Float(bottom[lo + slice]), p11 = Float(bottom[hi + slice])
                                        let upper = p00 + (p01 - p00) * f
                                        let lower = p10 + (p11 - p10) * f
                                        scratch[slice] = upper + (lower - upper) * fd
                                    }
                                    var value = C.initial
                                    for n in 0 ..< stepLower.count {
                                        let b0 = scratch[stepLower[n]], f = stepFraction[n]
                                        value = C.add(value, f == 0 ? b0 : b0 + (scratch[stepUpper[n]] - b0) * f)
                                    }
                                    target[c] = isMean ? value / samplesPerPixel : value
                                }
                                continue
                            }
                            for slice in 0 ..< sliceCount where isNeeded[slice] {
                                let base = (sliceBase + slice) * sliceStride
                                let top = v.baseAddress! + base + d0, bottom = v.baseAddress! + base + d1
                                let row = scratch + slice * span
                                for c in 0 ..< span {
                                    let lo = a0[x0 + c], hi = a1[x0 + c], f = fa[x0 + c]
                                    let p00 = Float(top[lo]), p01 = Float(top[hi])
                                    let p10 = Float(bottom[lo]), p11 = Float(bottom[hi])
                                    let upper = p00 + (p01 - p00) * f
                                    let lower = p10 + (p11 - p10) * f
                                    row[c] = upper + (lower - upper) * fd
                                }
                            }
                            let target = o.baseAddress! + y * w + x0
                            var first = true
                            for s in valid {
                                let b0 = scratch + (steps.lower[s] - sliceBase) * span
                                let f = steps.fraction[s]
                                if f == 0 {
                                    if first {
                                        for c in 0 ..< span { target[c] = C.add(C.initial, b0[c]) }
                                    } else {
                                        for c in 0 ..< span { target[c] = C.add(target[c], b0[c]) }
                                    }
                                } else {
                                    let b1 = scratch + (steps.upper[s] - sliceBase) * span
                                    if first {
                                        for c in 0 ..< span { target[c] = C.add(C.initial, b0[c] + (b1[c] - b0[c]) * f) }
                                    } else {
                                        for c in 0 ..< span { target[c] = C.add(target[c], b0[c] + (b1[c] - b0[c]) * f) }
                                    }
                                }
                                first = false
                            }
                            if isMean {
                                for c in 0 ..< span { target[c] /= samplesPerPixel }
                            }
                        }
                    }
                }
                }
                }
            }
        }
        return out
    }

    // MARK: Tilted

    private func tiltedKernel<C: SlabCombine>(_ g: ResliceGeometry, outside: Float, isCancelled: @Sendable () -> Bool, _: C.Type) -> [Float] {
        let w = g.width, h = g.height
        var out = [Float](repeating: outside, count: w * h)
        let nx = width, ny = height, nz = depth, plane2D = width * height
        let limit = SIMD3(Double(nx - 1), Double(ny - 1), Double(nz - 1))
        let o = g.origin, ax = g.across, dy = g.down, dn = g.normal, half = g.half
        let isMean = C.self == SumCombine.self
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * Self.bandsPerCore))

        /// The pixels of a row whose samples land in the volume. Along each
        /// axis the sample coordinate `row[c] + Double(x) * ax[c]` is monotonic
        /// in x, so each of the six limits holds on one side of a boundary.
        /// The plane equation guesses each boundary; the exact test of the
        /// plain loop confirms it, or a binary search finds it when rounding
        /// moved it (an axis the row barely crosses).
        @Sendable @inline(__always) func span(_ row: SIMD3<Double>) -> ClosedRange<Int>? {
            var first = 0, end = w
            for c in 0 ..< 3 {
                let a = ax[c], r = row[c], m = limit[c]
                if a == 0 {
                    if !(r >= 0 && r <= m) { return nil }
                    continue
                }
                @inline(__always) func q(_ x: Int) -> Double { r + Double(x) * a }
                // Entering at the low limit going up, or at the high limit going down.
                let enter: (Int) -> Bool = a > 0 ? { q($0) >= 0 } : { q($0) <= m }
                let leave: (Int) -> Bool = a > 0 ? { q($0) > m } : { q($0) < 0 }
                first = max(first, firstTrue(guess: ((a > 0 ? 0 : m) - r) / a, enter))
                end = min(end, firstTrue(guess: ((a > 0 ? m : 0) - r) / a, leave))
                if first >= end { return nil }
            }
            return first < end ? first ... end - 1 : nil
        }

        /// The first x in 0 ... w where a predicate that only turns from
        /// false to true holds (w when it never does), starting at a guess.
        @Sendable @inline(__always) func firstTrue(guess: Double, _ holds: (Int) -> Bool) -> Int {
            var x = guess.isFinite ? Int(min(max(guess.rounded(.up), 0), Double(w))) : 0
            // Rounding, or a boundary that falls on a pixel, moves it by a step or two.
            for _ in 0 ..< 4 {
                let here = x == w || holds(x)
                if here && (x == 0 || !holds(x - 1)) { return x }
                x += here ? -1 : 1
            }
            var lo = 0, hi = w
            while lo < hi {
                let mid = (lo + hi) / 2
                if holds(mid) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        voxels.withUnsafeBufferPointer { v in
            out.withUnsafeMutableBufferPointer { result in
                nonisolated(unsafe) let v = v, result = result
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let firstRow = band * h / bands, endRow = (band + 1) * h / bands
                    let stepCount = 2 * half + 1, bandRows = endRow - firstRow
                    guard bandRows > 0 else { return }
                    // Per row and slab step: where the step's row starts and which
                    // pixels land inside.
                    let rows = UnsafeMutablePointer<SIMD3<Double>>.allocate(capacity: bandRows * stepCount)
                    let firsts = UnsafeMutablePointer<Int>.allocate(capacity: bandRows * stepCount)
                    let lasts = UnsafeMutablePointer<Int>.allocate(capacity: bandRows * stepCount)
                    let lowest = UnsafeMutablePointer<Int>.allocate(capacity: bandRows)
                    let highest = UnsafeMutablePointer<Int>.allocate(capacity: bandRows)
                    defer { rows.deallocate(); firsts.deallocate(); lasts.deallocate(); lowest.deallocate(); highest.deallocate() }
                    @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Float { Float(v[k * plane2D + j * nx + i]) }
                    for r in 0 ..< bandRows {
                        let y = firstRow + r
                        lowest[r] = w; highest[r] = -1
                        for n in 0 ..< stepCount {
                            let shifted = o + Double(n - half) * dn
                            let row = shifted + Double(y) * dy
                            let m = r * stepCount + n
                            rows[m] = row
                            if let run = span(row) {
                                firsts[m] = run.lowerBound; lasts[m] = run.upperBound
                                lowest[r] = min(lowest[r], run.lowerBound); highest[r] = max(highest[r], run.upperBound)
                            } else {
                                firsts[m] = w; lasts[m] = -1
                            }
                        }
                    }
                    // Slab steps a few at a time, then rows, then pixels, those steps
                    // innermost. The samples of one pixel sit next to each other along
                    // the normal and the next pixel's reuse the same cache lines. Slices
                    // of a 512 x 512 volume lie a power of two apart and share cache
                    // sets, so a whole slab per pixel would evict itself; a few steps fit.
                    let hits = UnsafeMutablePointer<UInt16>.allocate(capacity: bandRows * w)
                    defer { hits.deallocate() }
                    for r in 0 ..< bandRows where lowest[r] <= highest[r] {
                        let target = result.baseAddress! + (firstRow + r) * w
                        for x in lowest[r] ... highest[r] { target[x] = C.initial; hits[r * w + x] = 0 }
                    }
                    for chunk in stride(from: 0, to: stepCount, by: Self.stepsTogether) {
                        let chunkEnd = min(chunk + Self.stepsTogether, stepCount)
                        for r in 0 ..< bandRows where lowest[r] <= highest[r] {
                            if isCancelled() { return }
                            let target = result.baseAddress! + (firstRow + r) * w
                            let count = hits + r * w
                            var start = w, end = -1
                            for n in r * stepCount + chunk ..< r * stepCount + chunkEnd {
                                start = min(start, firsts[n]); end = max(end, lasts[n])
                            }
                            guard start <= end else { continue }
                            for x in start ... end {
                                var value = target[x]
                                var added: UInt16 = 0
                                for n in r * stepCount + chunk ..< r * stepCount + chunkEnd where x >= firsts[n] && x <= lasts[n] {
                                    let p = rows[n] + Double(x) * ax
                                    let x0 = Int(p.x), y0 = Int(p.y), z0 = Int(p.z)
                                    let x1 = min(x0 + 1, nx - 1), y1 = min(y0 + 1, ny - 1), z1 = min(z0 + 1, nz - 1)
                                    let fx = Float(p.x - Double(x0)), fy = Float(p.y - Double(y0)), fz = Float(p.z - Double(z0))
                                    let c00 = at(x0, y0, z0) + (at(x1, y0, z0) - at(x0, y0, z0)) * fx
                                    let c10 = at(x0, y1, z0) + (at(x1, y1, z0) - at(x0, y1, z0)) * fx
                                    let c01 = at(x0, y0, z1) + (at(x1, y0, z1) - at(x0, y0, z1)) * fx
                                    let c11 = at(x0, y1, z1) + (at(x1, y1, z1) - at(x0, y1, z1)) * fx
                                    let c0 = c00 + (c10 - c00) * fy, c1 = c01 + (c11 - c01) * fy
                                    value = C.add(value, c0 + (c1 - c0) * fz)
                                    added &+= 1
                                }
                                target[x] = value
                                count[x] &+= added
                            }
                        }
                    }
                    for r in 0 ..< bandRows where lowest[r] <= highest[r] {
                        let target = result.baseAddress! + (firstRow + r) * w
                        let count = hits + r * w
                        for x in lowest[r] ... highest[r] {
                            if count[x] == 0 { target[x] = outside } else if isMean { target[x] /= Float(count[x]) }
                        }
                    }
                }
            }
        }
        return out
    }
}
