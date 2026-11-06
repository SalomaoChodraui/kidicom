import Foundation

/// The Library: Kidicom's own folder for copied files, next to the database.
///   ~/Library/Application Support/Kidicom/Library/Files/<study>/<series>/<image>.dcm
/// With APP_STORE set (tests, snapshots), it sits next to that store instead.
nonisolated enum Library {
    static var root: URL {
        if Store.isOverridden {
            return Store.url.deletingPathExtension().appendingPathExtension("library")
        }
        return URL.applicationSupportDirectory.appending(path: "Kidicom/Library", directoryHint: .isDirectory)
    }

    /// Scratch space for expanded zips, emptied after each import.
    static var temporary: URL {
        FileManager.default.temporaryDirectory.appending(path: "Kidicom-import", directoryHint: .isDirectory)
    }
}
