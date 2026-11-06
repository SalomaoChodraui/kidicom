import Foundation

/// Synthetic studies with real pixels, for snapshots and the self-test:
/// a chest CT with a prior, an ultrasound cine, and a radiograph. No
/// patient data, only generated shapes.
public enum SampleStudies {
    public struct Spec: Sendable {
        public var patient: String
        public var patientID: String
        public var date: String
        public var description: String
    }

    /// Writes the sample files under `folder` and returns their URLs.
    @discardableResult
    public static func write(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let ct = Spec(patient: "SILVA^MARIA^C", patientID: "102938", date: "20261031", description: "TC TORAX SEM CONTRASTE")
        urls += try writeCT(ct, studyUID: "1.2.826.0.1.3680043.10.1.1", slices: 24, nodule: 6, folder: folder)
        let prior = Spec(patient: "SILVA^MARIA^C", patientID: "102938", date: "20250929", description: "TC TORAX SEM CONTRASTE")
        urls += try writeCT(prior, studyUID: "1.2.826.0.1.3680043.10.1.2", slices: 24, nodule: 4, folder: folder)
        let us = Spec(patient: "SANTOS^ANA^PAULA", patientID: "778812", date: "20261025", description: "US ABDOME TOTAL")
        urls.append(try writeUltrasound(us, studyUID: "1.2.826.0.1.3680043.10.1.3", folder: folder))
        let cr = Spec(patient: "PEREIRA^CARLOS", patientID: "220145", date: "20261022", description: "RX TORAX PA")
        urls.append(try writeRadiograph(cr, studyUID: "1.2.826.0.1.3680043.10.1.4", folder: folder))
        return urls
    }

    static func header(_ spec: Spec, studyUID: String, seriesUID: String, sopUID: String, modality: String, series: String, number: Int) -> DicomWriter {
        var w = DicomWriter()
        w.text(.specificCharacterSet, .CS, "ISO_IR 100")
        w.text(.sopClassUID, .UI, "1.2.840.10008.5.1.4.1.1.7")
        w.text(.sopInstanceUID, .UI, sopUID)
        w.text(.studyDate, .DA, spec.date)
        w.text(.modality, .CS, modality)
        w.text(.studyDescription, .LO, spec.description, encoding: .isoLatin1)
        w.text(.seriesDescription, .LO, series, encoding: .isoLatin1)
        w.text(.patientName, .PN, spec.patient, encoding: .isoLatin1)
        w.text(.patientID, .LO, spec.patientID)
        w.text(.studyInstanceUID, .UI, studyUID)
        w.text(.seriesInstanceUID, .UI, seriesUID)
        w.text(.seriesNumber, .IS, "1")
        w.text(.instanceNumber, .IS, "\(number)")
        return w
    }

    static func writeCT(_ spec: Spec, studyUID: String, slices: Int, nodule: Double, folder: URL) throws -> [URL] {
        let size = 64
        let seriesUID = studyUID + ".1"
        var urls: [URL] = []
        for z in 0 ..< slices {
            let sop = "\(seriesUID).\(z + 1)"
            var w = header(spec, studyUID: studyUID, seriesUID: seriesUID, sopUID: sop, modality: "CT", series: "AXIAL 2.5 mm", number: z + 1)
            w.text(.sliceThickness, .DS, "2.5")
            w.text(.imagePositionPatient, .DS, "-160\\-160\\\(Double(-z) * 2.5)")
            w.text(.imageOrientationPatient, .DS, "1\\0\\0\\0\\1\\0")
            w.text(.frameOfReferenceUID, .UI, studyUID + ".9")
            w.us(.samplesPerPixel, 1)
            w.text(.photometricInterpretation, .CS, "MONOCHROME2")
            w.us(.rows, UInt16(size))
            w.us(.columns, UInt16(size))
            w.text(.pixelSpacing, .DS, "5\\5")
            w.us(.bitsAllocated, 16)
            w.us(.bitsStored, 12)
            w.us(.highBit, 11)
            w.us(.pixelRepresentation, 0)
            w.text(.windowCenter, .DS, "40")
            w.text(.windowWidth, .DS, "400")
            w.text(.rescaleIntercept, .DS, "-1024")
            w.text(.rescaleSlope, .DS, "1")
            var pixels = Data(capacity: size * size * 2)
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let hu = phantomCT(x: x, y: y, z: z, size: size, slices: slices, nodule: nodule)
                    pixels.append(le16(UInt16(max(0, min(4095, hu + 1024)))))
                }
            }
            w.element(.pixelData, .OW, pixels)
            let url = folder.appending(path: "CT-\(studyUID.suffix(1))-\(z + 1)")
            try w.build().write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// A body ellipse with two lungs, a spine, and a round nodule.
    static func phantomCT(x: Int, y: Int, z: Int, size: Int, slices: Int, nodule: Double) -> Int {
        let fx = (Double(x) - Double(size) / 2) / (Double(size) / 2)
        let fy = (Double(y) - Double(size) / 2) / (Double(size) / 2)
        if fx * fx / 0.85 + fy * fy / 0.6 > 1 { return -1000 }
        let spine = (fx * fx + (fy - 0.45) * (fy - 0.45)) < 0.012
        if spine { return 700 }
        for side in [-0.4, 0.4] {
            let lung = (fx - side) * (fx - side) / 0.08 + fy * fy / 0.25
            if lung < 1 {
                let nx = fx - side, ny = fy + 0.1, nz = Double(z - slices / 2) / 6
                let r = nodule / 32
                return (side > 0 && nx * nx + ny * ny + nz * nz * r * r < r * r) ? 30 : -850
            }
        }
        return 40
    }

