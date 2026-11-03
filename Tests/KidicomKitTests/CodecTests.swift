import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KidicomKit

@Suite("Codecs")
struct CodecTests {
    /// Wraps frames as encapsulated pixel data in an explicit VR file.
    func encapsulated(syntax: String, frames: [Data], configure: (inout DicomBuilder) -> Void) -> Data {
        var b = DicomBuilder()
        configure(&b)
        var pixel = Data()
        pixel.append(le16(0xFFFE) + le16(0xE000) + le32(0))  // empty offset table
        for frame in frames {
            var f = frame
            if f.count % 2 == 1 { f.append(0) }
            pixel.append(le16(0xFFFE) + le16(0xE000) + le32(UInt32(f.count)))
            pixel.append(f)
        }
        pixel.append(le16(0xFFFE) + le16(0xE0DD) + le32(0))
        b.element(.pixelData, .OB, pixel, undefinedLength: true)
        var out = b.build()
        // Point the meta header at the compressed syntax.
        let explicitUID = "1.2.840.10008.1.2.1\0".data(using: .ascii)!
        if let range = out.range(of: explicitUID) {
            var uid = syntax.data(using: .ascii)!
            if uid.count % 2 == 1 { uid.append(0) }
            var rebuilt = out[..<(range.lowerBound - 2)]
            rebuilt.append(le16(UInt16(uid.count)))
            rebuilt.append(uid)
            rebuilt.append(out[range.upperBound...])
            out = Data(rebuilt)
        }
        return out
    }

    @Test("RLE 16-bit grayscale, two frames")
    func rle16() throws {
        // Values 0x0102, 0x0102, 0x0300, 0xFFFF: high byte plane, then low.
        func segmentFile(high: [UInt8], low: [UInt8]) -> Data {
            // Literal runs: header byte n-1, then n bytes.
            let s1 = Data([UInt8(high.count - 1)] + high)
            let s2 = Data([UInt8(low.count - 1)] + low)
            var header = le32(2) + le32(64) + le32(UInt32(64 + s1.count))
            header.append(Data(count: 64 - header.count))
            return header + s1 + s2
        }
        let frame1 = segmentFile(high: [0x01, 0x01, 0x03, 0xFF], low: [0x02, 0x02, 0x00, 0xFF])
        // Second frame: a replicate run of four 0x00 high bytes, low 7s.
        var header = le32(2) + le32(64) + le32(66)
        header.append(Data(count: 64 - header.count))
        let frame2 = header + Data([0xFD, 0x00]) + Data([0xFD, 0x07])
        let data = encapsulated(syntax: "1.2.840.10008.1.2.5", frames: [frame1, frame2]) { b in
            b.us(.samplesPerPixel, 1)
            b.text(.photometricInterpretation, .CS, "MONOCHROME2")
            b.text(.numberOfFrames, .IS, "2")
            b.us(.rows, 2); b.us(.columns, 2)
            b.us(.bitsAllocated, 16); b.us(.bitsStored, 16); b.us(.highBit, 15); b.us(.pixelRepresentation, 0)
        }
        let file = try DicomParser.parse(data)
        #expect(file.transferSyntax == .rle)
        guard case .grayscale(let one) = try file.frame(0), case .grayscale(let two) = try file.frame(1) else {
            Issue.record("not gray"); return
        }
        #expect(one == [0x0102, 0x0102, 0x0300, 0xFFFF])
        #expect(two == [7, 7, 7, 7])
    }

    @Test("JPEG baseline color (ultrasound) decodes close to the original")
    func jpegBaseline() throws {
        let width = 16, height = 8
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0 ..< width * height { rgba[i * 4] = 200; rgba[i * 4 + 1] = 40; rgba[i * 4 + 2] = 90 }
        let jpeg = try makeJPEG(rgba, width: width, height: height)
        let data = encapsulated(syntax: "1.2.840.10008.1.2.4.50", frames: [jpeg]) { b in
            b.us(.samplesPerPixel, 3)
            b.text(.photometricInterpretation, .CS, "YBR_FULL_422")
            b.us(.rows, UInt16(height)); b.us(.columns, UInt16(width))
            b.us(.bitsAllocated, 8); b.us(.bitsStored, 8); b.us(.highBit, 7); b.us(.pixelRepresentation, 0)
        }
        let file = try DicomParser.parse(data)
        guard case .color(let out) = try file.frame(0) else { Issue.record("not color"); return }
        #expect(out.count == width * height * 4)
        let center = (height / 2 * width + width / 2) * 4
        #expect(abs(Int(out[center]) - 200) < 12)
        #expect(abs(Int(out[center + 1]) - 40) < 12)
        #expect(abs(Int(out[center + 2]) - 90) < 12)
    }

    func makeJPEG(_ rgba: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
