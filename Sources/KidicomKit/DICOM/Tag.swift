import Foundation

/// A DICOM attribute tag, like (0010,0010) Patient's Name.
public struct DicomTag: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let group: UInt16
    public let element: UInt16

    public init(_ group: UInt16, _ element: UInt16) {
        self.group = group
        self.element = element
    }

    public var raw: UInt32 { UInt32(group) << 16 | UInt32(element) }

    public static func < (lhs: DicomTag, rhs: DicomTag) -> Bool { lhs.raw < rhs.raw }

    public var description: String {
        String(format: "(%04X,%04X)", group, element)
    }
}

public extension DicomTag {
    // File meta
    static let transferSyntaxUID = DicomTag(0x0002, 0x0010)
    static let mediaStorageSOPInstanceUID = DicomTag(0x0002, 0x0003)
    // Identification
    static let specificCharacterSet = DicomTag(0x0008, 0x0005)
    static let sopClassUID = DicomTag(0x0008, 0x0016)
    static let sopInstanceUID = DicomTag(0x0008, 0x0018)
    static let studyDate = DicomTag(0x0008, 0x0020)
    static let seriesDate = DicomTag(0x0008, 0x0021)
    static let studyTime = DicomTag(0x0008, 0x0030)
    static let accessionNumber = DicomTag(0x0008, 0x0050)
    static let modality = DicomTag(0x0008, 0x0060)
    static let studyDescription = DicomTag(0x0008, 0x1030)
    static let seriesDescription = DicomTag(0x0008, 0x103E)
    // Patient
    static let patientName = DicomTag(0x0010, 0x0010)
    static let patientID = DicomTag(0x0010, 0x0020)
    static let patientBirthDate = DicomTag(0x0010, 0x0030)
    static let patientSex = DicomTag(0x0010, 0x0040)
    // Acquisition
    static let sliceThickness = DicomTag(0x0018, 0x0050)
    static let cineRate = DicomTag(0x0018, 0x0040)
    static let frameTime = DicomTag(0x0018, 0x1063)
    static let sequenceOfUltrasoundRegions = DicomTag(0x0018, 0x6011)
    static let physicalUnitsXDirection = DicomTag(0x0018, 0x6024)
    static let physicalUnitsYDirection = DicomTag(0x0018, 0x6026)
    static let physicalDeltaX = DicomTag(0x0018, 0x602C)
    static let physicalDeltaY = DicomTag(0x0018, 0x602E)
    static let regionLocationMinX0 = DicomTag(0x0018, 0x6018)
    static let regionLocationMinY0 = DicomTag(0x0018, 0x601A)
    static let regionLocationMaxX1 = DicomTag(0x0018, 0x601C)
    static let regionLocationMaxY1 = DicomTag(0x0018, 0x601E)
    // Relationship
    static let studyInstanceUID = DicomTag(0x0020, 0x000D)
    static let seriesInstanceUID = DicomTag(0x0020, 0x000E)
    static let seriesNumber = DicomTag(0x0020, 0x0011)
    static let instanceNumber = DicomTag(0x0020, 0x0013)
    static let imagePositionPatient = DicomTag(0x0020, 0x0032)
    static let imageOrientationPatient = DicomTag(0x0020, 0x0037)
    static let frameOfReferenceUID = DicomTag(0x0020, 0x0052)
    static let sliceLocation = DicomTag(0x0020, 0x1041)
    // Image pixel
    static let samplesPerPixel = DicomTag(0x0028, 0x0002)
    static let photometricInterpretation = DicomTag(0x0028, 0x0004)
    static let planarConfiguration = DicomTag(0x0028, 0x0006)
    static let numberOfFrames = DicomTag(0x0028, 0x0008)
    static let rows = DicomTag(0x0028, 0x0010)
    static let columns = DicomTag(0x0028, 0x0011)
    static let pixelSpacing = DicomTag(0x0028, 0x0030)
    static let imagerPixelSpacing = DicomTag(0x0018, 0x1164)
    static let bitsAllocated = DicomTag(0x0028, 0x0100)
    static let bitsStored = DicomTag(0x0028, 0x0101)
    static let highBit = DicomTag(0x0028, 0x0102)
    static let pixelRepresentation = DicomTag(0x0028, 0x0103)
    static let windowCenter = DicomTag(0x0028, 0x1050)
    static let windowWidth = DicomTag(0x0028, 0x1051)
    static let rescaleIntercept = DicomTag(0x0028, 0x1052)
    static let rescaleSlope = DicomTag(0x0028, 0x1053)
    static let pixelData = DicomTag(0x7FE0, 0x0010)
    // Item delimiters (no VR)
    static let item = DicomTag(0xFFFE, 0xE000)
    static let itemDelimitation = DicomTag(0xFFFE, 0xE00D)
    static let sequenceDelimitation = DicomTag(0xFFFE, 0xE0DD)
    // DICOMDIR
    static let directoryRecordSequence = DicomTag(0x0004, 0x1220)
    static let referencedFileID = DicomTag(0x0004, 0x1500)
}