    static func writeUltrasound(_ spec: Spec, studyUID: String, folder: URL) throws -> URL {
        let width = 80, height = 60, frames = 8
        var w = header(spec, studyUID: studyUID, seriesUID: studyUID + ".1", sopUID: studyUID + ".1.1", modality: "US", series: "FIGADO", number: 1)
        w.us(.samplesPerPixel, 3)
        w.text(.photometricInterpretation, .CS, "RGB")
        w.us(.planarConfiguration, 0)
        w.text(.numberOfFrames, .IS, "\(frames)")
        w.text(.frameTime, .DS, "40")
        w.us(.rows, UInt16(height))
        w.us(.columns, UInt16(width))
        w.us(.bitsAllocated, 8)
        w.us(.bitsStored, 8)
        w.us(.highBit, 7)
        w.us(.pixelRepresentation, 0)
        var pixels = Data(capacity: width * height * 3 * frames)
        for f in 0 ..< frames {
            for y in 0 ..< height {
                for x in 0 ..< width {
                    // A fan of speckle with a pulsing round vessel in color.
                    let dx = Double(x - width / 2), dy = Double(y)
                    let inFan = dy > 2 && abs(dx) < dy * 0.8
                    let speckle = UInt8((x * 37 + y * 91 + f * 13) % 60 + (inFan ? 60 : 0))
                    let vx = dx, vy = dy - 34
                    let r = 8 + 2 * sin(Double(f) / Double(frames) * 2 * .pi)
                    if inFan && vx * vx + vy * vy < r * r {
                        pixels.append(contentsOf: [200, 30, 40])
                    } else {
                        pixels.append(contentsOf: inFan ? [speckle, speckle, speckle] : [0, 0, 0])
                    }
                }
            }
        }
        w.element(.pixelData, .OB, pixels)
        let url = folder.appending(path: "US-1")
        try w.build().write(to: url)
        return url
    }

    static func writeRadiograph(_ spec: Spec, studyUID: String, folder: URL) throws -> URL {
        let size = 128
        var w = header(spec, studyUID: studyUID, seriesUID: studyUID + ".1", sopUID: studyUID + ".1.1", modality: "CR", series: "PA", number: 1)
        w.us(.samplesPerPixel, 1)
        // MONOCHROME1: low values show white, as many radiographs do.
        w.text(.photometricInterpretation, .CS, "MONOCHROME1")
        w.us(.rows, UInt16(size))
        w.us(.columns, UInt16(size))
        w.text(.pixelSpacing, .DS, "2.8\\2.8")
        w.us(.bitsAllocated, 16)
        w.us(.bitsStored, 12)
        w.us(.highBit, 11)
        w.us(.pixelRepresentation, 0)
        w.text(.windowCenter, .DS, "2048")
        w.text(.windowWidth, .DS, "4096")
        var pixels = Data(capacity: size * size * 2)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let ct = phantomCT(x: x / 2, y: y / 2, z: 12, size: 64, slices: 24, nodule: 0)
                // Radiograph: dense structures attenuate, so they get low values.
                let value = 3600 - (ct + 1000) * 3 / 2
                pixels.append(le16(UInt16(max(0, min(4095, value)))))
            }
        }
        w.element(.pixelData, .OW, pixels)
        let url = folder.appending(path: "CR-1")
        try w.build().write(to: url)
        return url
    }
}
