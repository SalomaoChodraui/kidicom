import Foundation

/// The Image Pixel module: how samples are laid out in each frame.
public struct PixelDescriptor: Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var samplesPerPixel: Int
    public var bitsAllocated: Int
    public var bitsStored: Int
    public var highBit: Int
    public var isSigned: Bool
    public var photometric: String
    /// 0: RGBRGB..., 1: RRR...GGG...BBB...
    public var planarConfiguration: Int
    public var frames: Int
    public var rescaleSlope: Double
    public var rescaleIntercept: Double

    public init(_ dataset: DicomDataset) throws {
        guard let rows = dataset.int(.rows), let columns = dataset.int(.columns), rows > 0, columns > 0 else {
            throw DicomError.noPixelData
        }
        self.rows = rows
        self.columns = columns
        samplesPerPixel = dataset.int(.samplesPerPixel) ?? 1
        bitsAllocated = dataset.int(.bitsAllocated) ?? 16
        bitsStored = dataset.int(.bitsStored) ?? bitsAllocated
        highBit = dataset.int(.highBit) ?? (bitsStored - 1)
        isSigned = dataset.int(.pixelRepresentation) == 1
        photometric = dataset.string(.photometricInterpretation)?.uppercased() ?? (samplesPerPixel == 3 ? "RGB" : "MONOCHROME2")
        planarConfiguration = dataset.int(.planarConfiguration) ?? 0
        frames = max(1, dataset.int(.numberOfFrames) ?? 1)
        let slope = dataset.number(.rescaleSlope) ?? 1
        rescaleSlope = slope == 0 ? 1 : slope
        rescaleIntercept = dataset.number(.rescaleIntercept) ?? 0
    }

    public var isMonochrome: Bool { photometric.hasPrefix("MONOCHROME") }
    /// MONOCHROME1 shows low values as white.
    public var isInverted: Bool { photometric == "MONOCHROME1" }
    public var pixelCount: Int { rows * columns }
    public var bytesPerFrame: Int { pixelCount * samplesPerPixel * bitsAllocated / 8 }
}

/// One decoded frame.
public enum Frame: Sendable {
    /// Modality values (rescale applied, like Hounsfield units), row by row.
    case grayscale([Float])
    /// 8-bit RGBA, row by row.
    case color([UInt8])
}

public extension DicomFile {
    var pixelDescriptor: PixelDescriptor {
        get throws { try PixelDescriptor(dataset) }
    }

    /// Decodes one frame of native (uncompressed) pixel data. Compressed
    /// syntaxes go through the codecs.
    func frame(_ index: Int) throws -> Frame {
        let descriptor = try pixelDescriptor
        guard index >= 0, index < descriptor.frames else { throw DicomError.frameOutOfRange(index) }
        guard let element = dataset[.pixelData] else { throw DicomError.noPixelData }
        if let fragments = element.fragments {
            let bytes = try encapsulatedFrame(index, fragments: fragments, frames: descriptor.frames)
            return try Codecs.decode(bytes, syntax: transferSyntax, descriptor: descriptor)
        }
        guard transferSyntax.isNative else {
            throw DicomError.unsupportedTransferSyntax(transferSyntax.uid)
        }
        guard let length = element.length else { throw DicomError.noPixelData }
        let frameBytes = descriptor.bytesPerFrame
        let start = element.offset + index * frameBytes
        guard frameBytes > 0, start + frameBytes <= element.offset + length else {
            throw DicomError.truncated(at: start)
        }
        let bytes = dataset.data.subdata(in: start ..< start + frameBytes)
        return try NativePixels.decode(bytes, descriptor: descriptor, littleEndian: dataset.isLittleEndian)
    }

    /// The compressed bytes of one frame. One fragment per frame is the
    /// common case; otherwise the Basic Offset Table, or all fragments for a
    /// single frame.
    func encapsulatedFrame(_ index: Int, fragments: [Range<Int>], frames: Int) throws -> Data {
        let data = dataset.data
        let pieces = Array(fragments.dropFirst())
        guard !pieces.isEmpty else { throw DicomError.noPixelData }
        if frames == 1 {
            if pieces.count == 1 { return data.subdata(in: pieces[0]) }
            var joined = Data()
            for piece in pieces { joined.append(data.subdata(in: piece)) }
            return joined
        }
        let table = fragments[0]
        if table.count >= frames * 4 {
            let offsets = (0 ..< frames).map { i in
                Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: table.lowerBound + i * 4, as: UInt32.self) }))
            }
            // Offsets count from the first byte of the first fragment's item tag.
            let base = pieces[0].lowerBound - 8
            let start = base + offsets[index]
            let end = index + 1 < frames ? base + offsets[index + 1] : pieces.last!.upperBound
            var joined = Data()
            for piece in pieces where piece.lowerBound >= start + 8 && piece.upperBound <= end {
                joined.append(data.subdata(in: piece))
            }
            if !joined.isEmpty { return joined }
        }
        guard index < pieces.count else { throw DicomError.frameOutOfRange(index) }
        return data.subdata(in: pieces[index])
    }
}

