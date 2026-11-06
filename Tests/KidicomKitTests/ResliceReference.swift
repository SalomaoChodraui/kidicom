import Foundation
import simd
@testable import KidicomKit

// The generic oblique reslice as it was before the specialized kernels:
// every sample bounds-checked, trilinear, hits counted, then a second pass.
// Kept unchanged as the reference the fast kernels are compared against.
extension Volume {
    func referenceReslice(_ plane: ObliquePlane, at t: Double, slab: Double = 0, mode: SlabMode = .single, outside: Float) -> ResliceImage {
        let n = plane.normal
        let step = obliqueStep(n)
        let half = mode.isProjection ? max(0, Int((slab / step / 2).rounded(.down))) : 0
        let origin = canvasOrigin(plane, at: t)
        let pixel = obliquePixel
        let w = plane.width, h = plane.height
        let inv = 1 / steps
        let o = origin * inv, ax = plane.across * pixel * inv, dy = plane.down * pixel * inv, nz = n * step * inv
        let nx = width, ny = height, nzCount = depth, plane2D = width * height
        let initial: Float = mode == .minip ? .greatestFiniteMagnitude : mode == .mean ? 0 : -.greatestFiniteMagnitude
        var values = [Float](repeating: initial, count: w * h)
        var counts = [UInt16](repeating: 0, count: w * h)
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        voxels.withUnsafeBufferPointer { v in
            values.withUnsafeMutableBufferPointer { acc in
                counts.withUnsafeMutableBufferPointer { hits in
                    nonisolated(unsafe) let v = v, acc = acc, hits = hits
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let firstRow = band * h / bands, endRow = (band + 1) * h / bands
                        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Float { Float(v[k * plane2D + j * nx + i]) }
                        for s in -half ... half {
                            let shifted = o + Double(s) * nz
                            for y in firstRow ..< endRow {
                                let row = shifted + Double(y) * dy
                                for x in 0 ..< w {
                                    let p = row + Double(x) * ax
                                    guard p.x >= 0, p.y >= 0, p.z >= 0,
                                          p.x <= Double(nx - 1), p.y <= Double(ny - 1), p.z <= Double(nzCount - 1) else { continue }
                                    let x0 = Int(p.x), y0 = Int(p.y), z0 = Int(p.z)
                                    let x1 = min(x0 + 1, nx - 1), y1 = min(y0 + 1, ny - 1), z1 = min(z0 + 1, nzCount - 1)
                                    let fx = Float(p.x - Double(x0)), fy = Float(p.y - Double(y0)), fz = Float(p.z - Double(z0))
                                    let c00 = at(x0, y0, z0) + (at(x1, y0, z0) - at(x0, y0, z0)) * fx
                                    let c10 = at(x0, y1, z0) + (at(x1, y1, z0) - at(x0, y1, z0)) * fx
                                    let c01 = at(x0, y0, z1) + (at(x1, y0, z1) - at(x0, y0, z1)) * fx
                                    let c11 = at(x0, y1, z1) + (at(x1, y1, z1) - at(x0, y1, z1)) * fx
                                    let c0 = c00 + (c10 - c00) * fy, c1 = c01 + (c11 - c01) * fy
                                    let sample = c0 + (c1 - c0) * fz
                                    let i = y * w + x
                                    switch mode {
                                    case .single, .mip: acc[i] = max(acc[i], sample)
                                    case .minip: acc[i] = min(acc[i], sample)
                                    case .mean: acc[i] += sample
                                    }
                                    hits[i] &+= 1
                                }
                            }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: outside, count: w * h)
        for i in out.indices where counts[i] > 0 {
            out[i] = mode == .mean ? values[i] / Float(counts[i]) : values[i]
        }
        let row = patientDirection(plane.across), column = patientDirection(plane.down)
        let patientNormal = patientDirection(n)
        let first = patientPoint(origin)
        return ResliceImage(values: out, width: w, height: h, pixelSpacing: [pixel, pixel],
                            orientation: [row.x, row.y, row.z, column.x, column.y, column.z],
                            position: [first.x, first.y, first.z],
                            location: simd_dot(patientPoint(physicalCenter + (t - simd_dot(physicalCenter, n)) * n), patientNormal))
    }
}
