import Foundation

public enum DicomError: Error, Equatable, Sendable {
    case notDicom
    case truncated(at: Int)
    case unsupportedTransferSyntax(String)
    case noPixelData
    case unsupportedPixelFormat(String)
    case frameOutOfRange(Int)
    case decodeFailed(String)
}

/// A parsed DICOM file: its meta header, its dataset, and how pixels are
/// encoded.
public struct DicomFile: Sendable {
    public let meta: DicomDataset?
    public let dataset: DicomDataset
    public let transferSyntax: TransferSyntax
}

/// Reads DICOM Part 10 files, with or without the 128-byte preamble, and
/// bare datasets in implicit or explicit VR.
public enum DicomParser {
    public static func parse(contentsOf url: URL, headerOnly: Bool = false) throws -> DicomFile {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(data, headerOnly: headerOnly)
    }

    /// - Parameter headerOnly: stop at the pixel data, for fast import.
    public static func parse(_ input: Data, headerOnly: Bool = false) throws -> DicomFile {
        // Work on data that starts at index 0, so offsets are plain ints.
        let data = input.startIndex == 0 ? input : Data(input)
        var position = 0
        var meta: DicomDataset?

        if data.count >= 132, data[128] == 0x44, data[129] == 0x49, data[130] == 0x43, data[131] == 0x4D {
            position = 132
        }
        if position == 132 || looksLikeMetaGroup(data) {
            var reader = Reader(data: data, position: position, explicit: true, little: true)
            meta = try reader.readDataset(until: .metaEnd)
            position = reader.position
        } else if position == 0, !looksLikeDataset(data) {
            throw DicomError.notDicom
        }

        let syntax: TransferSyntax
        if let uid = meta?.string(.transferSyntaxUID), !uid.isEmpty {
            syntax = TransferSyntax(uid: uid)
        } else {
            syntax = guessSyntax(data, at: position)
        }
        if syntax.isDeflated { throw DicomError.unsupportedTransferSyntax(syntax.uid) }

        var reader = Reader(
            data: data, position: position,
            explicit: !syntax.isImplicitVR, little: !syntax.isBigEndian,
            stopAtPixelData: headerOnly
        )
        let dataset = try reader.readDataset(until: .end)
        if dataset.elements.isEmpty && meta == nil { throw DicomError.notDicom }
        return DicomFile(meta: meta, dataset: dataset, transferSyntax: syntax)
    }

    /// A file without preamble that starts with group 0002 in explicit VR.
    private static func looksLikeMetaGroup(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return data[0] == 0x02 && data[1] == 0x00 && isVR(data[4], data[5])
    }

    /// A bare dataset starts with a low group number, in even order.
    private static func looksLikeDataset(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let group = UInt16(data[0]) | UInt16(data[1]) << 8
        return [0x0002, 0x0004, 0x0008, 0x0010, 0x0018, 0x0020, 0x0028].contains(group)
    }

    private static func guessSyntax(_ data: Data, at position: Int) -> TransferSyntax {
        guard data.count >= position + 6 else { return .implicitLittle }
        return isVR(data[position + 4], data[position + 5]) ? .explicitLittle : .implicitLittle
    }

    static func isVR(_ a: UInt8, _ b: UInt8) -> Bool {
        guard (0x41 ... 0x5A).contains(a), (0x41 ... 0x5A).contains(b) else { return false }
        return VR(rawValue: String(bytes: [a, b], encoding: .ascii) ?? "") != nil
    }
}

private struct Reader {
    enum Stop { case metaEnd, end, itemDelimiter, limit(Int) }

    let data: Data
    var position: Int
    let explicit: Bool
    let little: Bool
    var stopAtPixelData = false
    var encoding: String.Encoding = .isoLatin1
    private static let undefined = 0xFFFF_FFFF

    init(data: Data, position: Int, explicit: Bool, little: Bool, stopAtPixelData: Bool = false) {
        self.data = data
        self.position = position
        self.explicit = explicit
        self.little = little
        self.stopAtPixelData = stopAtPixelData
    }

    mutating func readDataset(until stop: Stop) throws -> DicomDataset {
        var dataset = DicomDataset(data: data, isLittleEndian: little)
        dataset.inherit(encoding: encoding)
        let end: Int
        if case .limit(let limit) = stop { end = min(limit, data.count) } else { end = data.count }

        while position + 8 <= end {
            let tag = DicomTag(u16(position), u16(position + 2))
            if case .metaEnd = stop, tag.group != 0x0002 { break }
            if tag == .itemDelimitation {
                position += 8
                if case .itemDelimiter = stop { break }
                continue
            }
            if tag == .sequenceDelimitation { position += 8; continue }
            // Trailing padding (zeros) at the end of a file.
            if tag.group == 0 && tag.element == 0 && u32(position + 4) == 0 { break }

            if tag == .pixelData && stopAtPixelData {
                let header = try readHeader(tag)
                dataset.add(DicomElement(tag: tag, vr: header.vr, offset: position, length: nil, items: nil, fragments: nil))
                position = end
                break
            }
            let element = try readElement()
            dataset.add(element)
            if tag == .specificCharacterSet {
                encoding = Self.encoding(for: dataset.string(.specificCharacterSet) ?? "")
                dataset.inherit(encoding: encoding)
            }
        }
        if case .limit(let limit) = stop { position = max(position, limit) }
        return dataset
    }

