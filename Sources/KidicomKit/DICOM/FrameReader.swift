import Foundation
import Synchronization

/// Where each frame's compressed bytes sit among the fragments of
/// encapsulated pixel data, worked out once per file.
public struct EncapsulatedIndex: Sendable {
    /// Fragments after the Basic Offset Table.
    let pieces: [Range<Int>]
    /// For each frame, the range of `pieces` that holds it; empty when the
    /// frame cannot be found.
    let spans: [Range<Int>]

    /// One fragment per frame is the common case; otherwise the Basic Offset
    /// Table, or all fragments for a single frame.
    public init(fragments: [Range<Int>], frames: Int, data: Data) throws {
        let pieces = Array(fragments.dropFirst())
        guard !pieces.isEmpty else { throw DicomError.noPixelData }
        self.pieces = pieces
        if frames == 1 {
            spans = [0 ..< pieces.count]
            return
        }
        var spans = [Range<Int>](repeating: 0 ..< 0, count: frames)
        let table = fragments[0]
        if table.count >= frames * 4 {
            let offsets = data.withUnsafeBytes { raw in
                (0 ..< frames).map { i in
                    Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: table.lowerBound + i * 4, as: UInt32.self)))
                }
            }
            // Offsets count from the first byte of the first fragment's item tag.
            let base = pieces[0].lowerBound - 8
            for index in 0 ..< frames {
                let start = base + offsets[index] + 8
                let end = index + 1 < frames ? base + offsets[index + 1] : pieces.last!.upperBound
                // Fragments run in file order: the frame's pieces are a run that
                // starts at the first fragment at or after `start`.
                var low = 0, high = pieces.count
                while low < high {
                    let mid = (low + high) / 2
                    if pieces[mid].lowerBound < start { low = mid + 1 } else { high = mid }
                }
                var last = low
                while last < pieces.count && pieces[last].upperBound <= end { last += 1 }
                spans[index] = low ..< last
            }
        }
        for index in 0 ..< frames where spans[index].isEmpty && index < pieces.count {
            spans[index] = index ..< index + 1
        }
        self.spans = spans
    }

    /// The compressed bytes of one frame.
    public func bytes(_ index: Int, in data: Data) throws -> Data {
        guard spans.indices.contains(index), !spans[index].isEmpty else { throw DicomError.frameOutOfRange(index) }
        let span = spans[index]
        if span.count == 1 { return data.subdata(in: pieces[span.lowerBound]) }
        var joined = Data()
        for piece in pieces[span] { joined.append(data.subdata(in: piece)) }
        return joined
    }
}

/// A parsed file ready to decode any of its frames without parsing it again
/// or rebuilding the frame index: what a cine needs on every frame.
public struct FrameReader: Sendable {
    public let file: DicomFile
    public let descriptor: PixelDescriptor
    let index: EncapsulatedIndex?

    public init(_ file: DicomFile) throws {
        self.file = file
        descriptor = try file.pixelDescriptor
        if let fragments = file.dataset[.pixelData]?.fragments {
            index = try EncapsulatedIndex(fragments: fragments, frames: descriptor.frames, data: file.dataset.data)
        } else {
            index = nil
        }
    }

    public func frame(_ number: Int) throws -> Frame {
        guard number >= 0, number < descriptor.frames else { throw DicomError.frameOutOfRange(number) }
        if let index {
            let bytes = try index.bytes(number, in: file.dataset.data)
            return try Codecs.decode(bytes, syntax: file.transferSyntax, descriptor: descriptor)
        }
        return try file.nativeFrame(number, descriptor: descriptor)
    }
}

/// A few recently read multiframe files, shared by every decode. Files with
/// one frame are read once per frame anyway, so they are not kept.
public final class FrameReaderCache: Sendable {
    public static let shared = FrameReaderCache(capacity: 4)

    private struct State {
        var readers: [URL: FrameReader] = [:]
        /// Least recently used first.
        var order: [URL] = []
    }
    private let state = Mutex(State())
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The reader for this file, parsed now or taken from the cache.
    public func reader(for url: URL) throws -> FrameReader {
        if let hit = state.withLock({ s -> FrameReader? in
            guard let reader = s.readers[url] else { return nil }
            s.order.removeAll { $0 == url }
            s.order.append(url)
            return reader
        }) {
            return hit
        }
        let reader = try FrameReader(DicomParser.parse(contentsOf: url))
        guard reader.descriptor.frames > 1 else { return reader }
        state.withLock { s in
            if s.readers[url] == nil { s.order.append(url) }
            s.readers[url] = reader
            while s.order.count > capacity { s.readers[s.order.removeFirst()] = nil }
        }
        return reader
    }

    public var count: Int { state.withLock { $0.readers.count } }

    public func removeAll() {
        state.withLock { $0 = State() }
    }
}
