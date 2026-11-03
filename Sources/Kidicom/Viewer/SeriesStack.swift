import CoreGraphics
import Foundation
import KidicomKit

/// One frame on screen: an image file and a frame inside it.
struct SliceRef: Sendable {
    var url: URL
    var frame: Int
    var instanceNumber: Int
    /// Position along the slice normal, in mm, when the series has geometry.
    var location: Double?
    /// Image Orientation (Patient): row and column direction cosines.
    var orientation: [Double] = []
}

/// A decoded frame with what the viewport needs to draw it.
struct DecodedSlice: Sendable {
    var frame: Frame
    var width: Int
    var height: Int
    var inverted: Bool
    var defaultWindow: Window
    var pixelSpacing: [Double]
    var sliceThickness: Double?
    /// Milliseconds between frames (Frame Time), or nil.
    var frameTime: Double?
    /// Frames per second from Cine Rate, or nil.
    var cineRate: Double?
    var isColor: Bool {
        if case .color = frame { return true }
        return false
    }
}

/// The frames of one series, in scroll order, with a cache of decoded frames.
@Observable
final class SeriesStack: Identifiable {
    let id: String
    let number: Int
    let title: String
    let modality: String
    let slices: [SliceRef]
    /// Rendered middle frame for the series strip.
    var thumbnail: CGImage?

    @ObservationIgnored private var cache: [Int: DecodedSlice] = [:]
    @ObservationIgnored private var order: [Int] = []
    @ObservationIgnored private var loading: [Int: Task<DecodedSlice?, Never>] = [:]
    /// About 384 MB of decoded frames per series.
    @ObservationIgnored private var limit = 96

    init(series: Series) {
        id = series.seriesUID
        number = series.number
        modality = series.modality
        title = series.seriesDescription.isEmpty ? String(localized: "Series \(series.number)") : series.seriesDescription
        let images = series.images
        let order = SliceOrder.order(images.map {
            SliceOrder.Item(instanceNumber: $0.instanceNumber, position: $0.imagePosition, orientation: $0.imageOrientation)
        })
        var slices: [SliceRef] = []
        for index in order {
            let image = images[index]
            let location = SliceOrder.location(position: image.imagePosition, orientation: image.imageOrientation)
            for frame in 0 ..< max(1, image.frames) {
                slices.append(SliceRef(url: image.fileURL, frame: frame, instanceNumber: image.instanceNumber, location: location, orientation: image.imageOrientation))
            }
        }
        self.slices = slices
    }

    var count: Int { slices.count }
    /// True for a single image with several frames, like an ultrasound cine.
    var isCine: Bool { slices.count > 1 && Set(slices.map(\.url)).count == 1 }

    func cached(_ index: Int) -> DecodedSlice? { cache[index] }

    func load(_ index: Int) async -> DecodedSlice? {
        guard slices.indices.contains(index) else { return nil }
        if let hit = cache[index] { return hit }
        if let running = loading[index] { return await running.value }
        let ref = slices[index]
        let task = Task { await Self.decode(ref) }
        loading[index] = task
        let result = await task.value
        loading[index] = nil
        if let result { store(result, at: index) }
        return result
    }

    /// Decodes the next and previous frames while the person looks at one.
    func prefetch(around index: Int, radius: Int = 6) {
        for offset in 1 ... radius {
            for candidate in [index + offset, index - offset] where slices.indices.contains(candidate) && cache[candidate] == nil && loading[candidate] == nil {
                Task { _ = await load(candidate) }
            }
        }
    }

    func makeThumbnail() async {
        guard thumbnail == nil, !slices.isEmpty, let slice = await load(slices.count / 2) else { return }
        thumbnail = Renderer.image(slice.frame, width: slice.width, height: slice.height, window: slice.defaultWindow, inverted: slice.inverted)
    }

    private func store(_ slice: DecodedSlice, at index: Int) {
        if cache[index] == nil { order.append(index) }
        cache[index] = slice
        limit = max(16, 384_000_000 / max(1, slice.width * slice.height * (slice.isColor ? 4 : 4)))
        while order.count > limit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
    }

    @concurrent
    nonisolated static func decode(_ ref: SliceRef) async -> DecodedSlice? {
        guard let file = try? DicomParser.parse(contentsOf: ref.url),
              let descriptor = try? file.pixelDescriptor,
              let frame = try? file.frame(ref.frame) else { return nil }
        let d = file.dataset
        let window: Window
        if case .grayscale(let values) = frame {
            if let center = d.number(.windowCenter), let width = d.number(.windowWidth), width > 1 {
                window = Window(center: center, width: width)
            } else {
                let range = Renderer.range(values)
                window = Window(center: Double(range.low + range.high) / 2, width: Double(range.high - range.low) + 1)
            }
        } else {
            window = Window(center: 128, width: 256)
        }
        var spacing = d.numbers(.pixelSpacing)
        if spacing.count < 2 { spacing = d.numbers(.imagerPixelSpacing) }
        return DecodedSlice(
            frame: frame, width: descriptor.columns, height: descriptor.rows,
            inverted: descriptor.isInverted, defaultWindow: window, pixelSpacing: spacing,
            sliceThickness: d.number(.sliceThickness), frameTime: d.number(.frameTime), cineRate: d.number(.cineRate)
        )
    }
}
