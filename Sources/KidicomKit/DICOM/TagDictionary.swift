import Foundation

/// Names of DICOM tags, from the standard's data dictionary.
public enum TagDictionary {
    private static let entries: [UInt32: (vr: String, keyword: String)] = {
        var map: [UInt32: (String, String)] = [:]
        map.reserveCapacity(5000)
        for line in TagNames.table.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let raw = UInt32(parts[0], radix: 16) else { continue }
            map[raw] = (String(parts[1]), String(parts[2]))
        }
        return map
    }()

    /// The keyword, like "PatientName", or nil for private and unknown tags.
    public static func keyword(for tag: DicomTag) -> String? {
        if tag.element == 0 { return "GroupLength" }
        return entries[tag.raw]?.keyword
    }

    /// A readable name: "PatientName" becomes "Patient Name", "SOPClassUID"
    /// becomes "SOP Class UID". Private tags say so.
    public static func name(for tag: DicomTag) -> String {
        if let keyword = keyword(for: tag) { return spaced(keyword) }
        if tag.group % 2 == 1 { return tag.element < 0x0100 ? "Private Creator" : "Private Tag" }
        return "Unknown Tag"
    }

    static func spaced(_ keyword: String) -> String {
        var out = ""
        let chars = Array(keyword)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase || (c.isNumber && !chars[i - 1].isNumber) {
                let previous = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if previous.isLowercase || (previous.isUppercase && nextIsLower) || (c.isNumber && !previous.isNumber) {
                    out.append(" ")
                }
            }
            out.append(c)
        }
        return out
    }
}

/// One line of a tag listing.
public struct TagRow: Identifiable, Sendable, Equatable {
    public let id: Int
    public let depth: Int
    public let tag: DicomTag
    public let name: String
    public let vr: String
    public let value: String
}

/// Lists a dataset's attributes in tag order, sequences indented.
public enum DicomDump {
    public static func rows(_ file: DicomFile) -> [TagRow] {
        var rows: [TagRow] = []
        if let meta = file.meta { append(meta, depth: 0, to: &rows) }
        append(file.dataset, depth: 0, to: &rows)
        return rows
    }

    static func append(_ dataset: DicomDataset, depth: Int, to rows: inout [TagRow]) {
        for tag in dataset.elements.keys.sorted() {
            guard let element = dataset[tag] else { continue }
            rows.append(TagRow(id: rows.count, depth: depth, tag: tag, name: TagDictionary.name(for: tag),
                               vr: element.vr.rawValue, value: value(of: element, in: dataset)))
            if let items = element.items {
                for (index, item) in items.enumerated() {
                    rows.append(TagRow(id: rows.count, depth: depth + 1, tag: .item, name: "Item \(index + 1)", vr: "", value: ""))
                    append(item, depth: depth + 2, to: &rows)
                }
            }
        }
    }

    static func value(of element: DicomElement, in dataset: DicomDataset) -> String {
        if let items = element.items { return items.count == 1 ? "1 item" : "\(items.count) items" }
        if let fragments = element.fragments {
            let bytes = fragments.dropFirst().reduce(0) { $0 + $1.count }
            return "\(fragments.count - 1) fragments, \(bytes.formatted()) bytes"
        }
        guard let length = element.length else { return "" }
        let vr = element.vr == .UN ? VR.implicit(element.tag) : element.vr
        if vr.isText, let text = dataset.string(element.tag) {
            return text.count > 200 ? String(text.prefix(200)) + "…" : text
        }
        switch vr {
        case .US, .SS, .UL, .SL, .FL, .FD:
            let numbers = dataset.numbers(element.tag)
            let shown = numbers.prefix(16).map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int64($0)) : String($0) }
            return shown.joined(separator: "\\") + (numbers.count > 16 ? "…" : "")
        case .AT:
            guard length >= 4 else { return "" }
            return DicomTag(dataset.u16(element.offset), dataset.u16(element.offset + 2)).description
        default:
            return "\(length.formatted()) bytes"
        }
    }
}
