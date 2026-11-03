import Foundation
import Testing
@testable import KidicomKit

@Suite("Tag dictionary")
struct TagDictionaryTests {
    @Test("Standard tags have readable names")
    func names() {
        #expect(TagDictionary.name(for: .patientName) == "Patient Name")
        #expect(TagDictionary.name(for: .sopClassUID) == "SOP Class UID")
        #expect(TagDictionary.name(for: .imagePositionPatient) == "Image Position Patient")
        #expect(TagDictionary.name(for: DicomTag(0x0029, 0x1010)) == "Private Tag")
        #expect(TagDictionary.name(for: DicomTag(0x0029, 0x0010)) == "Private Creator")
    }

    @Test("The dump lists tags in order with sequences indented")
    func dump() throws {
        var item = DicomWriter()
        item.text(.studyDescription, .LO, "inner")
        var w = DicomWriter()
        w.text(.patientName, .PN, "SILVA^MARIA")
        w.sequence(.sequenceOfUltrasoundRegions, items: [item])
        w.us(.rows, 512)
        w.text(.imagePositionPatient, .DS, "1\\2\\3")
        let rows = DicomDump.rows(try DicomParser.parse(w.build()))
        #expect(rows.map(\.tag) == [.transferSyntaxUID, .patientName, .sequenceOfUltrasoundRegions, .item, .studyDescription, .imagePositionPatient, .rows])
        #expect(rows.first { $0.tag == .rows }?.value == "512")
        #expect(rows.first { $0.tag == .sequenceOfUltrasoundRegions }?.value == "1 item")
        #expect(rows.first { $0.tag == .studyDescription }?.depth == 2)
        #expect(rows.first { $0.tag == .imagePositionPatient }?.value == "1\\2\\3")
    }
}
