import Foundation

/// How a file encodes its dataset and its pixels.
public struct TransferSyntax: Hashable, Sendable {
    public let uid: String

    public init(uid: String) {
        self.uid = uid.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    public static let implicitLittle = TransferSyntax(uid: "1.2.840.10008.1.2")
    public static let explicitLittle = TransferSyntax(uid: "1.2.840.10008.1.2.1")
    public static let deflatedExplicitLittle = TransferSyntax(uid: "1.2.840.10008.1.2.1.99")
    public static let explicitBig = TransferSyntax(uid: "1.2.840.10008.1.2.2")
    public static let jpegBaseline = TransferSyntax(uid: "1.2.840.10008.1.2.4.50")
    public static let jpegExtended = TransferSyntax(uid: "1.2.840.10008.1.2.4.51")
    public static let jpegLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.57")
    public static let jpegLosslessSV1 = TransferSyntax(uid: "1.2.840.10008.1.2.4.70")
    public static let jpegLSLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.80")
    public static let jpegLSNearLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.81")
    public static let jpeg2000Lossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.90")
    public static let jpeg2000 = TransferSyntax(uid: "1.2.840.10008.1.2.4.91")
    public static let rle = TransferSyntax(uid: "1.2.840.10008.1.2.5")

    public var isImplicitVR: Bool { self == .implicitLittle }
    public var isBigEndian: Bool { self == .explicitBig }
    public var isDeflated: Bool { self == .deflatedExplicitLittle }

    /// Pixel data stored as plain samples, not compressed fragments.
    public var isNative: Bool {
        self == .implicitLittle || self == .explicitLittle || self == .explicitBig || self == .deflatedExplicitLittle
    }
}
