import Foundation
import SwiftData
import KidicomKit

/// One imaging exam of one patient on one date.
@Model
final class Study {
    /// Study Instance UID (0020,000D). Unique in the database.
    @Attribute(.unique) var studyUID: String
    /// A stable id for selection and links.
    var uid: UUID = UUID()
    /// Patient's Name (0010,0010) as stored in the file, like "SILVA^MARIA".
    var patientName: String = ""
    var patientID: String = ""
    var patientBirthDate: Date?
    var patientSex: String = ""
    var studyDate: Date?
    var studyDescription: String = ""
    var accessionNumber: String = ""
    /// Modalities in Study, like "CT" or "PT, CT".
    var modalities: String = ""
    var imageCount: Int = 0
    /// True when every image was copied into the Library; false when any
    /// image stays where it was imported from.
    var isCopied: Bool = true
    var importedAt: Date = Date.now
    /// Set when the person deletes the study; it hides at once and is
    /// removed for good at the next launch, so Undo can bring it back.
    var trashedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \Series.study) var series: [Series] = []

    init(studyUID: String) {
        self.studyUID = studyUID
    }

    var displayName: String { PersonName.display(patientName) }

    /// Sort key for Study Date; studies without a date sort as oldest.
    var sortDate: Date { studyDate ?? .distantPast }

    /// Sort key for the Files column.
    var filesOrder: Int { isCopied ? 0 : 1 }

    /// Search over patient name, patient ID, and description, ignoring
    /// case and accents.
    func matches(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [displayName, patientName, patientID, studyDescription, accessionNumber].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A Keep in Place study whose files moved or were removed.
    var isOffline: Bool {
        guard !isCopied else { return false }
        guard let image = series.lazy.flatMap(\.images).first(where: { !$0.isCopied }) else { return false }
        return !FileManager.default.fileExists(atPath: image.fileURL.path)
    }
}

/// One set of images inside a study.
@Model
final class Series {
    @Attribute(.unique) var seriesUID: String
    var number: Int = 0
    var seriesDescription: String = ""
    var modality: String = ""
    var frameOfReferenceUID: String = ""
    var study: Study?
    @Relationship(deleteRule: .cascade, inverse: \ImageFile.series) var images: [ImageFile] = []

    init(seriesUID: String) {
        self.seriesUID = seriesUID
    }
}

/// One DICOM file, with one or more frames.
@Model
final class ImageFile {
    @Attribute(.unique) var sopUID: String
    /// Inside the Library ("Files/...") when copied, else an absolute path.
    var path: String = ""
    var isCopied: Bool = true
    var instanceNumber: Int = 0
    var imagePosition: [Double] = []
    var imageOrientation: [Double] = []
    var frames: Int = 1
    var rows: Int = 0
    var columns: Int = 0
    var transferSyntaxUID: String = ""
    var series: Series?

    init(sopUID: String) {
        self.sopUID = sopUID
    }

    var fileURL: URL {
        isCopied ? Library.root.appending(path: path) : URL(fileURLWithPath: path)
    }
}

/// The sidebar pages. Snapshot mode walks through every case.
enum SidebarItem: String, CaseIterable, Identifiable {
    case all, recent

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All Studies"
        case .recent: "Recently Imported"
        }
    }

    var symbol: String {
        switch self {
        case .all: "rectangle.stack"
        case .recent: "clock"
        }
    }

    /// Recently Imported shows studies imported in the last seven days.
    /// Deleted studies show nowhere.
    func includes(_ study: Study, now: Date = .now) -> Bool {
        guard study.trashedAt == nil else { return false }
        return switch self {
        case .all: true
        case .recent: study.importedAt > now.addingTimeInterval(-7 * 86_400)
        }
    }
}

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let container: ModelContainer
    var sidebar: SidebarItem? = .all
    /// The selected study, by `Study.uid`.
    var selection: UUID?
    @ObservationIgnored lazy var importer = Importer(model: self)
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    init(container: ModelContainer) {
        self.container = container
    }

    /// Shows the open panel (File > Import…, toolbar +).
    var showsOpenPanel = false

    func importFiles() { showsOpenPanel = true }

    /// Set by the main window; opens or brings forward a viewer window.
    @ObservationIgnored var openViewer: (UUID) -> Void = { _ in }

    /// Opens a study in the viewer (double-click, Return, File > Open).
    func open(_ uid: UUID) { openViewer(uid) }

    /// Hides studies at once; Undo restores them. See `purgeTrash`.
    func trash(_ studies: [Study], undoManager: UndoManager?) {
        let now = Date.now
        for study in studies { study.trashedAt = now }
        if studies.contains(where: { $0.uid == selection }) { selection = nil }
        try? container.mainContext.save()
        undoManager?.registerUndo(withTarget: self) { model in
            for study in studies { study.trashedAt = nil }
            try? model.container.mainContext.save()
        }
        undoManager?.setActionName(studies.count == 1 ? String(localized: "Delete Study") : String(localized: "Delete Studies"))
    }

    /// Removes studies deleted in an earlier session: copied files go to the
    /// Trash; files kept in place are never touched.
    func purgeTrash() {
        let context = container.mainContext
        let trashed = (try? context.fetch(FetchDescriptor<Study>(predicate: #Predicate { $0.trashedAt != nil }))) ?? []
        for study in trashed {
            let folders = Set(study.series.flatMap(\.images).filter(\.isCopied).map { $0.fileURL.deletingLastPathComponent().deletingLastPathComponent() })
            for folder in folders where folder.path.hasPrefix(Library.root.path) {
                try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
            context.delete(study)
        }
        if !trashed.isEmpty { try? context.save() }
    }
}
