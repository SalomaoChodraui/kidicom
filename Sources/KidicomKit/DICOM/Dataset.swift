import Foundation

/// One attribute: where its value sits in the file, or its items.
public struct DicomElement: Sendable {
    public let tag: DicomTag
    public let vr: VR
    /// Offset of the value in the file data.
    public let offset: Int
    /// Value length in bytes; nil when the length was undefined.
    public let length: Int?
    /// Items of a sequence (SQ, or UN that holds items).
    public let items: [DicomDataset]?
    /// Fragments of encapsulated (compressed) pixel data. The first one is
    /// the Basic Offset Table, possibly empty.
    public let fragments: [Range<Int>]?
}

/// A set of attributes read from a file. Values point into the file data,
/// so nothing is copied until a value is read.
public struct DicomDataset: Sendable {
    public let data: Data
    public let isLittleEndian: Bool
    public private(set) var elements: [DicomTag: DicomElement] = [:]
    /// String encoding from Specific Character Set (0008,0005).
    var encoding: String.Encoding = .isoLatin1

    init(data: Data, isLittleEndian: Bool) {
        self.data = data
        self.isLittleEndian = isLittleEndian
    }

    mutating func add(_ element: DicomElement) {
        elements[element.tag] = element
    }

    mutating func inherit(encoding: String.Encoding) {
        self.encoding = encoding
    }

    public subscript(tag: DicomTag) -> DicomElement? { elements[tag] }

    public func contains(_ tag: DicomTag) -> Bool { elements[tag] != nil }

    /// Raw value bytes. Empty for sequences and undefined lengths.
    public func bytes(_ tag: DicomTag) -> Data? {
        guard let element = elements[tag], let length = element.length else { return nil }
        return data.subdata(in: element.offset ..< element.offset + length)
    }

    /// The whole value as text, with trailing spaces and NULs trimmed.
    /// Multi-valued strings keep their backslashes.
    public func string(_ tag: DicomTag) -> String? {
        guard let element = elements[tag], let length = element.length else { return nil }
        guard element.vr.isText || element.vr == .UN else { return nil }
        let raw = data.subdata(in: element.offset ..< element.offset + length)
        let text = String(data: raw, encoding: encoding)
            ?? String(data: raw, encoding: .isoLatin1)
            ?? ""
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    /// The values of a multi-valued text attribute, split at backslashes.
    public func strings(_ tag: DicomTag) -> [String] {
        guard let text = string(tag), !text.isEmpty else { return [] }
        return text.split(separator: "\\", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Numeric values, from text (DS, IS) or binary (US, SS, UL, SL, FL, FD).
    public func numbers(_ tag: DicomTag) -> [Double] {
        guard let element = elements[tag], let length = element.length, length > 0 else { return [] }
        var vr = element.vr
        if vr == .UN { vr = VR.implicit(tag) }
        if vr.isText {
            return strings(tag).compactMap { Double($0) }
        }
        let size: Int
        switch vr {
        case .US, .SS: size = 2
        case .UL, .SL, .FL: size = 4
        case .FD: size = 8
        default: return []
        }
        let count = length / size
        return (0 ..< count).map { index in
            let at = element.offset + index * size
            switch vr {
            case .US: return Double(u16(at))
            case .SS: return Double(Int16(bitPattern: u16(at)))
            case .UL: return Double(u32(at))
            case .SL: return Double(Int32(bitPattern: u32(at)))
            case .FL: return Double(Float(bitPattern: u32(at)))
            default: return Double(bitPattern: u64(at))
            }
        }
    }

    public func number(_ tag: DicomTag) -> Double? { numbers(tag).first }

    public func int(_ tag: DicomTag) -> Int? { number(tag).map { Int($0) } }

    /// A DA value as a date at midnight UTC, like 20240131.
    public func date(_ tag: DicomTag) -> Date? {
        guard let text = string(tag) else { return nil }
        return DicomDate.parse(text)
    }

    public func sequence(_ tag: DicomTag) -> [DicomDataset] { elements[tag]?.items ?? [] }

    func u16(_ at: Int) -> UInt16 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
        return isLittleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    func u32(_ at: Int) -> UInt32 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        return isLittleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    func u64(_ at: Int) -> UInt64 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        return isLittleEndian ? UInt64(littleEndian: value) : UInt64(bigEndian: value)
    }
}

public enum DicomDate {
    /// Parses DA values: "20240131", and the old "2024.01.31".
    public static func parse(_ text: String) -> Date? {
        let digits = text.filter(\.isNumber)
        guard digits.count >= 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)),
              (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
