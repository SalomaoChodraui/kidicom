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
        let context = model.container.mainContext
        var known = Set(((try? context.fetch(FetchDescriptor<ImageFile>())) ?? []).map(\.sopUID))
        var studies: [String: Study] = [:]
        var seriesByUID: [String: Series] = [:]
        for study in (try? context.fetch(FetchDescriptor<Study>())) ?? [] { studies[study.studyUID] = study }
        for series in (try? context.fetch(FetchDescriptor<Series>())) ?? [] { seriesByUID[series.seriesUID] = series }
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
            let results = await Self.read(batch, copyTo: copy ? library : nil, skipping: known)
            for result in results {
                switch result {
                case .failed: summary.failed += 1
                case .duplicate: summary.duplicates += 1
                case .read(let record, let storedPath):
                    guard !known.contains(record.sopUID) else { summary.duplicates += 1; continue }
                    known.insert(record.sopUID)
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
                    if !copy { study.isCopied = false }
                    touched.insert(record.studyUID)
                    summary.images += 1
                }
            }
            index += batch.count
            for uid in touched { if let study = studies[uid] { updateTotals(study) } }
            try? context.save()
            phase = .importing(done: index, total: total)
        }
        summary.studies = newStudies.count
        Self.cleanUp(scan)
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

    private func updateTotals(_ study: Study) {
        let modalities = study.series.map(\.modality).filter { !$0.isEmpty }
        // Keep the order they first appear in, without repeats.
        var seen = Set<String>()
        study.modalities = modalities.filter { seen.insert($0).inserted }.joined(separator: ", ")
        study.imageCount = study.series.reduce(0) { $0 + $1.images.count }
    }

    private func countAlreadyImported(_ scan: ImportScan) -> Int {
        // Cheap check by file path for Keep in Place imports of the same folder.
        let paths = Set(((try? model.container.mainContext.fetch(FetchDescriptor<ImageFile>())) ?? []).filter { !$0.isCopied }.map(\.path))
        return scan.files.filter { paths.contains($0.path) }.count
    }

    private func urlsName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) items")
    }

    // MARK: Off the main thread

    enum ReadResult: Sendable {
        case read(InstanceRecord, storedPath: String)
        case duplicate
        case failed
    }

    @concurrent
    nonisolated static func scan(_ urls: [URL], temporary: URL) async throws -> ImportScan {
        try ImportScanner.scan(urls, temporaryRoot: temporary, isCancelled: { Task.isCancelled })
    }

    /// Reads headers in parallel and copies files into the Library.
    @concurrent
    nonisolated static func read(_ files: [URL], copyTo library: URL?, skipping known: Set<String>) async -> [ReadResult] {
        await withTaskGroup(of: (Int, ReadResult).self) { group in
            for (index, url) in files.enumerated() {
                group.addTask {
                    guard let record = try? InstanceRecord(contentsOf: url) else { return (index, .failed) }
                    if known.contains(record.sopUID) { return (index, .duplicate) }
                    guard let library else { return (index, .read(record, storedPath: url.path)) }
                    let relative = LibraryPath.relativePath(for: record)
                    let destination = library.appending(path: relative)
                    do {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.copyItem(at: url, to: destination)
                        }
                        return (index, .read(record, storedPath: relative))
                    } catch {
                        return (index, .failed)
                    }
                }
            }
            var results = [ReadResult](repeating: .failed, count: files.count)
            for await (index, result) in group { results[index] = result }
            return results
        }
    }

    nonisolated static func cleanUp(_ scan: ImportScan) {
        for folder in scan.temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    }
}
