import Foundation

/// The files found in what the person dropped or picked.
public struct ImportScan: Sendable {
    /// DICOM image files to import.
    public var files: [URL] = []
    /// Files that are not DICOM images (JPG, PDF, DICOMDIR, system files).
    public var skipped = 0
    /// Folders made by expanding zips. Delete them after the import.
    public var temporaryFolders: [URL] = []
    /// True when any file came from a zip; those must be copied.
    public var containsArchives: Bool { !temporaryFolders.isEmpty }

    public init() {}
}

/// Walks files, folders, and zips, and finds DICOM files by their content,
/// not their name: lab CDs use names like `I0001` with no extension.
public enum ImportScanner {
    public static func scan(_ urls: [URL], temporaryRoot: URL, isCancelled: @Sendable () -> Bool = { false }) throws -> ImportScan {
        var scan = ImportScan()
        // Zips found along the way, expanded after the plain files.
        var archives: [URL] = []
        for url in urls {
            if isCancelled() { break }
            if isSystemJunk(url.lastPathComponent) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                walk(url, isCancelled: isCancelled) { classify($0, into: &scan, archives: &archives) }
            } else {
                classify(url, into: &scan, archives: &archives)
            }
        }
        while let archive = archives.popLast() {
            if isCancelled() { break }
            let folder = temporaryRoot.appending(path: "zip-\(UUID().uuidString)", directoryHint: .isDirectory)
            // Listed before expanding, so a cancelled or failed zip is cleaned up too.
            scan.temporaryFolders.append(folder)
            do {
                try expand(archive, into: folder, isCancelled: isCancelled)
            } catch ImportError.cancelled {
                break
            } catch {
                for folder in scan.temporaryFolders { try? FileManager.default.removeItem(at: folder) }
                throw error
            }
            walk(folder, isCancelled: isCancelled) { classify($0, into: &scan, archives: &archives) }
        }
        scan.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return scan
    }

    private static func classify(_ url: URL, into scan: inout ImportScan, archives: inout [URL]) {
        if isSystemJunk(url.lastPathComponent) || url.pathComponents.contains("__MACOSX") { return }
        if url.pathExtension.lowercased() == "zip" {
            archives.append(url)
        } else if url.lastPathComponent.uppercased() != "DICOMDIR" && isDicom(url) {
            scan.files.append(url)
        } else {
            scan.skipped += 1
        }
    }

    /// Regular files under a folder, skipping hidden files and `__MACOSX`,
    /// handed over one at a time so a cancel stops the walk at once.
    static func walk(_ folder: URL, isCancelled: () -> Bool = { false }, _ visit: (URL) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        while let url = walker.nextObject() as? URL {
            if isCancelled() { return }
            if url.lastPathComponent == "__MACOSX" { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { visit(url) }
        }
    }

    static func isSystemJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name == "__MACOSX" || name == "Thumbs.db"
    }

    /// Reads the first bytes: "DICM" at 128, or a bare dataset that starts
    /// with a low group number and a valid VR or length.
    public static func isDicom(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 132), head.count >= 8 else { return false }
        let bytes = [UInt8](head)
        if bytes.count >= 132, bytes[128 ..< 132].elementsEqual([0x44, 0x49, 0x43, 0x4D]) { return true }
        let group = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard [0x0002, 0x0008].contains(group) else { return false }
        return DicomParser.isVR(bytes[4], bytes[5]) || bytes[7] == 0
    }

    /// Expands a zip with ditto. A cancel stops ditto and throws `cancelled`.
    static func expand(_ archive: URL, into folder: URL, isCancelled: () -> Bool = { false }) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        // ditto handles UTF-8 names and the zips made by Finder and Windows.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Wait in short steps so a cancel reaches ditto within a moment.
        repeat {
            if isCancelled() {
                process.terminate()
                exited.wait()
                throw ImportError.cancelled
            }
        } while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut
        guard process.terminationStatus == 0 else {
            throw ImportError.archiveFailed(archive.lastPathComponent)
        }
    }
}

public enum ImportError: Error, Equatable, Sendable {
    case archiveFailed(String)
    case cancelled
}

/// Where a copied image goes inside the Library: Files/<study>/<series>/<image>.dcm
public enum LibraryPath {
    public static func relativePath(for record: InstanceRecord) -> String {
        "Files/\(safe(record.studyUID))/\(safe(record.seriesUID))/\(safe(record.sopUID)).dcm"
    }

    static func safe(_ uid: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_")
        let cleaned = String(uid.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(120))
    }
}
