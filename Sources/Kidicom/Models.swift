import Foundation
import SwiftData
import KidicomKit

/// One imaging study (an exam) in the worklist. Series and instances come
/// with the DICOM parser (stories S-001 to S-003).
@Model
final class Study {
    /// Study Instance UID (0020,000D). Unique in the database.
    @Attribute(.unique) var studyUID: String
    /// Patient's Name (0010,0010) as stored in the file, like "SILVA^MARIA".
    var patientName: String = ""
    var patientID: String = ""
    var studyDate: Date?
    var studyDescription: String = ""
    /// Modalities in Study, like "CT" or "MR, PT".
    var modalities: String = ""
    var imageCount: Int = 0
    /// True when the files were copied into the Kidicom library, false when
    /// they stay where they were imported from.
    var isCopied: Bool = true
    var importedAt: Date = Date.now

    init(studyUID: String) {
        self.studyUID = studyUID
    }

    var displayName: String { PersonName.display(patientName) }
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
    func includes(_ study: Study, now: Date = .now) -> Bool {
        switch self {
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
    var selection: PersistentIdentifier?
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    init(container: ModelContainer) {
        self.container = container
    }

    /// Imports files and folders. Filled in by story S-003.
    func importFiles() {}
}