    private mutating func readHeader(_ tag: DicomTag) throws -> (vr: VR, length: Int) {
        guard position + 8 <= data.count else { throw DicomError.truncated(at: position) }
        if explicit && DicomParser.isVR(data[position + 4], data[position + 5]) {
            let vr = VR(rawValue: String(bytes: [data[position + 4], data[position + 5]], encoding: .ascii)!)!
            if vr.hasLongLength {
                guard position + 12 <= data.count else { throw DicomError.truncated(at: position) }
                let length = Int(u32(position + 8))
                position += 12
                return (vr, length)
            }
            let length = Int(u16(position + 6))
            position += 8
            return (vr, length)
        }
        // Implicit VR, or a broken explicit file that wrote no VR here.
        let length = Int(u32(position + 4))
        position += 8
        return (VR.implicit(tag), length)
    }

    private mutating func readElement() throws -> DicomElement {
        let tag = DicomTag(u16(position), u16(position + 2))
        let start = position
        let (vr, length) = try readHeader(tag)

        if tag == .pixelData && length == Self.undefined {
            let fragments = try readFragments()
            return DicomElement(tag: tag, vr: vr, offset: start, length: nil, items: nil, fragments: fragments)
        }
        if vr == .SQ || length == Self.undefined || (vr == .UN && startsWithItem()) {
            let items = try readItems(length: length == Self.undefined ? nil : length, implicitInside: vr == .UN)
            return DicomElement(tag: tag, vr: .SQ, offset: start, length: nil, items: items, fragments: nil)
        }
        guard position + length <= data.count else { throw DicomError.truncated(at: position) }
        let element = DicomElement(tag: tag, vr: vr, offset: position, length: length, items: nil, fragments: nil)
        position += length
        return element
    }

    private func startsWithItem() -> Bool {
        guard position + 4 <= data.count else { return false }
        return DicomTag(u16(position), u16(position + 2)) == .item
    }

    private mutating func readItems(length: Int?, implicitInside: Bool) throws -> [DicomDataset] {
        let end = length.map { position + $0 } ?? data.count
        guard end <= data.count else { throw DicomError.truncated(at: position) }
        var items: [DicomDataset] = []
        while position + 8 <= end {
            let tag = DicomTag(u16(position), u16(position + 2))
            let itemLength = Int(u32(position + 4))
            position += 8
            if tag == .sequenceDelimitation { break }
            guard tag == .item else { throw DicomError.truncated(at: position - 8) }
            // UN sequences are encoded in implicit VR little endian.
            var inner = Reader(data: data, position: position, explicit: implicitInside ? false : explicit, little: implicitInside ? true : little)
            inner.encoding = encoding
            let item: DicomDataset
            if itemLength == Self.undefined {
                item = try inner.readDataset(until: .itemDelimiter)
            } else {
                item = try inner.readDataset(until: .limit(position + itemLength))
            }
            position = inner.position
            items.append(item)
        }
        if length != nil { position = end }
        return items
    }

    private mutating func readFragments() throws -> [Range<Int>] {
        var fragments: [Range<Int>] = []
        while position + 8 <= data.count {
            let tag = DicomTag(u16(position), u16(position + 2))
            let length = Int(u32(position + 4))
            position += 8
            if tag == .sequenceDelimitation { return fragments }
            guard tag == .item, position + length <= data.count else { throw DicomError.truncated(at: position) }
            fragments.append(position ..< position + length)
            position += length
        }
        // Some files end without the sequence delimiter.
        return fragments
    }

    private func u16(_ at: Int) -> UInt16 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
        return little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    private func u32(_ at: Int) -> UInt32 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        return little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    static func encoding(for charset: String) -> String.Encoding {
        let terms = charset.split(separator: "\\").map { $0.trimmingCharacters(in: .whitespaces) }
        if terms.contains("ISO_IR 192") { return .utf8 }
        if terms.contains(where: { $0.hasSuffix("IR 100") }) { return .isoLatin1 }
        if terms.contains(where: { $0.hasSuffix("IR 101") }) { return .isoLatin2 }
        if terms.contains("GB18030") || terms.contains("GBK") {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        return .isoLatin1
    }
}
