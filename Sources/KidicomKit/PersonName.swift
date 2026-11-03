import Foundation

/// DICOM Person Name (PN): "Family^Given^Middle^Prefix^Suffix", with up to
/// three groups split by "=" (alphabetic, ideographic, phonetic).
public enum PersonName {
    /// Readable form of the alphabetic group: "SILVA^MARIA^C" becomes
    /// "Silva, Maria C". An empty name stays empty; the app shows its own word.
    public static func display(_ raw: String) -> String {
        let alphabetic = raw.split(separator: "=", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = alphabetic.split(separator: "^", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let family = parts.first.map(capitalize) ?? ""
        let rest = parts.dropFirst().prefix(2).filter { !$0.isEmpty }.map(capitalize).joined(separator: " ")
        switch (family.isEmpty, rest.isEmpty) {
        case (true, true): return ""
        case (false, true): return family
        case (true, false): return rest
        case (false, false): return "\(family), \(rest)"
        }
    }

    /// Capitalizes names stored in upper case and keeps mixed case as is.
    private static func capitalize(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words == words.uppercased() ? words.capitalized : words
    }
}
