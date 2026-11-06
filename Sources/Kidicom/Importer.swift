import Foundation
import KidicomKit
import SwiftData

/// How an import stores files.
enum ImportMode: String, CaseIterable {
    case copy, keepInPlace

    /// The remembered choice ("Always do this"), or nil to ask.
    static var remembered: ImportMode? {
        get { UserDefaults.standard.string(forKey: "import.mode").flatMap(ImportMode.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "import.mode") }
    }
}

struct ImportSummary: Equatable {
    var studies = 0
    var images = 0
    var skipped = 0
    var duplicates = 0
    var failed = 0
}

/// Runs imports: scan, ask (Import sheet), then read headers, copy files,
/// and add studies in batches, off the main thread except for the database.
@Observable
final class Importer {
    enum Phase: Equatable {
        case idle
        case scanning
        /// Waiting for the Import sheet.
        case confirm
        case importing(done: Int, total: Int)
        case finished(ImportSummary)
        case nothingFound(skipped: Int)
        case failed(String)
    }

    var phase: Phase = .idle
    /// The scan waiting for the Import sheet.
    private(set) var pending: ImportScan?
    /// Images in the pending scan that are already in the worklist.
    private(set) var alreadyImported = 0

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var pendingCount: Int { pending?.files.count ?? 0 }
    var pendingFromZip: Bool { pending?.containsArchives ?? false }
    var pendingSkipped: Int { pending?.skipped ?? 0 }

    var isBusy: Bool {
        switch phase {
        case .scanning, .importing, .confirm: true
        default: false
        }
    }

    @ObservationIgnored private var queued: [URL] = []
    @ObservationIgnored private var gathering: Task<Void, Never>?

