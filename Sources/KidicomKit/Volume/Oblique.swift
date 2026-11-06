import Foundation
import simd

/// One plane of an oblique MPR: two unit vectors in volume space (mm along
/// i, j, k) and the pixel canvas it is drawn on.
public struct ObliquePlane: Sendable, Equatable {
    /// Screen right and screen down, as unit vectors in volume space.
    public var across: SIMD3<Double>
    public var down: SIMD3<Double>
    /// Canvas size in pixels, fixed for the session so the image does not
    /// jump when the plane tilts.
    public var width: Int
    public var height: Int

    public var normal: SIMD3<Double> { simd_normalize(simd_cross(across, down)) }
}

/// Three mutually perpendicular planes through one point: the state of an
/// oblique MPR. Space is the volume's own, in mm: x = i·Δi, y = j·Δj, z = k·Δk.
public struct MPRFrame: Sendable, Equatable {
    public var center: SIMD3<Double>
    public var planes: [ObliquePlane]
    /// The planes as they started, for Reset.
    public let initial: [ObliquePlane]

    /// Starts on the three orthogonal planes of `Volume.layout`, through the
    /// middle of the volume, drawn exactly like the straight reformats.
    public init(volume: Volume) {
        var planes: [ObliquePlane] = []
        for plane in VolumePlane.allCases {
            let l = volume.layout(plane)
            let pixel = volume.obliquePixel
            func unit(_ a: Volume.Axis, _ sign: Double) -> SIMD3<Double> {
                switch a {
                case .i: SIMD3(sign, 0, 0)
                case .j: SIMD3(0, sign, 0)
                case .k: SIMD3(0, 0, sign)
                }
            }
            func pixels(_ a: Volume.Axis) -> Int {
                max(1, Int((Double(volume.axisCount(a) - 1) * volume.axisSpacing(a) / pixel).rounded()) + 1)
            }
            planes.append(ObliquePlane(across: unit(l.across, l.acrossSign), down: unit(l.down, l.downSign),
                                       width: pixels(l.across), height: pixels(l.down)))
        }
        self.planes = planes
        initial = planes
        center = volume.physicalCenter
    }

    /// Turns the two planes other than `fixed` around `fixed`'s normal, so
    /// all three stay perpendicular. Positive angles turn clockwise on screen.
    public mutating func rotate(around fixed: Int, by angle: Double) {
        let axis = planes[fixed].normal
        let turn = simd_quatd(angle: angle, axis: axis)
        for p in planes.indices where p != fixed {
            planes[p].across = simd_normalize(turn.act(planes[p].across))
            planes[p].down = simd_normalize(turn.act(planes[p].down))
        }
    }

    public mutating func resetRotation() { planes = initial }

    public var isTilted: Bool {
        zip(planes, initial).contains { simd_length($0.across - $1.across) > 1e-6 || simd_length($0.down - $1.down) > 1e-6 }
    }
}

public extension Volume {
    /// Square output pixels: the finer of the in-plane spacings.
    var obliquePixel: Double { min(spacing.i, spacing.j) }

    /// Volume space size of one step along each axis.
    var steps: SIMD3<Double> { SIMD3(spacing.i, spacing.j, spacing.k) }

    /// The middle of the volume, in volume space.
    var physicalCenter: SIMD3<Double> {
        SIMD3(Double(width - 1), Double(height - 1), Double(depth - 1)) * steps / 2
    }

    private var corners: [SIMD3<Double>] {
        let m = SIMD3(Double(width - 1), Double(height - 1), Double(depth - 1)) * steps
        return [0, 1].flatMap { a in [0, 1].flatMap { b in [0, 1].map { c in SIMD3(Double(a) * m.x, Double(b) * m.y, Double(c) * m.z) } } }
    }

    /// Distance between neighboring positions along a normal: one voxel's
    /// worth of travel, so a straight plane scrolls slice by slice.
    func obliqueStep(_ normal: SIMD3<Double>) -> Double {
        let n = normal / steps
        return 1 / max(simd_length(n), 1e-9)
    }

