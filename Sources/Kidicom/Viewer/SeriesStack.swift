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
    /// Image Position (Patient) of the first pixel.
    var position: [Double] = []
}

/// A decoded frame with what the viewport needs to draw it.
struct DecodedSlice: Sendable {
    var frame: Frame
    var width: Int
    var height: Int
    var inverted: Bool
    var defaultWindow: VOIWindow
    var pixelSpacing: [Double]
    var sliceThickness: Double?
    /// Milliseconds between frames (Frame Time), or nil.
    var frameTime: Double?
    /// Frames per second from Cine Rate, or nil.
    var cineRate: Double?
    /// Calibrated ultrasound areas, for measurements without Pixel Spacing.
    var regions: [UltrasoundRegion] = []
    var isColor: Bool {
        if case .color = frame { return true }
        return false
    }
}

/// The frames of one series, in scroll order. Decoded frames live in the
/// shared `FrameCache`; decoding goes through one queue for the whole app.
@Observable
final class SeriesStack: Identifiable {
    let id: String
    let number: Int
    let title: String
    let modality: String
    let slices: [SliceRef]
    let frameOfReferenceUID: String
    /// The study this series belongs to, for the overlay and comparisons.
    let studyUID: UUID?
    let studyDate: Date?
    let studyDescription: String
    /// True for a single image with several frames, like an ultrasound cine.
    let isCine: Bool
    /// Finds the slice nearest a position, for scroll sync.
    let locations: LocationIndex
    /// The middle frame, scaled down for the series strip.
    var thumbnail: CGImage?

    /// This series' frames in the shared cache.
    @ObservationIgnored let cacheID = UUID()
    @ObservationIgnored private var jobs: [Int: DecodeJob] = [:]
    /// Bytes of the last decoded frame, to size prefetch to the cache.
    @ObservationIgnored private var frameBytes = 0
    @ObservationIgnored private var makingThumbnail = false

    /// Every decode in the app goes through here: about one per core, the
    /// frame on screen first, then prefetch, then thumbnails.
    nonisolated static let gate = WorkGate(limit: ProcessInfo.processInfo.activeProcessorCount)

    enum Priority {
        static let display = 1000
        static let prefetch = 500
        static let thumbnail = 0
        /// Prefetch leaves one core for the frame the person asks for.
        static var prefetchCeiling: Int { max(1, SeriesStack.gate.limit - 1) }
        static let thumbnailCeiling = 2
    }