    /// Files opened from the Finder or the Dock arrive in bursts of open
    /// requests; gather them for half a second into one import.
    func gather(_ urls: [URL]) {
        queued.append(contentsOf: urls)
        gathering?.cancel()
        gathering = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            startQueued()
        }
    }

    /// Runs what waited while another import was busy.
    private func startQueued() {
        guard !isBusy, !queued.isEmpty else { return }
        let urls = queued
        queued = []
        begin(urls)
    }

    /// Starts from a drop, the open panel, or the Dock. While another import
    /// runs, the new one waits its turn.
    func begin(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy else { queued.append(contentsOf: urls); return }
        phase = .scanning
        task = Task {
            let temporary = Library.temporary
            let scan: ImportScan
            do {
                scan = try await Self.scan(urls, temporary: temporary)
            } catch {
                phase = .failed(String(localized: "Unable to open \(urlsName(urls)). The zip may be damaged."))
                return
            }
            if Task.isCancelled { Self.cleanUp(scan); phase = .idle; return }
            guard !scan.files.isEmpty else {
                Self.cleanUp(scan)
                phase = .nothingFound(skipped: scan.skipped)
                startQueued()
                return
            }
            pending = scan
            alreadyImported = countAlreadyImported(scan)
            if let mode = ImportMode.remembered {
                confirm(mode: scan.containsArchives ? .copy : mode, remember: false)
            } else {
                phase = .confirm
            }
        }
    }

    /// Snapshot mode: shows the Import sheet for a made-up scan.
    func previewSheet(files: Int, skipped: Int, fromZip: Bool) {
        var scan = ImportScan()
        scan.files = (0 ..< files).map { URL(fileURLWithPath: "/tmp/preview/\($0)") }
        scan.skipped = skipped
        if fromZip { scan.temporaryFolders = [URL(fileURLWithPath: "/tmp/preview")] }
        pending = scan
        alreadyImported = 0
        phase = .confirm
    }

    /// The Import sheet's Import button.
    func confirm(mode: ImportMode, remember: Bool) {
        guard let scan = pending else { return }
        if remember { ImportMode.remembered = mode }
        pending = nil
        let copy = mode == .copy || scan.containsArchives
        task = Task { await run(scan, copy: copy) }
    }

    /// Cancel in the sheet or in the progress footer. Images already added stay.
    func cancel() {
        task?.cancel()
        if let scan = pending { Self.cleanUp(scan) }
        pending = nil
        phase = .idle
        queued = []
    }

    func dismissMessage() {
        if !isBusy { phase = .idle }
    }

    /// Imports a scan and returns what happened. The self-test calls this directly.
    @discardableResult
    func run(_ scan: ImportScan, copy: Bool) async -> ImportSummary {
        var summary = ImportSummary(skipped: scan.skipped)
        if copy, !Library.isAvailable || Library.isMoving {
            Self.cleanUp(scan)
            phase = .failed(Library.isMoving
                ? String(localized: "The Library is being moved. Import again when it finishes.")
                : String(localized: "The Library is not available. Connect its disk and try again."))
            return summary
        }
        // A purge of studies deleted earlier may still be moving folders to the Trash.
        await model.purging?.value
        let context = model.container.mainContext
        // Only the images, studies, and series of each batch are looked up, so
        // an import costs the same in an empty Library and in a full one.
        var added = Set<String>()
        var studies: [String: Study] = [:]
        var seriesByUID: [String: Series] = [:]
        var touched = Set<String>()
        var newStudies = Set<String>()

        let total = scan.files.count
        phase = .importing(done: 0, total: total)
        let library = Library.root
        let batchSize = 200
        var index = 0
        while index < total {
            if Task.isCancelled { break }
            let batch = Array(scan.files[index ..< min(index + batchSize, total)])
            let headers = await Self.readHeaders(batch)
            if Task.isCancelled { break }

            // Duplicates: already in the database, or earlier in this import.
            let existing = Self.existingImages(headers.compactMap { $0?.sopUID }, in: context)
            var fresh: [InstanceRecord] = []
            for header in headers {
                guard let record = header else { summary.failed += 1; continue }
                if existing.contains(record.sopUID) || !added.insert(record.sopUID).inserted {
                    summary.duplicates += 1
                } else {
                    fresh.append(record)
                }
            }
            loadStudies(of: fresh, into: &studies, series: &seriesByUID, in: context)

            // Images copied before a cancel are still added.
            let stored = await Self.store(fresh, copyTo: copy ? library : nil)
            for (record, result) in zip(fresh, stored) {
                let storedPath: String
                switch result {
                case .notStarted: continue
                case .failed: summary.failed += 1; continue
                case .stored(let path): storedPath = path
                }
                let study = studies[record.studyUID] ?? {
                    let study = Study(studyUID: record.studyUID)
                    context.insert(study)
                    studies[record.studyUID] = study
                    newStudies.insert(record.studyUID)
                    return study
                }()
                study.trashedAt = nil   // importing again brings a deleted study back
                fill(study, from: record)
                let series = seriesByUID[record.seriesUID] ?? {
                    let series = Series(seriesUID: record.seriesUID)
                    series.number = record.seriesNumber
                    series.seriesDescription = record.seriesDescription
                    series.modality = record.modality
                    series.frameOfReferenceUID = record.frameOfReferenceUID
                    context.insert(series)
                    series.study = study
                    seriesByUID[record.seriesUID] = series
                    Self.addModality(record.modality, to: study)
                    return series
                }()
                let image = ImageFile(sopUID: record.sopUID)
                image.path = storedPath
                image.isCopied = copy
                image.instanceNumber = record.instanceNumber
                image.imagePosition = record.imagePosition
                image.imageOrientation = record.imageOrientation
                image.frames = record.frames
                image.rows = record.rows
                image.columns = record.columns
                image.transferSyntaxUID = record.transferSyntaxUID
                context.insert(image)
                image.series = series
                study.imageCount += 1
                if !copy { study.isCopied = false }
                touched.insert(record.studyUID)
                summary.images += 1
            }
            index += batch.count
            try? context.save()
            // After Cancel the footer is already gone; keep it gone.
            if !Task.isCancelled { phase = .importing(done: index, total: total) }
        }
        summary.studies = newStudies.count
        Self.cleanUp(scan)
        model.availability.forget(touched.compactMap { studies[$0]?.uid })
        // Show what came in: the first new study, in Recently Imported.
        if let first = touched.compactMap({ studies[$0] }).sorted(by: { $0.displayName < $1.displayName }).first {
            model.sidebar = .recent
            model.selection = first.uid
        }
        phase = Task.isCancelled ? .idle : .finished(summary)
        if !queued.isEmpty { Task { startQueued() } }
        return summary
    }

    private func fill(_ study: Study, from record: InstanceRecord) {
        if study.patientName.isEmpty { study.patientName = record.patientName }
        if study.patientID.isEmpty { study.patientID = record.patientID }
        if study.patientBirthDate == nil { study.patientBirthDate = record.patientBirthDate }
        if study.patientSex.isEmpty { study.patientSex = record.patientSex }
        if study.studyDate == nil { study.studyDate = record.studyDate }
        if study.studyDescription.isEmpty { study.studyDescription = record.studyDescription }
        if study.accessionNumber.isEmpty { study.accessionNumber = record.accessionNumber }
        study.importedAt = .now
    }

    /// Modalities in Study keep the order they first appear in, without repeats.
    private static func addModality(_ modality: String, to study: Study) {
        guard !modality.isEmpty else { return }
        var list = study.modalities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.contains(modality) else { return }
        list.append(modality)
        study.modalities = list.joined(separator: ", ")
    }

    /// Fetches the studies and series of a batch that this import has not loaded yet.
    private func loadStudies(of records: [InstanceRecord], into studies: inout [String: Study], series: inout [String: Series], in context: ModelContext) {
        let studyUIDs = Array(Set(records.map(\.studyUID)).filter { studies[$0] == nil })
        if !studyUIDs.isEmpty {
            let found = (try? context.fetch(FetchDescriptor<Study>(predicate: #Predicate { studyUIDs.contains($0.studyUID) }))) ?? []
            for study in found { studies[study.studyUID] = study }
        }
        let seriesUIDs = Array(Set(records.map(\.seriesUID)).filter { series[$0] == nil })
        if !seriesUIDs.isEmpty {
            let found = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { seriesUIDs.contains($0.seriesUID) }))) ?? []
            for item in found { series[item.seriesUID] = item }
        }
    }

    /// The SOP Instance UIDs from `uids` that are already in the database.
    private static func existingImages(_ uids: [String], in context: ModelContext) -> Set<String> {
        guard !uids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<ImageFile>(predicate: #Predicate { uids.contains($0.sopUID) })
        descriptor.propertiesToFetch = [\.sopUID]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.sopUID))
    }

    private func countAlreadyImported(_ scan: ImportScan) -> Int {
        // Cheap check by file path for Keep in Place imports of the same folder,
        // asked of the database in chunks instead of loading every image.
        let context = model.container.mainContext
        let paths = scan.files.map(\.path)
        var found = Set<String>()
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start ..< min(start + 500, paths.count)])
            var descriptor = FetchDescriptor<ImageFile>(predicate: #Predicate { !$0.isCopied && chunk.contains($0.path) })
            descriptor.propertiesToFetch = [\.path]
            for image in (try? context.fetch(descriptor)) ?? [] { found.insert(image.path) }
        }
        return paths.filter { found.contains($0) }.count
    }

    private func urlsName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) items")
    }

    // MARK: Off the main thread

    enum StoreResult: Sendable {
        case stored(String)
        case failed
        /// Cancelled before this file was copied.
        case notStarted
    }

    @concurrent
    nonisolated static func scan(_ urls: [URL], temporary: URL) async throws -> ImportScan {
        try ImportScanner.scan(urls, temporaryRoot: temporary, isCancelled: { Task.isCancelled })
    }

    /// Runs `work` on each item, a few at a time, in order. After a cancel no
    /// new item starts; those get `skipped`.
    @concurrent
    nonisolated private static func each<T: Sendable, R: Sendable>(_ items: [T], skipped: R, _ work: @escaping @Sendable (T) -> R) async -> [R] {
        let parallelism = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R](repeating: skipped, count: items.count)
            var next = 0
            func addNext() {
                guard next < items.count, !Task.isCancelled else { return }
                let index = next, item = items[index]
                next += 1
                group.addTask { Task.isCancelled ? (index, skipped) : (index, work(item)) }
            }
            for _ in 0 ..< parallelism { addNext() }
            for await (index, result) in group {
                results[index] = result
                addNext()
            }
            return results
        }
    }

    /// Reads headers in parallel; nil for files that are not readable images.
    @concurrent
    nonisolated static func readHeaders(_ files: [URL]) async -> [InstanceRecord?] {
        await each(files, skipped: nil) { try? InstanceRecord(contentsOf: $0) }
    }

    /// Copies files into the Library, or keeps their paths for Keep in Place.
    @concurrent
    nonisolated static func store(_ records: [InstanceRecord], copyTo library: URL?) async -> [StoreResult] {
        guard let library else { return records.map { .stored($0.url.path) } }
        return await each(records, skipped: .notStarted) { record in
            let relative = LibraryPath.relativePath(for: record)
            let destination = library.appending(path: relative)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: record.url, to: destination)
                }
                return .stored(relative)
            } catch {
                return .failed
            }
        }
    }

    nonisolated static func cleanUp(_ scan: ImportScan) {
        for folder in scan.temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    }
}
