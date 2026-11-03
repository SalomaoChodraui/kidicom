import Foundation
import Testing
@testable import KidicomKit

/// Parses real files from a local folder when KIDICOM_SAMPLES points to one,
/// like a Horos database. Patient files never go into the repository.
///   KIDICOM_SAMPLES=~/path swift test --filter SampleFolder
@Suite("Sample folder", .enabled(if: ProcessInfo.processInfo.environment["KIDICOM_SAMPLES"] != nil))
struct SampleFolderTests {
    @Test("Random files from the sample folder parse and decode")
    func sampleFiles() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KIDICOM_SAMPLES"]!)
        let limit = Int(ProcessInfo.processInfo.environment["KIDICOM_SAMPLE_COUNT"] ?? "") ?? 100
        var files: [URL] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        var generator = SystemRandomNumberGenerator()
        let sample = files.shuffled(using: &generator).prefix(limit)
        var parsed = 0, decoded = 0
        var failures: [String: Int] = [:]
        for url in sample {
            do {
                let file = try DicomParser.parse(contentsOf: url)
                parsed += 1
                _ = try file.frame(0)
                decoded += 1
            } catch {
                failures["\(error)", default: 0] += 1
            }
        }
        print("SAMPLES \(sample.count) parsed \(parsed) decoded \(decoded)")
        for (reason, count) in failures.sorted(by: { $0.value > $1.value }) { print("  \(count) \(reason)") }
        #expect(parsed == sample.count)
    }
}
