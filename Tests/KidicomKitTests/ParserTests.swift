import Foundation
import Testing
@testable import KidicomKit

@Suite("DICOM parser")
struct ParserTests {
    @Test("Explicit VR with preamble")
    func explicitWithPreamble() throws {
        let file = try DicomParser.parse(grayImage(stored: [1, 2, 3, 4]))
        #expect(file.transferSyntax == .explicitLittle)
        #expect(file.dataset.string(.patientName) == "SILVA^MARIA")
        #expect(file.dataset.int(.rows) == 2)
        #expect(file.dataset.string(.studyInstanceUID) == "1.2.3.4")
    }

    @Test("Implicit VR without preamble or meta header")
    func implicitBare() throws {
        let file = try DicomParser.parse(grayImage(explicit: false, preamble: false, meta: false, stored: [1, 2, 3, 4]))
        #expect(file.transferSyntax == .implicitLittle)
        #expect(file.dataset.int(.columns) == 2)
        guard case .grayscale(let values) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(values == [1, 2, 3, 4])
    }

    @Test("Explicit VR without preamble but with meta group")
    func explicitNoPreamble() throws {
        let file = try DicomParser.parse(grayImage(preamble: false, stored: [9, 9, 9, 9]))
        #expect(file.meta != nil)
        #expect(file.dataset.int(.bitsAllocated) == 16)
    }

    @Test("Sequences of undefined length, nested, with elements after them", arguments: [true, false])
    func sequences(explicit: Bool) throws {
        var inner = DicomBuilder(explicit: explicit)
        inner.text(.physicalDeltaX, .CS, "0.1")
        var item = DicomBuilder(explicit: explicit)
        item.text(.studyDescription, .LO, "inner")
        item.sequence(DicomTag(0x0008, 0x1140), items: [inner])
        var b = DicomBuilder(explicit: explicit)
        b.text(.patientID, .LO, "123")
        b.sequence(.sequenceOfUltrasoundRegions, items: [item, item])
        b.text(.studyDescription, .LO, "after")
        let file = try DicomParser.parse(b.build())
        let items = file.dataset.sequence(.sequenceOfUltrasoundRegions)
        #expect(items.count == 2)
        #expect(items[0].string(.studyDescription) == "inner")
        #expect(items[0].sequence(DicomTag(0x0008, 0x1140)).count == 1)
        #expect(file.dataset.string(.studyDescription) == "after")
        #expect(file.dataset.string(.patientID) == "123")
    }

    @Test("Header-only parse stops at pixel data")
    func headerOnly() throws {
        let file = try DicomParser.parse(grayImage(stored: [1, 2, 3, 4]), headerOnly: true)
        #expect(file.dataset.contains(.pixelData))
        #expect(file.dataset.string(.patientName) == "SILVA^MARIA")
    }

    @Test("Latin-1 names keep their accents")
    func latin1() throws {
        var b = DicomBuilder()
        b.text(.specificCharacterSet, .CS, "ISO_IR 100")
        b.text(.patientName, .PN, "CONCEIÇÃO^JOSÉ", encoding: .isoLatin1)
        let file = try DicomParser.parse(b.build())
        #expect(file.dataset.string(.patientName) == "CONCEIÇÃO^JOSÉ")
    }

    @Test("UTF-8 names with ISO_IR 192")
    func utf8() throws {
        var b = DicomBuilder()
        b.text(.specificCharacterSet, .CS, "ISO_IR 192")
        b.text(.patientName, .PN, "JOÃO^ANDRÉ", encoding: .utf8)
        let file = try DicomParser.parse(b.build())
        #expect(file.dataset.string(.patientName) == "JOÃO^ANDRÉ")
    }

    @Test("Multi-valued numbers and dates")
    func numbers() throws {
        var b = DicomBuilder()
        b.text(.imagePositionPatient, .DS, "-120.5\\-90\\33.25")
        b.text(.studyDate, .DA, "20240131")
        let file = try DicomParser.parse(b.build())
        #expect(file.dataset.numbers(.imagePositionPatient) == [-120.5, -90, 33.25])
        #expect(file.dataset.date(.studyDate) == DicomDate.parse("2024.01.31"))
    }

