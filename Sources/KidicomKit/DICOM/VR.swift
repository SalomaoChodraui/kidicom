import Foundation

/// Value Representation: the data type of an attribute.
public enum VR: String, Sendable, CaseIterable {
    case AE, AS, AT, CS, DA, DS, DT, FL, FD, IS, LO, LT, OB, OD, OF, OL, OV, OW
    case PN, SH, SL, SQ, SS, ST, SV, TM, UC, UI, UL, UN, UR, US, UT, UV

    /// In explicit VR syntaxes these VRs have two reserved bytes and a
    /// 32-bit length; the others have a 16-bit length.
    var hasLongLength: Bool {
        switch self {
        case .OB, .OD, .OF, .OL, .OV, .OW, .SQ, .UC, .UN, .UR, .UT, .SV, .UV: true
        default: false
        }
    }

    /// Text VRs hold characters; the rest hold binary numbers or bytes.
    var isText: Bool {
        switch self {
        case .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT: true
        default: false
        }
    }

    /// The VR of a tag in implicit VR files. Only tags the app reads and
    /// common sequences are listed; others come back as UN.
    static func implicit(_ tag: DicomTag) -> VR {
        if tag.element == 0x0000 { return .UL }  // group length
        if let vr = dictionary[tag.raw] { return vr }
        if tag.group == 0x7FE0 && tag.element == 0x0010 { return .OW }
        return .UN
    }

    private static let dictionary: [UInt32: VR] = [
        0x0002_0010: .UI, 0x0002_0003: .UI, 0x0002_0002: .UI,
        0x0008_0005: .CS, 0x0008_0008: .CS, 0x0008_0016: .UI, 0x0008_0018: .UI,
        0x0008_0020: .DA, 0x0008_0021: .DA, 0x0008_0030: .TM, 0x0008_0050: .SH,
        0x0008_0060: .CS, 0x0008_0061: .CS, 0x0008_0070: .LO, 0x0008_0080: .LO, 0x0008_0090: .PN,
        0x0008_1030: .LO, 0x0008_103E: .LO,
        0x0008_1110: .SQ, 0x0008_1115: .SQ, 0x0008_1140: .SQ, 0x0008_1250: .SQ, 0x0008_2112: .SQ,
        0x0010_0010: .PN, 0x0010_0020: .LO, 0x0010_0030: .DA, 0x0010_0040: .CS, 0x0010_1010: .AS,
        0x0018_0015: .CS, 0x0018_0040: .IS, 0x0018_0050: .DS, 0x0018_0088: .DS, 0x0018_1063: .DS,
        0x0018_1164: .DS, 0x0018_5100: .CS,
        0x0018_6011: .SQ, 0x0018_6012: .US, 0x0018_6014: .US, 0x0018_6016: .UL,
        0x0018_6018: .UL, 0x0018_601A: .UL, 0x0018_601C: .UL, 0x0018_601E: .UL,
        0x0018_6024: .US, 0x0018_6026: .US, 0x0018_602C: .FD, 0x0018_602E: .FD,
        0x0020_000D: .UI, 0x0020_000E: .UI, 0x0020_0010: .SH, 0x0020_0011: .IS, 0x0020_0013: .IS,
        0x0020_0020: .CS, 0x0020_0032: .DS, 0x0020_0037: .DS, 0x0020_0052: .UI, 0x0020_1041: .DS,
        0x0020_9113: .SQ, 0x0020_9116: .SQ,
        0x0028_0002: .US, 0x0028_0004: .CS, 0x0028_0006: .US, 0x0028_0008: .IS,
        0x0028_0010: .US, 0x0028_0011: .US, 0x0028_0030: .DS, 0x0028_0034: .IS,
        0x0028_0100: .US, 0x0028_0101: .US, 0x0028_0102: .US, 0x0028_0103: .US,
        0x0028_1050: .DS, 0x0028_1051: .DS, 0x0028_1052: .DS, 0x0028_1053: .DS, 0x0028_1054: .LO,
        0x0028_1101: .US, 0x0028_1102: .US, 0x0028_1103: .US,
        0x0028_1201: .OW, 0x0028_1202: .OW, 0x0028_1203: .OW,
        0x0028_3000: .SQ, 0x0028_3010: .SQ, 0x0028_9110: .SQ, 0x0028_9132: .SQ, 0x0028_9145: .SQ,
        0x0040_0275: .SQ, 0x0040_0260: .SQ, 0x0040_A730: .SQ,
        0x0004_1220: .SQ, 0x0004_1430: .CS, 0x0004_1500: .CS, 0x0004_1510: .UI, 0x0004_1511: .UI,
        0x0004_1512: .UI,
        0x5200_9229: .SQ, 0x5200_9230: .SQ,
    ]
}