    /// Positions along a normal that cross the volume: first one, step, count.
    func obliqueRange(_ normal: SIMD3<Double>) -> (start: Double, step: Double, count: Int) {
        let ts = corners.map { simd_dot($0, normal) }
        let lo = ts.min() ?? 0, hi = ts.max() ?? 0
        let step = obliqueStep(normal)
        return (lo, step, max(1, Int(((hi - lo) / step).rounded()) + 1))
    }

    /// Patient-space vector for a volume-space direction.
    func patientDirection(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let r = SIMD3(rowDirection[0], rowDirection[1], rowDirection[2])
        let c = SIMD3(columnDirection[0], columnDirection[1], columnDirection[2])
        let n = SIMD3(normal[0], normal[1], normal[2])
        return v.x * r + v.y * c + v.z * n
    }

    /// Patient-space position for a volume-space point.
    func patientPoint(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(origin[0], origin[1], origin[2]) + patientDirection(p)
    }

    /// Where pixel (0, 0) of a plane's canvas sits when the plane passes at
    /// `t` along its normal: the canvas is centered on the volume's middle.
    func canvasOrigin(_ plane: ObliquePlane, at t: Double) -> SIMD3<Double> {
        let n = plane.normal
        let middle = physicalCenter + (t - simd_dot(physicalCenter, n)) * n
        let pixel = obliquePixel
        return middle - (Double(plane.width - 1) / 2) * pixel * plane.across - (Double(plane.height - 1) / 2) * pixel * plane.down
    }

    /// Canvas pixel of a volume-space point on a plane.
    func canvasPoint(_ p: SIMD3<Double>, on plane: ObliquePlane, at t: Double) -> SIMD2<Double> {
        let d = p - canvasOrigin(plane, at: t)
        return SIMD2(simd_dot(d, plane.across), simd_dot(d, plane.down)) / obliquePixel
    }

    /// Volume-space point under a canvas pixel.
    func volumePoint(_ pixel: SIMD2<Double>, on plane: ObliquePlane, at t: Double) -> SIMD3<Double> {
        canvasOrigin(plane, at: t) + obliquePixel * (pixel.x * plane.across + pixel.y * plane.down)
    }

    /// The lowest value in the volume, drawn outside it.
    var floorValue: Float {
        voxels.withUnsafeBufferPointer { v in
            var lowest = Float.greatestFiniteMagnitude
            for i in stride(from: 0, to: v.count, by: max(1, v.count / 65_536)) { lowest = min(lowest, Float(v[i])) }
            return lowest
        }
    }

    /// Samples a plane at `t` along its normal, trilinear, with an optional
    /// slab in mm combined by `mode` (MIP, MinIP, or mean). Pixels with no
    /// sample inside the volume get `outside`.
    ///
    /// `isCancelled` is asked once per output row on every core. When it
    /// returns true the work stops early and the image comes back
    /// unfinished, for a caller that no longer wants it (pass
    /// `{ Task.isCancelled }` from the task that asked, then drop the result).
    func reslice(_ plane: ObliquePlane, at t: Double, slab: Double = 0, mode: SlabMode = .single, outside: Float,
                 isCancelled: @Sendable () -> Bool = { false }) -> ResliceImage {
        let n = plane.normal
        let step = obliqueStep(n)
        let half = mode.isProjection ? max(0, Int((slab / step / 2).rounded(.down))) : 0
        let origin = canvasOrigin(plane, at: t)
        let pixel = obliquePixel
        let w = plane.width, h = plane.height
        // Index-space increments per canvas pixel and per slab step.
        let inv = 1 / steps
        let geometry = ResliceGeometry(origin: origin * inv, across: plane.across * pixel * inv, down: plane.down * pixel * inv,
                                       normal: n * step * inv, half: half, width: w, height: h, mode: mode)
        let out = resliceValues(geometry, outside: outside, isCancelled: isCancelled)
        let row = patientDirection(plane.across), column = patientDirection(plane.down)
        let patientNormal = patientDirection(n)
        let first = patientPoint(origin)
        return ResliceImage(values: out, width: w, height: h, pixelSpacing: [pixel, pixel],
                            orientation: [row.x, row.y, row.z, column.x, column.y, column.z],
                            position: [first.x, first.y, first.z],
                            location: simd_dot(patientPoint(physicalCenter + (t - simd_dot(physicalCenter, n)) * n), patientNormal))
    }
}
