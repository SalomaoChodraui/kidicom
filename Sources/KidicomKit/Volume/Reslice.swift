import Foundation

/// The three orthogonal planes of a volume, named by the volume's axes.
public enum VolumePlane: Int, CaseIterable, Sendable {
    /// The acquired slices (fixed k).
    case native
    /// Fixed j: spans i (across) and k (up).
    case alongRows
    /// Fixed i: spans j (across) and k (up).
    case alongColumns
}

/// A reformatted image, resampled to square pixels.
public struct ResliceImage: Sendable {
    public var values: [Float]
    public var width: Int
    public var height: Int
    /// Row then column spacing, in mm (equal: pixels are square).
    public var pixelSpacing: [Double]
    public var orientation: [Double]
    /// Patient position of the first pixel.
    public var position: [Double]
    /// Position along this plane's normal, for the overlay.
    public var location: Double
}

public enum SlabMode: Sendable {
    /// One plane, interpolated.
    case single
    /// Maximum intensity projection across the slab.
    case mip
}

public extension Volume {
    /// Number of positions along a plane's normal.
    func count(_ plane: VolumePlane) -> Int {
        switch plane {
        case .native: depth
        case .alongRows: height
        case .alongColumns: width
        }
    }

    /// mm between neighboring positions along a plane's normal.
    func step(_ plane: VolumePlane) -> Double {
        switch plane {
        case .native: spacing.k
        case .alongRows: spacing.j
        case .alongColumns: spacing.i
        }
    }

    /// Square output pixels: the finer of the in-plane spacings.
    private var pixel: Double { min(spacing.i, spacing.j) }

    /// The image of `plane` at `index`, with an optional slab in mm.
    func reslice(_ plane: VolumePlane, at index: Int, slab: Double = 0, mode: SlabMode = .single) -> ResliceImage {
        let index = min(max(0, index), count(plane) - 1)
        let half = mode == .mip ? max(0, Int((slab / step(plane) / 2).rounded(.down))) : 0
        let range = max(0, index - half) ... min(count(plane) - 1, index + half)
        switch plane {
        case .native: return native(range, index: index)
        case .alongRows, .alongColumns: return reformat(plane, range, index: index)
        }
    }

    private func native(_ range: ClosedRange<Int>, index: Int) -> ResliceImage {
        let plane = width * height
        var out = [Float](repeating: -.greatestFiniteMagnitude, count: plane)
        voxels.withUnsafeBufferPointer { v in
            out.withUnsafeMutableBufferPointer { o in
                for k in range {
                    let base = k * plane
                    for p in 0 ..< plane { o[p] = max(o[p], Float(v[base + p])) }
                }
            }
        }
        let position = (0 ..< 3).map { origin[$0] + normal[$0] * spacing.k * Double(index) }
        return ResliceImage(values: out, width: width, height: height, pixelSpacing: [spacing.j, spacing.i],
                            orientation: rowDirection + columnDirection, position: position,
                            location: location(.native, at: index))
    }

    // MARK: Reformat layout

    enum Axis { case i, j, k }

    /// How a plane maps onto the screen: which volume axis runs across and
    /// which runs down, and in which direction.
    struct Layout {
        var across: Axis, acrossSign: Double
        var down: Axis, downSign: Double
        var fixed: Axis
    }

    func axisCount(_ a: Axis) -> Int { a == .i ? width : a == .j ? height : depth }
    func axisSpacing(_ a: Axis) -> Double { a == .i ? spacing.i : a == .j ? spacing.j : spacing.k }
    func axisDirection(_ a: Axis) -> [Double] { a == .i ? rowDirection : a == .j ? columnDirection : normal }
    private func axisStride(_ a: Axis) -> Int { a == .i ? 1 : a == .j ? width : width * height }

    /// Native planes show the acquired image as is. Reformats follow the
    /// reading convention whatever the acquisition: the head up (anterior
    /// up in axial planes), patient right on the screen's left, anterior on
    /// the left in sagittal planes.
    func layout(_ plane: VolumePlane) -> Layout {
        switch plane {
        case .native: return Layout(across: .i, acrossSign: 1, down: .j, downSign: 1, fixed: .k)
        case .alongRows: return reformatLayout(.i, .k, fixed: .j)
        case .alongColumns: return reformatLayout(.j, .k, fixed: .i)
        }
    }

    private func reformatLayout(_ a: Axis, _ b: Axis, fixed: Axis) -> Layout {
        let da = axisDirection(a), db = axisDirection(b)
        let planeNormal = Self.cross(da, db)
        let isAxial = abs(planeNormal[2]) >= max(abs(planeNormal[0]), abs(planeNormal[1]))
        // Down: toward the feet (-z), or toward posterior (+y) in an axial plane.
        let component = isAxial ? 1 : 2
        let (down, across) = abs(da[component]) >= abs(db[component]) ? (a, b) : (b, a)
        let downDirection = axisDirection(down)[component]
        let downSign: Double = isAxial ? (downDirection >= 0 ? 1 : -1) : (downDirection <= 0 ? 1 : -1)
        // Across: toward patient left (+x), or posterior (+y) when x is absent.
        let ad = axisDirection(across)
        let main = abs(ad[0]) >= abs(ad[1]) ? 0 : 1
        let acrossSign: Double = ad[main] >= 0 ? 1 : -1
        return Layout(across: across, acrossSign: acrossSign, down: down, downSign: downSign, fixed: fixed)
    }

    /// Output pixels along an axis at the square pixel size.
    private func pixels(_ a: Axis) -> Int {
        max(1, Int((Double(axisCount(a) - 1) * axisSpacing(a) / pixel).rounded()) + 1)
    }

