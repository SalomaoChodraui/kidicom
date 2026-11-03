import Accelerate
import CoreGraphics
import Foundation

/// Turns decoded frames into images on screen.
public enum Renderer {
    /// Applies a window to modality values: DICOM linear function, vectorized.
    public static func gray8(_ values: [Float], window: Window, inverted: Bool) -> [UInt8] {
        let count = values.count
        guard count > 0 else { return [] }
        // y = ((x - (c - 0.5)) / (w - 1) + 0.5), clamped to 0...1, times 255.
        let w = Float(max(window.width - 1, 1))
        var scale = 255 / w
        var offset = Float((0.5 - (window.center - 0.5) / Double(w)) * 255)
        if inverted {
            scale = -scale
            offset = 255 - offset
        }
        var scaled = [Float](repeating: 0, count: count)
        vDSP_vsmsa(values, 1, &scale, &offset, &scaled, 1, vDSP_Length(count))
        var low: Float = 0, high: Float = 255
        vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, vDSP_Length(count))
        var out = [UInt8](repeating: 0, count: count)
        vDSP_vfixru8(scaled, 1, &out, 1, vDSP_Length(count))
        return out
    }

    public static func image(_ frame: Frame, width: Int, height: Int, window: Window, inverted: Bool) -> CGImage? {
        switch frame {
        case .grayscale(let values):
            return grayImage(gray8(values, window: window, inverted: inverted), width: width, height: height)
        case .color(let rgba):
            return colorImage(rgba, width: width, height: height)
        }
    }

    public static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard pixels.count >= width * height, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    public static func colorImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgba.count >= width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// The lowest and highest value in a frame, for a default window.
    public static func range(_ values: [Float]) -> (low: Float, high: Float) {
        guard !values.isEmpty else { return (0, 1) }
        var low: Float = 0, high: Float = 0
        vDSP_minv(values, 1, &low, vDSP_Length(values.count))
        vDSP_maxv(values, 1, &high, vDSP_Length(values.count))
        return (low, high)
    }
}

/// Window presets by key: 1 Soft Tissue, 2 Lung, 3 Bone, 4 Brain, 0 file default.
public enum WindowPreset: Int, CaseIterable, Sendable {
    case fileDefault = 0, softTissue, lung, bone, brain

    public var window: Window? {
        switch self {
        case .fileDefault: nil
        case .softTissue: Window(center: 40, width: 400)
        case .lung: Window(center: -600, width: 1500)
        case .bone: Window(center: 400, width: 1800)
        case .brain: Window(center: 40, width: 80)
        }
    }
}
