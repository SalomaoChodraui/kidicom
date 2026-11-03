import Foundation
import COpenJPEG
import ImageIO

/// Decoders for compressed transfer syntaxes: JPEG Lossless and RLE in
/// Swift, JPEG baseline and JPEG 2000 through ImageIO.
enum Codecs {
    static func decode(_ bytes: Data, syntax: TransferSyntax, descriptor: PixelDescriptor) throws -> Frame {
        switch syntax {
        case .jpegLossless, .jpegLosslessSV1:
            let image = try JPEGLossless.decode(bytes)
            return try fromSamples(image.samples, width: image.width, height: image.height, components: image.components, descriptor: descriptor)
        case .rle:
            let native = try RLE.decode(bytes, descriptor: descriptor)
            return try NativePixels.decode(native, descriptor: descriptor)
        case .jpeg2000Lossless, .jpeg2000:
            return try jpeg2000(bytes, descriptor: descriptor)
        case .jpegBaseline, .jpegExtended:
            return try imageIO(bytes, descriptor: descriptor)
        default:
            throw DicomError.unsupportedTransferSyntax(syntax.uid)
        }
    }

    /// Decoded samples to a frame, through the same masking and rescale as
    /// native pixels.
    static func fromSamples(_ samples: [UInt16], width: Int, height: Int, components: Int, descriptor: PixelDescriptor) throws -> Frame {
        var d = descriptor
        d.rows = height
        d.columns = width
        d.samplesPerPixel = components
        if components == 1 {
            d.bitsAllocated = 16
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            return try NativePixels.decode(data, descriptor: d)
        }
        // Color: the codec output is RGB, interleaved, 8 bits.
        d.bitsAllocated = 8
        d.planarConfiguration = 0
        d.photometric = "RGB"
        return try NativePixels.decode(Data(samples.map { UInt8(truncatingIfNeeded: $0) }), descriptor: d)
    }

    static func imageIO(_ bytes: Data, descriptor: PixelDescriptor) throws -> Frame {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let provider = image.dataProvider, let cfData = provider.data else {
            throw DicomError.decodeFailed("ImageIO could not decode the frame")
        }
        let data = cfData as Data
        let width = image.width, height = image.height
        let bpc = image.bitsPerComponent
        let channels = image.bitsPerPixel / max(bpc, 1)
        let rowBytes = image.bytesPerRow
        let info = image.bitmapInfo
        let little16 = info.contains(.byteOrder16Little)
        let alpha = image.alphaInfo
        // Alpha and skipped bytes both take a channel.
        let hasAlpha = alpha != .none
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let colorChannels = channels - (hasAlpha ? 1 : 0)

        var samples = [UInt16](repeating: 0, count: width * height * max(1, min(colorChannels, 3)))
        let outComponents = colorChannels >= 3 ? 3 : 1
        data.withUnsafeBytes { raw in
            for y in 0 ..< height {
                for x in 0 ..< width {
                    for c in 0 ..< outComponents {
                        let channel = c + (alphaFirst ? 1 : 0)
                        let offset = y * rowBytes + (x * channels + channel) * (bpc / 8)
                        let value: UInt16
                        if bpc == 16 {
                            let r = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                            value = little16 ? UInt16(littleEndian: r) : UInt16(bigEndian: r)
                        } else {
                            value = UInt16(raw[offset])
                        }
                        samples[(y * width + x) * outComponents + c] = value
                    }
                }
            }
        }
        if outComponents == 3 && bpc == 16 {
            samples = samples.map { $0 >> 8 }
        }
        return try fromSamples(samples, width: width, height: height, components: outComponents, descriptor: descriptor)
    }

    /// JPEG 2000 through OpenJPEG, which keeps 12- and 16-bit samples.
    static func jpeg2000(_ bytes: Data, descriptor: PixelDescriptor) throws -> Frame {
        var image = kidicom_j2k_image()
        let status = bytes.withUnsafeBytes { raw in
            kidicom_j2k_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &image)
        }
        defer { kidicom_j2k_free(&image) }
        guard status == 0, let samples = image.samples else {
            throw DicomError.decodeFailed("JPEG 2000: OpenJPEG error \(status)")
        }
        let count = Int(image.width) * Int(image.height) * Int(image.components)
        // Stored values as 16-bit patterns; signed values keep two's complement,
        // which NativePixels sign-extends from Bits Stored.
        let values = (0 ..< count).map { UInt16(truncatingIfNeeded: samples[$0]) }
        return try fromSamples(values, width: Int(image.width), height: Int(image.height), components: Int(image.components), descriptor: descriptor)
    }
}

/// DICOM RLE (PS3.5 Annex G): a 64-byte header with up to 15 segment
/// offsets, one segment per byte plane, PackBits within each.
enum RLE {
    static func decode(_ data: Data, descriptor d: PixelDescriptor) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 64 else { throw DicomError.decodeFailed("RLE: short header") }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        let segmentCount = u32(0)
        let bytesPerSample = d.bitsAllocated / 8
        guard segmentCount == d.samplesPerPixel * bytesPerSample, segmentCount <= 15 else {
            throw DicomError.decodeFailed("RLE: \(segmentCount) segments for \(d.samplesPerPixel)x\(d.bitsAllocated) bits")
        }
        let pixels = d.pixelCount
        var out = [UInt8](repeating: 0, count: pixels * segmentCount)
        for s in 0 ..< segmentCount {
            let start = u32(4 + s * 4)
            let end = s + 1 < segmentCount ? u32(8 + s * 4) : bytes.count
            guard start >= 64, start <= end, end <= bytes.count else { throw DicomError.decodeFailed("RLE: bad offset") }
            let plane = packBits(bytes, from: start, to: end, count: pixels)
            // Segments are most significant byte first, per sample.
            let sample = s / bytesPerSample
            let byteInSample = bytesPerSample - 1 - s % bytesPerSample
            if d.samplesPerPixel == 1 {
                for i in 0 ..< pixels { out[i * bytesPerSample + byteInSample] = plane[i] }
            } else {
                // Color RLE is planar by definition; write interleaved.
                for i in 0 ..< pixels { out[(i * d.samplesPerPixel + sample) * bytesPerSample + byteInSample] = plane[i] }
            }
        }
        return Data(out)
    }

    static func packBits(_ bytes: [UInt8], from start: Int, to end: Int, count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var p = start
        while p < end && out.count < count {
            let n = Int(Int8(bitPattern: bytes[p]))
            p += 1
            if n >= 0 {
                let run = min(n + 1, end - p)
                out.append(contentsOf: bytes[p ..< p + run])
                p += run
            } else if n != -128, p < end {
                out.append(contentsOf: repeatElement(bytes[p], count: 1 - n))
                p += 1
            }
        }
        if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
        return Array(out.prefix(count))
    }
}
