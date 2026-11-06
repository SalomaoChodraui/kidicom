import Accelerate
import CoreGraphics
import Foundation

/// Turns decoded frames into images on screen. Safe to call from any thread.
public enum Renderer {
    /// Applies a window to modality values: DICOM linear function, vectorized.
    public static func gray8(_ values: [Float], window: VOIWindow, inverted: Bool) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: values.count) { out, filled in
            values.withUnsafeBufferPointer { gray8($0, into: out.baseAddress!, window: window, inverted: inverted) }
            filled = values.count
        }
    }

    /// Floats run through the window in blocks that stay in cache, so a
    /// large frame needs no second full-size buffer.
    private static let block = 4096

    private static func gray8(_ values: UnsafeBufferPointer<Float>, into out: UnsafeMutablePointer<UInt8>,
                              window: VOIWindow, inverted: Bool) {
        let count = values.count
        guard count > 0, let source = values.baseAddress else { return }
        // y = ((x - (c - 0.5)) / (w - 1) + 0.5), clamped to 0...1, times 255.
        let w = Float(max(window.width - 1, 1))
        var scale = 255 / w
        var offset = Float((0.5 - (window.center - 0.5) / Double(w)) * 255)
        if inverted {
            scale = -scale
            offset = 255 - offset
        }
        var low: Float = 0, high: Float = 255
        withUnsafeTemporaryAllocation(of: Float.self, capacity: min(block, count)) { scratch in
            let scaled = scratch.baseAddress!
            var start = 0
            while start < count {
                let n = vDSP_Length(min(block, count - start))
                vDSP_vsmsa(source + start, 1, &scale, &offset, scaled, 1, n)
                vDSP_vclip(scaled, 1, &low, &high, scaled, 1, n)
                vDSP_vfixru8(scaled, 1, out + start, 1, n)
                start += Int(n)
            }
        }
    }

    public static func image(_ frame: Frame, width: Int, height: Int, window: VOIWindow, inverted: Bool) -> CGImage? {
        switch frame {
        case .grayscale(let values):
            guard width > 0, height > 0, values.count >= width * height else { return nil }
            let count = width * height
            return grayImage(width: width, height: height) { out in
                values.withUnsafeBufferPointer { gray8(UnsafeBufferPointer(rebasing: $0[0 ..< count]), into: out, window: window, inverted: inverted) }
            }
        case .color(let rgba):
            guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
            return colorImage(width: width, height: height) { out in
                rgba.withUnsafeBufferPointer { color($0.baseAddress!, into: out, pixels: width * height, window: window) }
            }
        }
    }

    /// Brightness and contrast for color frames: the same linear window on
    /// each of R, G, and B (0...255). The default 128/256 leaves pixels as is.
    public static func color(_ rgba: [UInt8], window: VOIWindow) -> [UInt8] {
        if window == neutral { return rgba }
        return [UInt8](unsafeUninitializedCapacity: rgba.count) { out, filled in
            rgba.withUnsafeBufferPointer { color($0.baseAddress!, into: out.baseAddress!, pixels: rgba.count / 4, window: window) }
            // A trailing partial pixel, if any, is copied as is.
            for i in rgba.count / 4 * 4 ..< rgba.count { out[i] = rgba[i] }
            filled = rgba.count
        }
    }

    private static let neutral = VOIWindow(center: 128, width: 256)

    private static func color(_ source: UnsafePointer<UInt8>, into out: UnsafeMutablePointer<UInt8>, pixels: Int, window: VOIWindow) {
        let bytes = pixels * 4
        if window == neutral {
            out.update(from: source, count: bytes)
            return
        }
        let levels = (0 ..< 256).map(Float.init)
        let table = gray8(levels, window: window, inverted: false)
        // One vectorized lookup per channel; the fourth byte is left alone.
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(pixels), rowBytes: bytes)
        var to = vImage_Buffer(data: out, height: 1, width: vImagePixelCount(pixels), rowBytes: bytes)
        table.withUnsafeBufferPointer { t in
            let lookup = t.baseAddress!
            // vImage names the channels ARGB; for RGBA bytes the first three tables are R, G, B.
            _ = vImageTableLookUp_ARGB8888(&from, &to, lookup, lookup, lookup, nil, vImage_Flags(kvImageNoFlags))
        }
    }

    public static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        return grayImage(width: width, height: height) { out in
            pixels.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: width * height) }
        }
    }

    public static func colorImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        return colorImage(width: width, height: height) { out in
            rgba.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: width * height * 4) }
        }
    }

    private static let grayLinear = CGColorSpaceCreateDeviceGray()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func grayImage(width: Int, height: Int, fill: (UnsafeMutablePointer<UInt8>) -> Void) -> CGImage? {
        guard let provider = provider(bytes: width * height, fill: fill) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: grayLinear, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func colorImage(width: Int, height: Int, fill: (UnsafeMutablePointer<UInt8>) -> Void) -> CGImage? {
        guard let provider = provider(bytes: width * height * 4, fill: fill) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// A pixel buffer written once and handed to the image as is: no Data
    /// copy. The provider frees it when the last image lets go.
    private static func provider(bytes: Int, fill: (UnsafeMutablePointer<UInt8>) -> Void) -> CGDataProvider? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        fill(buffer)
        let provider = CGDataProvider(dataInfo: nil, data: buffer, size: bytes) { _, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
        }
        if provider == nil { buffer.deallocate() }
        return provider
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

/// VOIWindow presets by key: 1 Soft Tissue, 2 Lung, 3 Bone, 4 Brain, 0 file default.
public enum WindowPreset: Int, CaseIterable, Sendable {
    case fileDefault = 0, softTissue, lung, bone, brain

    public var window: VOIWindow? {
        switch self {
        case .fileDefault: nil
        case .softTissue: VOIWindow(center: 40, width: 400)
        case .lung: VOIWindow(center: -600, width: 1500)
        case .bone: VOIWindow(center: 400, width: 1800)
        case .brain: VOIWindow(center: 40, width: 80)
        }
    }
}
