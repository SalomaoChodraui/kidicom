import Foundation
@testable import KidicomKit

/// Writes small DICOM files for tests, in explicit or implicit VR.
struct DicomBuilder {
    var explicit = true
    var preamble = true
    var meta = true
    private var body = Data()

    init(explicit: Bool = true, preamble: Bool = true, meta: Bool = true) {
        self.explicit = explicit
        self.preamble = preamble
        self.meta = meta
    }

    var syntaxUID: String { explicit ? "1.2.840.10008.1.2.1" : "1.2.840.10008.1.2" }

    mutating func text(_ tag: DicomTag, _ vr: VR, _ value: String, encoding: String.Encoding = .ascii) {
        var bytes = value.data(using: encoding)!
        if bytes.count % 2 == 1 { bytes.append(vr == .UI ? 0 : 0x20) }
        element(tag, vr, bytes)
    }

    mutating func us(_ tag: DicomTag, _ value: UInt16) {
        element(tag, .US, le16(value))
    }

    mutating func element(_ tag: DicomTag, _ vr: VR, _ value: Data, undefinedLength: Bool = false) {
        body.append(header(tag, vr, undefinedLength ? 0xFFFF_FFFF : value.count, explicit: explicit))
        body.append(value)
    }

    /// A sequence of undefined length whose items have undefined length.
    mutating func sequence(_ tag: DicomTag, items: [DicomBuilder]) {
        body.append(header(tag, .SQ, 0xFFFF_FFFF, explicit: explicit))
        for item in items {
            body.append(le16(0xFFFE) + le16(0xE000) + le32(0xFFFF_FFFF))
            body.append(item.body)
            body.append(le16(0xFFFE) + le16(0xE00D) + le32(0))
        }
        body.append(le16(0xFFFE) + le16(0xE0DD) + le32(0))
    }

    func build() -> Data {
        var out = Data()
        if preamble {
            out.append(Data(count: 128))
            out.append("DICM".data(using: .ascii)!)
        }
        if meta {
            var uid = syntaxUID.data(using: .ascii)!
            if uid.count % 2 == 1 { uid.append(0) }
            out.append(header(.transferSyntaxUID, .UI, uid.count, explicit: true))
            out.append(uid)
        }
        out.append(body)
        return out
    }

    private func header(_ tag: DicomTag, _ vr: VR, _ length: Int, explicit: Bool) -> Data {
        var d = le16(tag.group) + le16(tag.element)
        if explicit {
            d.append(vr.rawValue.data(using: .ascii)!)
            if vr.hasLongLength {
                d.append(le16(0) + le32(UInt32(truncatingIfNeeded: length)))
            } else {
                d.append(le16(UInt16(length)))
            }
        } else {
            d.append(le32(UInt32(truncatingIfNeeded: length)))
        }
        return d
    }
}

func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

/// A 16-bit grayscale image with the given stored values.
func grayImage(
    explicit: Bool = true, preamble: Bool = true, meta: Bool = true,
    rows: UInt16 = 2, columns: UInt16 = 2, stored: [UInt16],
    bitsStored: UInt16 = 16, highBit: UInt16? = nil, signed: Bool = false,
    slope: String? = nil, intercept: String? = nil, photometric: String = "MONOCHROME2"
) -> Data {
    var b = DicomBuilder(explicit: explicit, preamble: preamble, meta: meta)
    b.text(.patientName, .PN, "SILVA^MARIA")
    b.text(.studyInstanceUID, .UI, "1.2.3.4")
    b.us(.samplesPerPixel, 1)
    b.text(.photometricInterpretation, .CS, photometric)
    b.us(.rows, rows)
    b.us(.columns, columns)
    b.us(.bitsAllocated, 16)
    b.us(.bitsStored, bitsStored)
    b.us(.highBit, highBit ?? bitsStored - 1)
    b.us(.pixelRepresentation, signed ? 1 : 0)
    if let intercept { b.text(.rescaleIntercept, .DS, intercept) }
    if let slope { b.text(.rescaleSlope, .DS, slope) }
    var pixels = Data()
    for v in stored { pixels.append(le16(v)) }
    b.element(.pixelData, .OW, pixels)
    return b.build()
}
