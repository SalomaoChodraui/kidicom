import Foundation

/// What the worklist needs from one image file, read from its header.
public struct InstanceRecord: Sendable, Equatable {
    public var url: URL
    public var studyUID: String
    public var seriesUID: String
    public var sopUID: String
    public var patientName = ""
    public var patientID = ""
    public var patientBirthDate: Date?
    public var patientSex = ""
    public var studyDate: Date?
    public var studyDescription = ""
    public var accessionNumber = ""
    public var modality = ""
    public var seriesNumber = 0
    public var seriesDescription = ""
    public var instanceNumber = 0
    public var imagePosition: [Double] = []
    public var imageOrientation: [Double] = []
    public var frameOfReferenceUID = ""
    public var frames = 1
    public var rows = 0
    public var columns = 0
    public var transferSyntaxUID = ""

    /// Reads the header of a DICOM image file. Files without pixel data
    /// (DICOMDIR, reports, presentation states) throw `noPixelData`.
    public init(contentsOf url: URL) throws {
        let file = try DicomParser.parse(contentsOf: url, headerOnly: true)
        try self.init(file: file, url: url)
    }

    public init(file: DicomFile, url: URL) throws {
        let d = file.dataset
        guard d.contains(.pixelData), let rows = d.int(.rows), let columns = d.int(.columns) else {
            throw DicomError.noPixelData
        }
        self.url = url
        // Files without UIDs still import, grouped by their file name.
        sopUID = d.string(.sopInstanceUID).nonEmpty
            ?? file.meta?.string(.mediaStorageSOPInstanceUID).nonEmpty
            ?? "kidicom.\(url.path.hashValue.magnitude)"
        studyUID = d.string(.studyInstanceUID).nonEmpty ?? "kidicom.study.\(d.string(.patientID) ?? "")"
        seriesUID = d.string(.seriesInstanceUID).nonEmpty ?? "\(studyUID).series"
        patientName = d.string(.patientName) ?? ""
        patientID = d.string(.patientID) ?? ""
        patientBirthDate = d.date(.patientBirthDate)
        patientSex = d.string(.patientSex) ?? ""
        studyDate = d.date(.studyDate) ?? d.date(.seriesDate)
        studyDescription = d.string(.studyDescription) ?? ""
        accessionNumber = d.string(.accessionNumber) ?? ""
        modality = d.string(.modality) ?? ""
        seriesNumber = d.int(.seriesNumber) ?? 0
        seriesDescription = d.string(.seriesDescription) ?? ""
        instanceNumber = d.int(.instanceNumber) ?? 0
        imagePosition = d.numbers(.imagePositionPatient)
        imageOrientation = d.numbers(.imageOrientationPatient)
        frameOfReferenceUID = d.string(.frameOfReferenceUID) ?? ""
        frames = max(1, d.int(.numberOfFrames) ?? 1)
        self.rows = rows
        self.columns = columns
        transferSyntaxUID = file.transferSyntax.uid
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
