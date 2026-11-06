import Foundation
@testable import KidicomKit

/// An RLE 16-bit grayscale cine: `frames` frames of `side`², each frame one
/// fragment, with or without a Basic Offset Table. Frame f holds the value f
/// everywhere.
func rleCine(frames: Int, side: Int = 8, offsetTable: Bool = true) -> Data {
    func plane(_ byte: UInt8) -> Data {
        // Replicate runs of up to 128 bytes: header 257 - n, then the byte.
        var out = Data()
        var left = side * side
        while left > 0 {
            let n = min(128, left)
            out.append(contentsOf: [UInt8(truncatingIfNeeded: 257 - n), byte])
            left -= n
        }
        return out
    }
    var encoded: [Data] = []
    for f in 0 ..< frames {
        let value = UInt16(f)
        let high = plane(UInt8(value >> 8)), low = plane(UInt8(value & 0xFF))
        var header = le32(2) + le32(64) + le32(UInt32(64 + high.count))
        header.append(Data(count: 64 - header.count))
        var frame = header + high + low
        if frame.count % 2 == 1 { frame.append(0) }
        encoded.append(frame)
    }
    var b = DicomWriter()
    b.us(.samplesPerPixel, 1)
    b.text(.photometricInterpretation, .CS, "MONOCHROME2")
    b.text(.numberOfFrames, .IS, "\(frames)")
    b.us(.rows, UInt16(side)); b.us(.columns, UInt16(side))
    b.us(.bitsAllocated, 16); b.us(.bitsStored, 16); b.us(.highBit, 15); b.us(.pixelRepresentation, 0)
    var pixel = Data()
    if offsetTable {
        var table = Data()
        var offset = 0
        for frame in encoded {
            table.append(le32(UInt32(offset)))
            offset += 8 + frame.count
        }
        pixel.append(le16(0xFFFE) + le16(0xE000) + le32(UInt32(table.count)))
        pixel.append(table)
    } else {
        pixel.append(le16(0xFFFE) + le16(0xE000) + le32(0))
    }
    for frame in encoded {
        pixel.append(le16(0xFFFE) + le16(0xE000) + le32(UInt32(frame.count)))
        pixel.append(frame)
    }
    pixel.append(le16(0xFFFE) + le16(0xE0DD) + le32(0))
    b.element(.pixelData, .OB, pixel, undefinedLength: true)
    var out = b.build()
    // Point the meta header at RLE.
    let explicitUID = "1.2.840.10008.1.2.1\0".data(using: .ascii)!
    if let range = out.range(of: explicitUID) {
        var uid = "1.2.840.10008.1.2.5".data(using: .ascii)!
        if uid.count % 2 == 1 { uid.append(0) }
        var rebuilt = out[..<(range.lowerBound - 2)]
        rebuilt.append(le16(UInt16(uid.count)))
        rebuilt.append(uid)
        rebuilt.append(out[range.upperBound...])
        out = Data(rebuilt)
    }
    return out
}
