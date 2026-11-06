import Foundation

/// JPEG Lossless (process 14, SOF3) decoder: transfer syntaxes .4.57 and
/// .4.70. Huffman coded differences from one of seven predictors, 2 to 16
/// bits, one or more components, restart intervals, point transform.
public enum JPEGLossless {
    public struct Image: Sendable {
        public let width: Int
        public let height: Int
        public let components: Int
        public let precision: Int
        /// Samples interleaved by component, row by row.
        public let samples: [UInt16]
    }

    public static func decode(_ data: Data) throws -> Image {
        try data.withUnsafeBytes { raw in
            var decoder = Decoder(bytes: raw.bindMemory(to: UInt8.self))
            return try decoder.decode()
        }
    }
}

private struct HuffmanTable {
    /// Codes up to 9 bits: index by the next 9 bits, gives length << 8 | value.
    var fast = [UInt16](repeating: 0, count: 512)
    var maxCode = [Int32](repeating: -1, count: 18)
    var valOffset = [Int32](repeating: 0, count: 18)
    var values: [UInt8] = []

    init(counts: [Int], values: [UInt8]) {
        self.values = values
        var code: Int32 = 0
        var k = 0
        for length in 1 ... 16 {
            let count = counts[length - 1]
            valOffset[length] = Int32(k) - code
            if count > 0 {
                for _ in 0 ..< count {
                    if length <= 9 {
                        let shift = 9 - length
                        let base = Int(code) << shift
                        for fill in 0 ..< (1 << shift) {
                            fast[base + fill] = UInt16(length) << 8 | UInt16(values[k])
                        }
                    }
                    code += 1
                    k += 1
                }
                maxCode[length] = code - 1
            }
            code <<= 1
        }
        maxCode[17] = .max
    }
}

private struct Component {
    var id: Int
    var table = 0
}

private struct Decoder {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0
    var tables: [Int: HuffmanTable] = [:]
    var width = 0, height = 0, precision = 0
    var components: [Component] = []
    var restartInterval = 0

