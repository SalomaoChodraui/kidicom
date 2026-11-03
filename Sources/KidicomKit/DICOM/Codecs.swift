import Foundation

/// Decoders for compressed transfer syntaxes. Filled in by story S-002.
enum Codecs {
    static func decode(_ bytes: Data, syntax: TransferSyntax, descriptor: PixelDescriptor) throws -> Frame {
        throw DicomError.unsupportedTransferSyntax(syntax.uid)
    }
}
