import Foundation
import Testing
@testable import KidicomKit

/// Times one pass through every frame of a long cine, and the sync search.
/// Opt-in: BENCH=1.
@Suite struct MultiframeBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
    func cinePass() throws {
        for frames in [500, 2000, 8000] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("kidicom-bench-cine-\(frames).dcm")
            try rleCine(frames: frames).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            var start = Date()
            for i in 0 ..< frames {
                // What the viewer did before: parse the file and index its frames for every frame.
                let file = try DicomParser.parse(contentsOf: url)
                let d = try file.pixelDescriptor
                let bytes = try oldEncapsulatedFrame(file, i, fragments: file.dataset[.pixelData]!.fragments!, frames: d.frames)
                _ = try Codecs.decode(bytes, syntax: file.transferSyntax, descriptor: d)
            }
            let before = Date().timeIntervalSince(start) * 1000
            let cache = FrameReaderCache(capacity: 4)
            start = Date()
            for i in 0 ..< frames { _ = try cache.reader(for: url).frame(i) }
            let after = Date().timeIntervalSince(start) * 1000
            print("BENCH cine \(frames) frames: parse per frame \(Int(before)) ms, cached reader \(Int(after)) ms")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
    func syncSearch() {
        let locations: [Double?] = (0 ..< 2000).map { Double($0) * 0.625 }
        let index = LocationIndex(locations)
        let targets = (0 ..< 2000).map { Double($0) * 0.625 + 0.1 }
        var start = Date()
        var sum = 0
        for t in targets {
            var best = 0, distance = Double.infinity
            for (i, l) in locations.enumerated() where abs(l! - t) < distance { distance = abs(l! - t); best = i }
            sum &+= best
        }
        let linear = Date().timeIntervalSince(start) * 1000
        start = Date()
        for t in targets { sum &+= index.nearest(to: t) ?? 0 }
        let binary = Date().timeIntervalSince(start) * 1000
        print("BENCH sync 2000 steps on 2000 slices: scan \(String(format: "%.1f", linear)) ms, binary \(String(format: "%.2f", binary)) ms (\(sum % 7))")
    }
}

/// The frame lookup before FrameReader: the offset table read whole for every frame.
private func oldEncapsulatedFrame(_ file: DicomFile, _ index: Int, fragments: [Range<Int>], frames: Int) throws -> Data {
    let data = file.dataset.data
    let pieces = Array(fragments.dropFirst())
    let table = fragments[0]
    if table.count >= frames * 4 {
        let offsets = (0 ..< frames).map { i in
            Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: table.lowerBound + i * 4, as: UInt32.self) }))
        }
        let base = pieces[0].lowerBound - 8
        let start = base + offsets[index]
        let end = index + 1 < frames ? base + offsets[index + 1] : pieces.last!.upperBound
        var joined = Data()
        for piece in pieces where piece.lowerBound >= start + 8 && piece.upperBound <= end {
            joined.append(data.subdata(in: piece))
        }
        if !joined.isEmpty { return joined }
    }
    return data.subdata(in: pieces[index])
}