    // Bit reader state.
    var bitBuffer: UInt64 = 0
    var bitCount = 0
    var hitMarker = false

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func decode() throws -> JPEGLossless.Image {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw DicomError.decodeFailed("JPEG: no SOI marker")
        }
        position = 2
        while position + 4 <= bytes.count {
            guard bytes[position] == 0xFF else { position += 1; continue }
            let marker = bytes[position + 1]
            position += 2
            if marker == 0xFF { position -= 1; continue }  // fill byte
            if marker == 0xD8 || (0xD0 ... 0xD7).contains(marker) || marker == 0x01 { continue }
            if marker == 0xD9 { break }
            let length = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            let segment = position + 2
            let next = position + length
            guard next <= bytes.count else { throw DicomError.decodeFailed("JPEG: segment past end") }
            switch marker {
            case 0xC4: try readHuffman(from: segment, to: next)
            case 0xC3, 0xC7, 0xCB, 0xCF:
                if marker != 0xC3 { throw DicomError.decodeFailed("JPEG: only SOF3 lossless is supported") }
                try readFrame(at: segment)
            case 0xC0, 0xC1, 0xC2:
                throw DicomError.decodeFailed("JPEG: lossy frame in a lossless syntax")
            case 0xDD: restartInterval = Int(bytes[segment]) << 8 | Int(bytes[segment + 1])
            case 0xDA:
                position = next
                return try readScan(header: segment)
            default: break
            }
            position = next
        }
        throw DicomError.decodeFailed("JPEG: no scan")
    }

    mutating func readHuffman(from start: Int, to end: Int) throws {
        var p = start
        while p + 17 <= end {
            let id = Int(bytes[p] & 0x0F)
            let counts = (0 ..< 16).map { Int(bytes[p + 1 + $0]) }
            let total = counts.reduce(0, +)
            p += 17
            guard p + total <= end else { throw DicomError.decodeFailed("JPEG: bad Huffman table") }
            let values = Array(bytes[p ..< p + total])
            p += total
            tables[id] = HuffmanTable(counts: counts, values: values)
        }
    }

    mutating func readFrame(at p: Int) throws {
        precision = Int(bytes[p])
        height = Int(bytes[p + 1]) << 8 | Int(bytes[p + 2])
        width = Int(bytes[p + 3]) << 8 | Int(bytes[p + 4])
        let count = Int(bytes[p + 5])
        components = (0 ..< count).map { Component(id: Int(bytes[p + 6 + $0 * 3])) }
        guard width > 0, height > 0, (2 ... 16).contains(precision), count >= 1 else {
            throw DicomError.decodeFailed("JPEG: bad frame header")
        }
    }

    mutating func readScan(header p: Int) throws -> JPEGLossless.Image {
        let count = Int(bytes[p])
        var order: [Int] = []
        for i in 0 ..< count {
            let id = Int(bytes[p + 1 + i * 2])
            let table = Int(bytes[p + 2 + i * 2] >> 4)
            guard let index = components.firstIndex(where: { $0.id == id }) else {
                throw DicomError.decodeFailed("JPEG: unknown component")
            }
            components[index].table = table
            order.append(index)
        }
        let predictor = Int(bytes[p + 1 + count * 2])
        let pointTransform = Int(bytes[p + 3 + count * 2] & 0x0F)
        guard (0 ... 7).contains(predictor) else { throw DicomError.decodeFailed("JPEG: bad predictor") }
        guard count == components.count else { throw DicomError.decodeFailed("JPEG: multi-scan images are not supported") }
        let huffman = try order.map { index -> HuffmanTable in
            guard let table = tables[components[index].table] else { throw DicomError.decodeFailed("JPEG: missing Huffman table") }
            return table
        }

        let n = count
        let rowLength = width * n
        var out = [UInt16](repeating: 0, count: rowLength * height)
        let mask = Int32((1 << precision) - 1)
        let initial = Int32(1 << (precision - pointTransform - 1))
        var sinceRestart = 0
        var firstLine = true

        try out.withUnsafeMutableBufferPointer { out in
            for y in 0 ..< height {
                for x in 0 ..< width {
                    if restartInterval > 0 && sinceRestart == restartInterval {
                        try restart()
                        sinceRestart = 0
                        firstLine = true
                    }
                    let restartedHere = sinceRestart == 0 && restartInterval > 0 && !(y == 0 && x == 0)
                    for c in 0 ..< n {
                        let diff = try decodeDifference(huffman[c])
                        let at = y * rowLength + x * n + c
                        let prediction: Int32
                        // The first sample of the image and of each restart
                        // interval uses the default; the rest of that line
                        // predicts from the left.
                        if (y == 0 && x == 0) || restartedHere {
                            prediction = initial
                        } else if firstLine {
                            prediction = Int32(out[at - n])
                        } else if x == 0 {
                            prediction = Int32(out[at - rowLength])
                        } else {
                            let a = Int32(out[at - n])
                            let b = Int32(out[at - rowLength])
                            let cc = Int32(out[at - rowLength - n])
                            switch predictor {
                            case 0, 1: prediction = a
                            case 2: prediction = b
                            case 3: prediction = cc
                            case 4: prediction = a + b - cc
                            case 5: prediction = a + ((b - cc) >> 1)
                            case 6: prediction = b + ((a - cc) >> 1)
                            default: prediction = (a + b) >> 1
                            }
                        }
                        out[at] = UInt16(truncatingIfNeeded: (prediction + diff) & mask)
                    }
                    sinceRestart += 1
                }
                firstLine = false
            }
            if pointTransform > 0 {
                for i in 0 ..< out.count { out[i] <<= UInt16(pointTransform) }
            }
        }
        return JPEGLossless.Image(width: width, height: height, components: n, precision: precision, samples: out)
    }

    // MARK: Entropy decoding

    @inline(__always)
    mutating func fill() {
        while bitCount <= 56 {
            var byte: UInt8 = 0
            if !hitMarker && position < bytes.count {
                byte = bytes[position]
                if byte == 0xFF {
                    let next = position + 1 < bytes.count ? bytes[position + 1] : 0
                    if next == 0x00 {
                        position += 2
                    } else {
                        hitMarker = true
                        byte = 0
                    }
                } else {
                    position += 1
                }
            }
            bitBuffer |= UInt64(byte) << UInt64(56 - bitCount)
            bitCount += 8
        }
    }

    @inline(__always)
    mutating func bits(_ n: Int) -> Int32 {
        if n == 0 { return 0 }
        if bitCount < n { fill() }
        let value = Int32(truncatingIfNeeded: bitBuffer >> UInt64(64 - n))
        bitBuffer <<= UInt64(n)
        bitCount -= n
        return value
    }

    @inline(__always)
    mutating func decodeDifference(_ table: HuffmanTable) throws -> Int32 {
        if bitCount < 16 { fill() }
        let peek = Int(bitBuffer >> 55)
        let entry = table.fast[peek]
        var category: Int
        if entry != 0 {
            let length = Int(entry >> 8)
            bitBuffer <<= UInt64(length)
            bitCount -= length
            category = Int(entry & 0xFF)
        } else {
            var code: Int32 = 0
            var length = 0
            repeat {
                code = code << 1 | bits(1)
                length += 1
            } while length <= 16 && code > table.maxCode[length]
            guard length <= 16 else { throw DicomError.decodeFailed("JPEG: bad Huffman code") }
            category = Int(table.values[Int(code + table.valOffset[length])])
        }
        if category == 0 { return 0 }
        if category == 16 { return 32768 }
        let raw = bits(category)
        // Extend: values with a leading 0 bit are negative.
        return raw < (1 << (category - 1)) ? raw - (1 << category) + 1 : raw
    }

    /// Skips to the next RSTn marker and clears the bit reader.
    mutating func restart() throws {
        bitBuffer = 0
        bitCount = 0
        hitMarker = false
        while position + 1 < bytes.count {
            if bytes[position] == 0xFF, (0xD0 ... 0xD7).contains(bytes[position + 1]) {
                position += 2
                return
            }
            position += 1
        }
    }
}
