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

/// Compares compressed frames with reference decoders installed by
/// Homebrew (dcmtk's dcmdjpeg and dcmdrle, OpenJPEG's opj_decompress).
@Suite("Reference decoders", .enabled(if: ProcessInfo.processInfo.environment["KIDICOM_SAMPLES"] != nil))
struct ReferenceDecoderTests {
    @Test("Compressed frames match the reference decoders sample by sample")
    func matchesReference() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KIDICOM_SAMPLES"]!)
        let limit = Int(ProcessInfo.processInfo.environment["KIDICOM_SAMPLE_COUNT"] ?? "") ?? 40
        let temp = FileManager.default.temporaryDirectory.appending(path: "kidicom-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var checked: [String: Int] = [:]
        var mismatches: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var seen = 0
        while let url = walker?.nextObject() as? URL, checked.values.reduce(0, +) < limit {
            seen += 1
            let only = ProcessInfo.processInfo.environment["KIDICOM_SYNTAX"]
            guard seen % 7 == 0, let file = try? DicomParser.parse(contentsOf: url), !file.transferSyntax.isNative,
                  only == nil || file.transferSyntax.uid == only,
                  let d = try? file.pixelDescriptor, d.samplesPerPixel == 1,
                  let frame = try? file.frame(0), case .grayscale(let ours) = frame else { continue }
            let reference: [Float]
            switch file.transferSyntax {
            case .jpegLossless, .jpegLosslessSV1, .rle:
                let out = temp.appending(path: "out.dcm")
                let tool = file.transferSyntax == .rle ? "/opt/homebrew/bin/dcmdrle" : "/opt/homebrew/bin/dcmdjpeg"
                guard run(tool, [url.path, out.path]) else { continue }
                guard let plain = try? DicomParser.parse(contentsOf: out), case .grayscale(let values) = try plain.frame(0) else { continue }
                reference = values
            case .jpeg2000Lossless:
                guard let element = file.dataset[.pixelData], let fragments = element.fragments else { continue }
                let stream = try file.encapsulatedFrame(0, fragments: fragments, frames: d.frames)
                let input = temp.appending(path: "in.j2k"), output = temp.appending(path: "out.rawl")
                try stream.write(to: input)
                guard run("/opt/homebrew/bin/opj_decompress", ["-i", input.path, "-o", output.path, "-quiet"]) else { continue }
                var plainDescriptor = d
                plainDescriptor.bitsAllocated = 16
                let raw = try Data(contentsOf: output)
                guard case .grayscale(let values) = try NativePixels.decode(raw, descriptor: plainDescriptor) else { continue }
                reference = values
            default:
                continue
            }
            checked[file.transferSyntax.uid, default: 0] += 1
            if ours != reference {
                let diff = zip(ours, reference).map { abs($0 - $1) }.max() ?? -1
                mismatches.append("\(file.transferSyntax.uid) \(url.lastPathComponent) max diff \(diff)")
            }
        }
        print("REFERENCE checked \(checked) mismatches \(mismatches.count)")
        for line in mismatches.prefix(10) { print("  \(line)") }
        #expect(mismatches.isEmpty)
        #expect(!checked.isEmpty)
    }

    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