    /// Volume index along an axis for an output pixel coordinate.
    private func volumeIndex(_ p: Double, _ a: Axis, _ sign: Double) -> Double {
        let t = p * pixel / axisSpacing(a)
        return sign > 0 ? t : Double(axisCount(a) - 1) - t
    }

    /// Output pixel coordinate for a volume index along an axis.
    private func pixelCoordinate(_ index: Double, _ a: Axis, _ sign: Double) -> Double {
        let t = sign > 0 ? index : Double(axisCount(a) - 1) - index
        return t * axisSpacing(a) / pixel
    }

    private func reformat(_ plane: VolumePlane, _ range: ClosedRange<Int>, index: Int) -> ResliceImage {
        let l = layout(plane)
        let columns = pixels(l.across), rows = pixels(l.down)
        let nA = axisCount(l.across), nD = axisCount(l.down)
        let sA = axisStride(l.across), sD = axisStride(l.down), sF = axisStride(l.fixed)
        let downIndex = (0 ..< rows).map { volumeIndex(Double($0), l.down, l.downSign) }
        let acrossIndex = (0 ..< columns).map { volumeIndex(Double($0), l.across, l.acrossSign) }
        var out = [Float](repeating: -.greatestFiniteMagnitude, count: columns * rows)
        voxels.withUnsafeBufferPointer { v in
            out.withUnsafeMutableBufferPointer { o in
                for r in 0 ..< rows {
                    let df = downIndex[r]
                    let d0 = max(0, min(nD - 1, Int(df.rounded(.down)))), d1 = min(nD - 1, d0 + 1)
                    let td = Float(df - Double(d0))
                    for c in 0 ..< columns {
                        let af = acrossIndex[c]
                        let a0 = max(0, min(nA - 1, Int(af.rounded(.down)))), a1 = min(nA - 1, a0 + 1)
                        let ta = Float(af - Double(a0))
                        var best = -Float.greatestFiniteMagnitude
                        for f in range {
                            let base = f * sF
                            let p00 = Float(v[base + d0 * sD + a0 * sA]), p01 = Float(v[base + d0 * sD + a1 * sA])
                            let p10 = Float(v[base + d1 * sD + a0 * sA]), p11 = Float(v[base + d1 * sD + a1 * sA])
                            let top = p00 + (p01 - p00) * ta
                            let bottom = p10 + (p11 - p10) * ta
                            best = max(best, top + (bottom - top) * td)
                        }
                        o[r * columns + c] = best
                    }
                }
            }
        }
        let o = orientation(plane)
        var position = origin
        for a in 0 ..< 3 {
            position[a] += axisDirection(l.fixed)[a] * axisSpacing(l.fixed) * Double(index)
            if l.acrossSign < 0 { position[a] += axisDirection(l.across)[a] * axisSpacing(l.across) * Double(nA - 1) }
            if l.downSign < 0 { position[a] += axisDirection(l.down)[a] * axisSpacing(l.down) * Double(nD - 1) }
        }
        _ = o
        return ResliceImage(values: out, width: columns, height: rows, pixelSpacing: [pixel, pixel],
                            orientation: orientation(plane), position: position, location: location(plane, at: index))
    }

    /// Where `index` of `plane` falls in another plane's image, as a pixel
    /// row or column, for the reference lines.
    func line(of plane: VolumePlane, at index: Int, in view: VolumePlane) -> (vertical: Bool, position: Double)? {
        let fixed = layout(plane).fixed, v = layout(view)
        if view == .native {
            if fixed == .i { return (true, Double(index)) }
            if fixed == .j { return (false, Double(index)) }
            return nil
        }
        if fixed == v.down { return (false, pixelCoordinate(Double(index), v.down, v.downSign)) }
        if fixed == v.across { return (true, pixelCoordinate(Double(index), v.across, v.acrossSign)) }
        return nil
    }

    /// The index of `plane` under a pixel of `view`'s image (click to move the crosshair).
    func index(of plane: VolumePlane, at point: (x: Double, y: Double), in view: VolumePlane) -> Int? {
        let fixed = layout(plane).fixed, v = layout(view)
        let value: Double
        if view == .native {
            switch fixed {
            case .i: value = point.x
            case .j: value = point.y
            case .k: return nil
            }
        } else if fixed == v.down {
            value = volumeIndex(point.y, v.down, v.downSign)
        } else if fixed == v.across {
            value = volumeIndex(point.x, v.across, v.acrossSign)
        } else {
            return nil
        }
        return min(max(0, Int(value.rounded())), count(plane) - 1)
    }
}

/// Patient plane names, from the dominant axis of the plane normal.
public enum PatientPlane: Sendable {
    case axial, coronal, sagittal, oblique

    public init(orientation: [Double]) {
        guard orientation.count == 6 else { self = .oblique; return }
        let n = Volume.cross(Array(orientation[0 ..< 3]), Array(orientation[3 ..< 6])).map(abs)
        guard let top = n.max(), top > 0.8 else { self = .oblique; return }
        self = top == n[2] ? .axial : top == n[1] ? .coronal : .sagittal
    }
}

public extension Volume {
    /// Row and column direction cosines of a plane's images.
    func orientation(_ plane: VolumePlane) -> [Double] {
        let l = layout(plane)
        return axisDirection(l.across).map { $0 * l.acrossSign } + axisDirection(l.down).map { $0 * l.downSign }
    }

    /// Position along a plane's normal for an index, in mm.
    func location(_ plane: VolumePlane, at index: Int) -> Double {
        let o = orientation(plane)
        let planeNormal = Self.cross(Array(o[0 ..< 3]), Array(o[3 ..< 6]))
        let fixed = layout(plane).fixed
        var point = origin
        for a in 0 ..< 3 { point[a] += axisDirection(fixed)[a] * axisSpacing(fixed) * Double(index) }
        return Self.dot(point, planeNormal)
    }
}
