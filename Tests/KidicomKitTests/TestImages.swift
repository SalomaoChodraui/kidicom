import Foundation
@testable import KidicomKit

typealias DicomBuilder = DicomWriter

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