    @Test("A file that is not DICOM throws")
    func notDicom() {
        #expect(throws: DicomError.notDicom) {
            try DicomParser.parse(Data("%PDF-1.7 hello world, this is not an image".utf8))
        }
        #expect(throws: (any Error).self) { try DicomParser.parse(Data()) }
    }

    @Test("A truncated file throws instead of crashing")
    func truncated() {
        let full = grayImage(stored: [1, 2, 3, 4])
        for cut in stride(from: 140, to: full.count - 1, by: 7) {
            let data = full.prefix(cut)
            // Either throws or parses fewer elements; never crashes.
            if let file = try? DicomParser.parse(Data(data)) {
                #expect(file.dataset.elements.count <= 13)
                _ = try? file.frame(0)
            }
        }
        #expect(throws: (any Error).self) { try DicomParser.parse(Data(full.prefix(full.count - 3))) }
    }
}

@Suite("Native pixels")
struct PixelTests {
    @Test("Signed 16-bit CT with rescale gives Hounsfield units")
    func hounsfield() throws {
        // -1000 stored as Int16 two's complement, intercept -1024.
        let stored: [UInt16] = [UInt16(bitPattern: -1000), 0, 1024, 2048]
        let file = try DicomParser.parse(grayImage(stored: stored, signed: true, slope: "1", intercept: "-1024"))
        guard case .grayscale(let hu) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(hu == [-2024, -1024, 0, 1024])
    }

    @Test("12 bits stored masks the unused high bits")
    func twelveBits() throws {
        let file = try DicomParser.parse(grayImage(stored: [0xF123, 0x0FFF, 0, 0x8001], bitsStored: 12))
        guard case .grayscale(let values) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(values == [0x123, 0xFFF, 0, 1])
    }

    @Test("Signed 12 bits sign-extends")
    func signedTwelve() throws {
        let file = try DicomParser.parse(grayImage(stored: [0x0FFF, 0x0800, 0x07FF, 0], bitsStored: 12, signed: true))
        guard case .grayscale(let values) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(values == [-1, -2048, 2047, 0])
    }

    @Test("Slope scales values")
    func slope() throws {
        let file = try DicomParser.parse(grayImage(stored: [10, 20, 30, 40], slope: "0.5", intercept: "2"))
        guard case .grayscale(let values) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(values == [7, 12, 17, 22])
    }

    @Test("MONOCHROME1 inverts the gray")
    func monochrome1() throws {
        let file = try DicomParser.parse(grayImage(stored: [0, 0, 0, 0], photometric: "MONOCHROME1"))
        let descriptor = try file.pixelDescriptor
        #expect(descriptor.isInverted)
        let window = Window(center: 50, width: 101)
        // Below and above the window clamp to black and white; inverted swaps them.
        #expect(window.gray(-10, inverted: true) == 255)
        #expect(window.gray(110, inverted: true) == 0)
        #expect(window.gray(-10) == 0)
        #expect(window.gray(110) == 255)
        #expect((127 ... 129).contains(window.gray(50)))
    }

    @Test("A frame index past the end throws")
    func frameRange() throws {
        let file = try DicomParser.parse(grayImage(stored: [1, 2, 3, 4]))
        #expect(throws: DicomError.frameOutOfRange(1)) { try file.frame(1) }
    }

    @Test("RGB interleaved and planar, and YBR_FULL")
    func color() throws {
        var base = PixelDescriptor.test(samples: 3, bits: 8, photometric: "RGB")
        let interleaved = Data([255, 0, 0, 0, 255, 0])
        base.columns = 2
        guard case .color(let rgba) = try NativePixels.decode(interleaved, descriptor: base) else { Issue.record(); return }
        #expect(rgba == [255, 0, 0, 255, 0, 255, 0, 255])
        base.planarConfiguration = 1
        let planar = Data([255, 0, 0, 255, 0, 0])
        guard case .color(let rgba2) = try NativePixels.decode(planar, descriptor: base) else { Issue.record(); return }
        #expect(rgba2 == [255, 0, 0, 255, 0, 255, 0, 255])
        base.planarConfiguration = 0
        base.photometric = "YBR_FULL"
        guard case .color(let gray) = try NativePixels.decode(Data([128, 128, 128, 128, 128, 128]), descriptor: base) else { Issue.record(); return }
        #expect(gray == [128, 128, 128, 255, 128, 128, 128, 255])
    }
}

extension PixelDescriptor {
    static func test(samples: Int, bits: Int, photometric: String) -> PixelDescriptor {
        var b = DicomBuilder()
        b.us(.rows, 1)
        b.us(.columns, 1)
        b.us(.samplesPerPixel, UInt16(samples))
        b.us(.bitsAllocated, UInt16(bits))
        b.text(.photometricInterpretation, .CS, photometric)
        return try! PixelDescriptor(DicomParser.parse(b.build()).dataset)
    }
}