    init(series: Series) {
        id = series.seriesUID
        number = series.number
        modality = series.modality
        frameOfReferenceUID = series.frameOfReferenceUID
        studyUID = series.study?.uid
        studyDate = series.study?.studyDate
        studyDescription = series.study?.studyDescription ?? ""
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
                slices.append(SliceRef(url: image.fileURL, frame: frame, instanceNumber: image.instanceNumber, location: location, orientation: image.imageOrientation, position: image.imagePosition))
            }
        }
        self.slices = slices
        isCine = slices.count > 1 && slices.allSatisfy { $0.url == slices[0].url }
        locations = LocationIndex(slices.map(\.location))
    }

    isolated deinit {
        for job in jobs.values { job.task?.cancel() }
        FrameCache.shared.removeAll(of: cacheID)
    }

    var count: Int { slices.count }

    func cached(_ index: Int) -> DecodedSlice? { FrameCache.shared.frame(cacheID, index) }

    /// The frame to show now: first in the decode queue. A frame already
    /// queued for prefetch moves up instead of decoding twice.
    func load(_ index: Int) async -> DecodedSlice? {
        guard slices.indices.contains(index) else { return nil }
        if let hit = cached(index) { return hit }
        let job = jobs[index] ?? startJob(index, priority: Priority.display, ceiling: nil, prefetch: false)
        if job.isPrefetch {
            job.isPrefetch = false
            let ticket = job.ticket
            Task { await Self.gate.promote(ticket, to: Priority.display, ceiling: Self.gate.limit) }
        }
        guard let task = job.task else { return nil }
        job.waiters += 1
        defer { job.waiters -= 1 }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.abandon(job, at: index) }
        }
    }

    /// Decodes the frames the person is likely to see next, most of them in
    /// the direction of the scroll, and drops queued ones the scroll left behind.
    func prefetch(around index: Int, direction: Int) {
        guard slices.indices.contains(index) else { return }
        for (i, job) in jobs where job.isPrefetch && PrefetchPlan.isStale(i, around: index, count: count, wraps: isCine) {
            job.task?.cancel()
            jobs[i] = nil
        }
        // Half the shared budget at most, so other series keep their frames.
        let room = frameBytes > 0 ? FrameCache.shared.budget / 2 / frameBytes : .max
        let plan = PrefetchPlan.indices(around: index, direction: direction.signum(), count: count, wraps: isCine, budget: room)
        // Frames near this one count as used, the nearest as the most recent.
        for i in plan.reversed() { _ = FrameCache.shared.frame(cacheID, i) }
        for (rank, i) in plan.enumerated() where jobs[i] == nil && !FrameCache.shared.contains(cacheID, i) {
            startJob(i, priority: Priority.prefetch - rank, ceiling: Priority.prefetchCeiling, prefetch: true)
        }
    }

    func prefetch(around index: Int) { prefetch(around: index, direction: 0) }

    /// Frames decoding or waiting in the queue.
    var pendingCount: Int { jobs.count }

    /// Draws the middle frame at the size of a strip cell, when the cell first
    /// shows. The full frame is not kept for it. Cancelled with the cell.
    func makeThumbnail(maxPixels: CGSize) async {
        guard thumbnail == nil, !makingThumbnail, !slices.isEmpty else { return }
        makingThumbnail = true
        defer { makingThumbnail = false }
        let index = slices.count / 2
        let slice: DecodedSlice?
        if let hit = cached(index) {
            slice = hit
        } else if let task = jobs[index]?.task {
            slice = await task.value
        } else {
            let ref = slices[index]
            slice = await Self.gate.run(priority: Priority.thumbnail, ceiling: Priority.thumbnailCeiling) { await Self.decode(ref) } ?? nil
        }
        guard let slice, !Task.isCancelled else { return }
        thumbnail = await Self.thumbnail(of: slice, maxPixels: maxPixels)
    }

    /// Frees this series' decoded frames, when no viewport shows it.
    func releaseFrames() {
        for (i, job) in jobs where job.isPrefetch {
            job.task?.cancel()
            jobs[i] = nil
        }
        FrameCache.shared.removeAll(of: cacheID)
    }

    @discardableResult
    private func startJob(_ index: Int, priority: Int, ceiling: Int?, prefetch: Bool) -> DecodeJob {
        let job = DecodeJob(isPrefetch: prefetch)
        let ref = slices[index], ticket = job.ticket
        job.task = Task { [weak self] in
            let result = await Self.gate.run(id: ticket, priority: priority, ceiling: ceiling) { await Self.decode(ref) } ?? nil
            self?.finish(job, at: index, result: result)
            return result
        }
        jobs[index] = job
        return job
    }

    private func finish(_ job: DecodeJob, at index: Int, result: DecodedSlice?) {
        if jobs[index] === job { jobs[index] = nil }
        guard let result else { return }
        frameBytes = result.byteCount
        FrameCache.shared.store(result, owner: cacheID, index: index)
    }

    /// The viewport that asked for a frame went elsewhere: if no one else
    /// waits for it, it does not run.
    private func abandon(_ job: DecodeJob, at index: Int) {
        job.abandoned += 1
        guard job.abandoned >= job.waiters, !job.isPrefetch else { return }
        job.task?.cancel()
        if jobs[index] === job { jobs[index] = nil }
    }

    /// Scales a frame down to fit `maxPixels`, off the main thread.
    @concurrent
    nonisolated static func thumbnail(of slice: DecodedSlice, maxPixels: CGSize) async -> CGImage? {
        guard let full = Renderer.image(slice.frame, width: slice.width, height: slice.height,
                                        window: slice.defaultWindow, inverted: slice.inverted) else { return nil }
        let scale = min(1, maxPixels.width / CGFloat(full.width), maxPixels.height / CGFloat(full.height))
        guard scale < 1 else { return full }
        let width = max(1, Int((CGFloat(full.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(full.height) * scale).rounded()))
        let gray = full.colorSpace?.model == .monochrome
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return full }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? full
    }

    @concurrent
    nonisolated static func decode(_ ref: SliceRef) async -> DecodedSlice? {
        // A cine reads and indexes its file once, not once per frame.
        guard let reader = try? FrameReaderCache.shared.reader(for: ref.url), !Task.isCancelled,
              let frame = try? reader.frame(ref.frame) else { return nil }
        let descriptor = reader.descriptor
        let d = reader.file.dataset
        let window: VOIWindow
        if case .grayscale(let values) = frame {
            if let center = d.number(.windowCenter), let width = d.number(.windowWidth), width > 1 {
                window = VOIWindow(center: center, width: width)
            } else {
                let range = Renderer.range(values)
                window = VOIWindow(center: Double(range.low + range.high) / 2, width: Double(range.high - range.low) + 1)
            }
        } else {
            window = VOIWindow(center: 128, width: 256)
        }
        var spacing = d.numbers(.pixelSpacing)
        if spacing.count < 2 { spacing = d.numbers(.imagerPixelSpacing) }
        return DecodedSlice(
            frame: frame, width: descriptor.columns, height: descriptor.rows,
            inverted: descriptor.isInverted, defaultWindow: window, pixelSpacing: spacing,
            sliceThickness: d.number(.sliceThickness), frameTime: d.number(.frameTime), cineRate: d.number(.cineRate),
            regions: UltrasoundRegion.regions(in: d)
        )
    }
}

/// One frame decoding or waiting in the queue, shared by every viewport
/// that asks for it.
final class DecodeJob {
    let ticket = UUID()
    var task: Task<DecodedSlice?, Never>?
    /// Prefetch nobody waits for yet: dropped when the scroll leaves it.
    var isPrefetch: Bool
    var waiters = 0
    var abandoned = 0

    init(isPrefetch: Bool) {
        self.isPrefetch = isPrefetch
    }
}
