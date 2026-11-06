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
    /// Albums this study is in.
    var albums: [Album] = []
    @Relationship(deleteRule: .cascade, inverse: \Series.study) var series: [Series] = []

    init(studyUID: String) {
        self.studyUID = studyUID
    }

    var displayName: String {
        let name = PersonName.display(patientName)
        return name.isEmpty ? String(localized: "Anonymous") : name
    }

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
    /// A copied study is offline while a picked Library is missing.
    var isOffline: Bool {
        if !Library.isAvailable, series.lazy.flatMap(\.images).contains(where: \.isCopied) { return true }
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

/// Groups of modalities shown in the sidebar, one row per group in use.
enum ModalityGroup: String, CaseIterable, Identifiable {
    case ct, mr, us, xray, mammography, nuclear, boneDensity, other

    var id: String { rawValue }

    var codes: Set<String> {
        switch self {
        case .ct: ["CT"]
        case .mr: ["MR"]
        case .us: ["US", "IVUS"]
        case .xray: ["CR", "DX", "RF", "XA", "RG", "DR", "PX", "IO"]
        case .mammography: ["MG"]
        case .nuclear: ["PT", "NM"]
        case .boneDensity: ["BMD", "BDUS"]
        case .other: []
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .ct: "CT"
        case .mr: "MR"
        case .us: "Ultrasound"
        case .xray: "X-Ray"
        case .mammography: "Mammography"
        case .nuclear: "Nuclear Medicine"
        case .boneDensity: "Bone Density"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .ct: "circle.circle"
        case .mr: "brain.head.profile"
        case .us: "dot.radiowaves.forward"
        case .xray: "lungs"
        case .mammography: "circle.lefthalf.striped.horizontal"
        case .nuclear: "atom"
        case .boneDensity: "figure.walk"
        case .other: "square.dashed"
        }
    }

    /// Groups a study belongs to, from its modality codes. Secondary
    /// captures and other non-image codes (OT, SR, KO, PR) alone fall in Other.
    static func groups(of study: Study) -> Set<ModalityGroup> {
        let codes = Set(study.modalities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        var groups = Set(allCases.filter { !$0.codes.isDisjoint(with: codes) })
        if groups.isEmpty { groups.insert(.other) }
        return groups
    }
}

/// A sidebar page: the library pages, a modality group, or an album.
enum SidebarItem: Hashable, Identifiable {
    case all, recent
    case modality(ModalityGroup)
    case album(UUID)

    var id: String {
        switch self {
        case .all: "all"
        case .recent: "recent"
        case .modality(let group): "modality-\(group.rawValue)"
        case .album(let uid): "album-\(uid.uuidString)"
        }
    }

    /// The fixed pages; modality and album pages depend on the data.
    static let library: [SidebarItem] = [.all, .recent]

    var title: LocalizedStringResource {
        switch self {
        case .all: "All Studies"
        case .recent: "Recently Imported"
        case .modality(let group): group.title
        case .album: "Album"
        }
    }

    var symbol: String {
        switch self {
        case .all: "rectangle.stack"
        case .recent: "clock"
        case .modality(let group): group.symbol
        case .album: "rectangle.stack.badge.person.crop"
        }
    }

    /// Recently Imported shows studies imported in the last seven days.
    /// Deleted studies show nowhere.
    func includes(_ study: Study, now: Date = .now) -> Bool {
        guard study.trashedAt == nil else { return false }
        return switch self {
        case .all: true
        case .recent: study.importedAt > now.addingTimeInterval(-7 * 86_400)
        case .modality(let group): ModalityGroup.groups(of: study).contains(group)
        case .album(let uid): study.albums.contains { $0.uid == uid }
        }
    }
}

/// A collection of studies the person makes, like a folder of teaching cases.
/// Studies can be in several albums; deleting an album keeps its studies.
@Model
final class Album {
    var uid: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \Study.albums) var studies: [Study] = []

    init(name: String) {
        self.name = name
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

    // MARK: Albums

    /// The New Album alert: its name and the studies it will hold.
    struct AlbumDraft {
        var isPresented = false
        var name = ""
        var studies: [Study] = []
    }

    var namingAlbum = AlbumDraft()

    func startNamingAlbum(with studies: [Study] = []) {
        namingAlbum = AlbumDraft(isPresented: true, name: String(localized: "Untitled Album"), studies: studies)
    }

    func finishNamingAlbum() {
        let album = newAlbum(named: namingAlbum.name, with: namingAlbum.studies)
        namingAlbum = AlbumDraft()
        sidebar = .album(album.uid)
    }

    @discardableResult
    func newAlbum(named name: String, with studies: [Study] = []) -> Album {
        let album = Album(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Untitled Album") : name)
        container.mainContext.insert(album)
        for study in studies where !album.studies.contains(where: { $0.uid == study.uid }) { album.studies.append(study) }
        try? container.mainContext.save()
        return album
    }

    func add(_ studies: [Study], to album: Album) {
        for study in studies where !album.studies.contains(where: { $0.uid == study.uid }) { album.studies.append(study) }
        try? container.mainContext.save()
    }

    func remove(_ studies: [Study], from album: Album) {
        let gone = Set(studies.map(\.uid))
        album.studies.removeAll { gone.contains($0.uid) }
        try? container.mainContext.save()
    }

    func deleteAlbum(_ album: Album) {
        if sidebar == .album(album.uid) { sidebar = .all }
        container.mainContext.delete(album)
        try? container.mainContext.save()
    }

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
        let libraryAvailable = Library.isAvailable
        for study in trashed {
            // Keep studies with copied files until their Library disk is back.
            if !libraryAvailable, study.series.contains(where: { $0.images.contains(where: \.isCopied) }) { continue }
            let folders = Set(study.series.flatMap(\.images).filter(\.isCopied).map { $0.fileURL.deletingLastPathComponent().deletingLastPathComponent() })
            for folder in folders where folder.path.hasPrefix(Library.root.path) {
                try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
            context.delete(study)
        }
        if !trashed.isEmpty { try? context.save() }
    }
}
