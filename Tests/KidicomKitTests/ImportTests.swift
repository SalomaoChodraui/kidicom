import Foundation
import Synchronization
import Testing
@testable import KidicomKit

@Suite("Import")
struct ImportTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "kidicom-import-\(UUID().uuidString)")

    @Test("Sample studies are readable images")
    func samples() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try SampleStudies.write(to: root)
        #expect(urls.count == 50)
        let records = try urls.map { try InstanceRecord(contentsOf: $0) }
        #expect(Set(records.map(\.studyUID)).count == 4)
        let us = try #require(records.first { $0.modality == "US" })
        #expect(us.frames == 8)
        let ct = try #require(records.first { $0.modality == "CT" && $0.instanceNumber == 3 })
        #expect(ct.imagePosition == [-160, -160, -5])
        #expect(ct.patientName == "SILVA^MARIA^C")
        let file = try DicomParser.parse(contentsOf: ct.url)
        guard case .grayscale(let hu) = try file.frame(0) else { Issue.record("not gray"); return }
        #expect(hu.min() == -1000)
    }

    @Test("Scanning finds DICOM by content and skips JPG, PDF, DICOMDIR, and macOS junk")
    func scanFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cd = root.appending(path: "CD/DICOM/5WKSINVZ")
        try SampleStudies.write(to: cd)
        try Data("jpeg".utf8).write(to: root.appending(path: "CD/foto.jpg"))
        try Data("%PDF".utf8).write(to: root.appending(path: "CD/laudo.pdf"))
        try Data(count: 200).write(to: root.appending(path: "CD/DICOMDIR"))
        try FileManager.default.createDirectory(at: root.appending(path: "CD/__MACOSX"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "CD/__MACOSX/._CT-1-1"))
        try Data("x".utf8).write(to: root.appending(path: "CD/._foto.jpg"))

        let scan = try ImportScanner.scan([root.appending(path: "CD")], temporaryRoot: root.appending(path: "tmp"))
        #expect(scan.files.count == 50)
        #expect(scan.skipped == 3)
        #expect(!scan.containsArchives)
    }

    @Test("Zips are expanded, nested zips too, and marked as archives")
    func scanZip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src/2026-05-11")
        try SampleStudies.write(to: source.appending(path: "Imagens"))
        try Data("jpeg".utf8).write(to: source.appending(path: "Imagens/jpeg.jpg"))
        let zip = root.appending(path: "exame.zip")
        try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path])

        let scan = try ImportScanner.scan([zip], temporaryRoot: root.appending(path: "tmp"))
        #expect(scan.files.count == 50)
        #expect(scan.skipped == 1)
        #expect(scan.containsArchives)
        let temp = root.appending(path: "tmp").resolvingSymlinksInPath().path
        #expect(scan.files.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(temp) })
    }

    @Test("A cancel stops a folder walk between files")
    func cancelWalk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try SampleStudies.write(to: root.appending(path: "CD"))
        let calls = Mutex(0)
        // Cancelled after the first few files of the walk.
        let scan = try ImportScanner.scan([root.appending(path: "CD")], temporaryRoot: root.appending(path: "tmp")) {
            calls.withLock { $0 += 1; return $0 > 5 }
        }
        #expect(scan.files.count < 50)
    }

    @Test("A cancel stops ditto and leaves the expanded folder to clean up")
    func cancelZip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // Random bytes do not compress, so ditto takes a while to expand them.
        for index in 0 ..< 3 {
            var bytes = [UInt8](repeating: 0, count: 40_000_000)
            bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try Data(bytes).write(to: source.appending(path: "f\(index).bin"))
        }
        let zip = root.appending(path: "big.zip")
        try ditto(["-c", "-k", source.path, zip.path])
        // Calls: before the dropped item, before the zip, then once ditto runs.
        let calls = Mutex(0)
        let scan = try ImportScanner.scan([zip], temporaryRoot: root.appending(path: "tmp")) {
            calls.withLock { $0 += 1; return $0 >= 3 }
        }
        #expect(scan.files.isEmpty)
        #expect(scan.temporaryFolders.count == 1)
        let folder = try #require(scan.temporaryFolders.first)
        let expanded = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = expanded.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        #expect(bytes < 120_000_000, "ditto was stopped before it expanded everything")
    }

    @Test("Bare datasets without preamble are recognized")
    func bareDataset() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var w = DicomWriter(explicit: false, preamble: false, meta: false)
        w.text(.sopInstanceUID, .UI, "1.2.3")
        let url = root.appending(path: "IM0001")
        try w.build().write(to: url)
        #expect(ImportScanner.isDicom(url))
    }

    @Test("Library paths are safe file names")
    func libraryPath() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try SampleStudies.write(to: root)
        var record = try InstanceRecord(contentsOf: urls[0])
        #expect(LibraryPath.relativePath(for: record) == "Files/1.2.826.0.1.3680043.10.1.1/1.2.826.0.1.3680043.10.1.1.1/1.2.826.0.1.3680043.10.1.1.1.1.dcm")
        record.studyUID = "../../etc"
        #expect(!LibraryPath.relativePath(for: record).contains("/../"))
    }

    func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }
}
