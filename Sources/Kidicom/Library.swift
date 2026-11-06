import Foundation
import Synchronization

/// The Library: Kidicom's own folder for copied files.
///   <root>/Files/<study>/<series>/<image>.dcm
/// The root is ~/Library/Application Support/Kidicom/Library unless the
/// person picked another folder in Settings (an external disk, say); the
/// database always stays in Application Support.
/// With APP_STORE set (tests, snapshots), it sits next to that store instead.
nonisolated enum Library {
    /// UserDefaults key for a root the person picked.
    static let customKey = "library.path"
    /// The folder created inside the one the person picks.
    static let folderName = "Kidicom Library"

    static var defaultRoot: URL {
        if Store.isOverridden {
            return Store.url.deletingPathExtension().appendingPathExtension("library")
        }
        return URL.applicationSupportDirectory.appending(path: "Kidicom/Library", directoryHint: .isDirectory)
    }

    /// The picked root's path. Test stores keep it in memory so they never
    /// touch the real setting.
    private static let testPath = Mutex<String?>(nil)
    private static var customPath: String? {
        get {
            if Store.isOverridden { return testPath.withLock { $0 } }
            return UserDefaults.standard.string(forKey: customKey)
        }
        set {
            if Store.isOverridden { testPath.withLock { $0 = newValue }; return }
            UserDefaults.standard.set(newValue, forKey: customKey)
        }
    }

    /// A root picked in Settings, or nil for the default.
    static var customRoot: URL? {
        guard let path = customPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var root: URL { customRoot ?? defaultRoot }

    /// False while a picked root is missing, like an external disk that is
    /// not connected. Copied studies show as offline then.
    static var isAvailable: Bool {
        guard let custom = customRoot else { return true }
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: custom.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// True while `move(to:)` runs; imports that copy wait for it.
    static var isMoving: Bool { moving.withLock { $0 } }
    private static let moving = Mutex(false)

    /// Scratch space for expanded zips, emptied after each import.
    static var temporary: URL {
        FileManager.default.temporaryDirectory.appending(path: "Kidicom-import", directoryHint: .isDirectory)
    }

    /// iCloud Drive syncs and evicts files on its own, which breaks a
    /// library of copied files, so folders in it are refused.
    static func isInICloud(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") { return true }
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    enum MoveError: LocalizedError {
        case iCloud
        case insideLibrary
        case unavailable
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .iCloud: String(localized: "Choose a folder outside iCloud Drive.")
            case .insideLibrary: String(localized: "Choose a folder outside the current Library.")
            case .unavailable: String(localized: "The current Library is not available. Connect its disk and try again.")
            case .copyFailed(let name): String(localized: "Unable to copy \(name). The Library was not moved.")
            }
        }
    }

    /// The root a move to `folder` would use: the default when `folder` is
    /// nil, else a "Kidicom Library" folder inside it (or `folder` itself
    /// when the person picked an existing Kidicom Library).
    static func destination(for folder: URL?) -> URL {
        guard let folder else { return defaultRoot }
        if folder.lastPathComponent == folderName { return folder }
        return folder.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Paths of the regular files under `folder`, relative to it.
    static func relativeFiles(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path
        var files: [String] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return files
    }

    /// Copies every file in the current Library to `newRoot`, keeping files
    /// already there, then saves the new root and moves the old files to the
    /// Trash. Nothing changes when a copy fails. `progress` gets
    /// (done, total) from a background thread.
    @concurrent
    static func move(to newRoot: URL, progress: @Sendable @escaping (Int, Int) -> Void) async throws {
        let fileManager = FileManager.default
        let oldRoot = root
        let newPath = newRoot.standardizedFileURL.path
        let oldPath = oldRoot.standardizedFileURL.path
        if newPath == oldPath { return }
        if newPath.hasPrefix(oldPath + "/") { throw MoveError.insideLibrary }
        if isInICloud(newRoot.deletingLastPathComponent()) || isInICloud(newRoot) { throw MoveError.iCloud }
        guard isAvailable else { throw MoveError.unavailable }
        moving.withLock { $0 = true }
        defer { moving.withLock { $0 = false } }

        let oldFiles = oldRoot.appending(path: "Files", directoryHint: .isDirectory)
        let newFiles = newRoot.appending(path: "Files", directoryHint: .isDirectory)
        let files = relativeFiles(in: oldFiles)
        try fileManager.createDirectory(at: newFiles, withIntermediateDirectories: true)
        progress(0, files.count)
        for (index, relative) in files.enumerated() {
            let source = oldFiles.appending(path: relative)
            let target = newFiles.appending(path: relative)
            if !fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: source, to: target)
                } catch {
                    throw MoveError.copyFailed(source.lastPathComponent)
                }
            }
            if index % 50 == 0 || index == files.count - 1 { progress(index + 1, files.count) }
        }

        customPath = newPath == defaultRoot.standardizedFileURL.path ? nil : newPath
        if fileManager.fileExists(atPath: oldFiles.path) {
            try? fileManager.trashItem(at: oldFiles, resultingItemURL: nil)
        }
        if oldPath != defaultRoot.standardizedFileURL.path,
           (try? fileManager.contentsOfDirectory(atPath: oldPath))?.isEmpty == true {
            try? fileManager.removeItem(at: oldRoot)
        }
    }
}