/// Uncompressed samples to modality values or RGBA.
public enum NativePixels {
    public static func decode(_ bytes: Data, descriptor d: PixelDescriptor, littleEndian: Bool = true) throws -> Frame {
        if d.isMonochrome && d.samplesPerPixel == 1 {
            return .grayscale(try grayscale(bytes, d, littleEndian))
        }
        if d.samplesPerPixel == 3 && d.bitsAllocated == 8 {
            return .color(color(bytes, d))
        }
        throw DicomError.unsupportedPixelFormat("\(d.photometric) \(d.samplesPerPixel)x\(d.bitsAllocated) bits")
    }

    static func grayscale(_ bytes: Data, _ d: PixelDescriptor, _ little: Bool) throws -> [Float] {
        let count = d.pixelCount
        let stored = max(1, min(d.bitsStored, d.bitsAllocated))
        let shift = max(0, d.highBit + 1 - stored)
        let mask: UInt32 = stored >= 32 ? .max : (1 << UInt32(stored)) - 1
        let signBit: UInt32 = 1 << UInt32(stored - 1)
        let slope = Float(d.rescaleSlope)
        let intercept = Float(d.rescaleIntercept)
        var out = [Float](repeating: 0, count: count)

        func value(_ raw: UInt32) -> Float {
            var v = (raw >> UInt32(shift)) & mask
            if d.isSigned && v & signBit != 0 {
                v |= ~mask
                return Float(Int32(bitPattern: v)) * slope + intercept
            }
            return Float(v) * slope + intercept
        }

        try bytes.withUnsafeBytes { raw in
            switch d.bitsAllocated {
            case 8:
                guard raw.count >= count else { throw DicomError.truncated(at: raw.count) }
                for i in 0 ..< count { out[i] = value(UInt32(raw[i])) }
            case 16:
                guard raw.count >= count * 2 else { throw DicomError.truncated(at: raw.count) }
                for i in 0 ..< count {
                    let r = raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                    out[i] = value(UInt32(little ? UInt16(littleEndian: r) : UInt16(bigEndian: r)))
                }
            case 32:
                guard raw.count >= count * 4 else { throw DicomError.truncated(at: raw.count) }
                for i in 0 ..< count {
                    let r = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    out[i] = value(little ? UInt32(littleEndian: r) : UInt32(bigEndian: r))
                }
            default:
                throw DicomError.unsupportedPixelFormat("\(d.bitsAllocated) bits allocated")
            }
        }
        return out
    }

    static func color(_ bytes: Data, _ d: PixelDescriptor) -> [UInt8] {
        let count = d.pixelCount
        var out = [UInt8](repeating: 255, count: count * 4)
        let ybr = d.photometric.hasPrefix("YBR_FULL")
        bytes.withUnsafeBytes { raw in
            for i in 0 ..< count {
                var a: Float, b: Float, c: Float
                if d.planarConfiguration == 1 {
                    a = Float(raw[i]); b = Float(raw[count + i]); c = Float(raw[2 * count + i])
                } else {
                    a = Float(raw[i * 3]); b = Float(raw[i * 3 + 1]); c = Float(raw[i * 3 + 2])
                }
                if ybr { (a, b, c) = Color.ybrToRGB(a, b, c) }
                out[i * 4] = Color.clamp(a)
                out[i * 4 + 1] = Color.clamp(b)
                out[i * 4 + 2] = Color.clamp(c)
            }
        }
        return out
    }
}

enum Color {
    /// YBR_FULL to RGB (PS3.3 C.7.6.3.1.2).
    static func ybrToRGB(_ y: Float, _ cb: Float, _ cr: Float) -> (Float, Float, Float) {
        (y + 1.402 * (cr - 128),
         y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128),
         y + 1.772 * (cb - 128))
    }

    static func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
}

/// VOIWindow center and width to 8-bit gray, by the DICOM linear function
/// (PS3.3 C.11.2.1.2).
public struct VOIWindow: Sendable, Equatable {
    public var center: Double
    public var width: Double

    public init(center: Double, width: Double) {
        self.center = center
        self.width = max(1, width)
    }

    public func gray(_ value: Float, inverted: Bool = false) -> UInt8 {
        let c = center - 0.5
        let w = width - 1
        let x = Double(value)
        let out: Double
        if x <= c - w / 2 { out = 0 }
        else if x > c + w / 2 { out = 255 }
        else { out = ((x - c) / max(w, 1) + 0.5) * 255 }
        let gray = UInt8(max(0, min(255, out.rounded())))
        return inverted ? 255 - gray : gray
    }

    /// The window stored in the file, or one that spans the frame's values.
    public static func initial(for dataset: DicomDataset, values: [Float]) -> VOIWindow {
        if let center = dataset.number(.windowCenter), let width = dataset.number(.windowWidth), width > 0 {
            return VOIWindow(center: center, width: width)
        }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        return VOIWindow(center: Double(low + high) / 2, width: Double(high - low) + 1)
    }
}
