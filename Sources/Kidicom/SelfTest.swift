import AppKit
import SwiftData
import KidicomKit
import Foundation

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Kidicom-self.store ~/Applications/Kidicom.app/Contents/MacOS/Kidicom --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let context = model.container.mainContext
            func studies() -> [Study] { (try? context.fetch(FetchDescriptor<Study>())) ?? [] }
            func images() -> [ImageFile] { (try? context.fetch(FetchDescriptor<ImageFile>())) ?? [] }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Kidicom-selftest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }

            // S-003: import a folder with images, a JPG, and macOS junk.
            let urls = (try? SampleStudies.write(to: folder.appending(path: "cd"))) ?? []
            try? Data("jpg".utf8).write(to: folder.appending(path: "cd/foto.jpg"))
            try? Data("x".utf8).write(to: folder.appending(path: "cd/._foto.jpg"))
            check("sample files were written", urls.count == 50)
            let scan = try? ImportScanner.scan([folder.appending(path: "cd")], temporaryRoot: Library.temporary)
            check("the scan finds the images and skips the JPG", scan?.files.count == 50 && scan?.skipped == 1)
            let started = Date.now
            let summary = await model.importer.run(scan ?? ImportScan(), copy: true)
            check("importing 50 images takes under 3 seconds", Date.now.timeIntervalSince(started) < 3, "\(Date.now.timeIntervalSince(started)) s")
            check("4 studies and 50 images were imported", summary.studies == 4 && summary.images == 50, "\(summary)")
            check("studies are grouped by patient and date", studies().count == 4)
            let ct = studies().first { $0.studyDescription.contains("TORAX") && $0.imageCount == 24 }
            check("the CT has 24 images in one series", ct?.series.count == 1 && ct?.series.first?.images.count == 24)
            check("the patient name reads well", ct?.displayName == "Silva, Maria C")
            check("copied files are in the Library", images().allSatisfy { $0.isCopied && FileManager.default.fileExists(atPath: $0.fileURL.path) })
            check("a new import is in Recently Imported", ct.map { SidebarItem.recent.includes($0) } ?? false)

            // Importing the same files again adds nothing.
            let again = await model.importer.run(scan ?? ImportScan(), copy: true)
            check("importing twice does not duplicate images", again.images == 0 && again.duplicates == 50 && images().count == 50)

            // S-004: Keep in Place, then the folder goes away: the study is offline.
            let placeFolder = folder.appending(path: "place")
            let us = urls.first { $0.lastPathComponent == "US-1" }
            try? FileManager.default.createDirectory(at: placeFolder, withIntermediateDirectories: true)
            var record = us.flatMap { try? InstanceRecord(contentsOf: $0) }
            record?.url = placeFolder.appending(path: "US-copy")
            if let us { try? FileManager.default.copyItem(at: us, to: placeFolder.appending(path: "US-copy")) }
            // Give the copy new UIDs by rewriting it as a new sample under a new study.
            let rewritten = rewriteAsNewStudy(placeFolder.appending(path: "US-copy"))
            let placeScan = try? ImportScanner.scan([placeFolder], temporaryRoot: Library.temporary)
            let kept = await model.importer.run(placeScan ?? ImportScan(), copy: false)
            check("Keep in Place imports without copying", rewritten && kept.images == 1)
            let keptStudy = studies().first { !$0.isCopied }
            check("a Keep in Place study is online while its files exist", keptStudy?.isOffline == false)
            try? FileManager.default.removeItem(at: placeFolder)
            check("a Keep in Place study goes offline when its folder is removed", keptStudy?.isOffline == true)

            // Zip imports are always copied.
            let zip = folder.appending(path: "exame.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", folder.appending(path: "cd").path, zip.path]
            try? ditto.run(); ditto.waitUntilExit()
            let zipScan = try? ImportScanner.scan([zip], temporaryRoot: Library.temporary)
            check("a zip is recognized as an archive", zipScan?.containsArchives == true && zipScan?.files.count == 50)

            // Deleting a study removes its series and images.
            if let ct { context.delete(ct); try? context.save() }
            check("deleting a study removes its images", images().count == 27)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// Gives a copied file a new Study, Series, and SOP Instance UID.
    private static func rewriteAsNewStudy(_ url: URL) -> Bool {
        guard var data = try? Data(contentsOf: url) else { return false }
        let old = Data("1.2.826.0.1.3680043.10.1.3".utf8)
        let new = Data("1.2.826.0.1.3680043.10.1.8".utf8)
        var replaced = false
        while let range = data.range(of: old) { data.replaceSubrange(range, with: new); replaced = true }
        return replaced && (try? data.write(to: url)) != nil
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
