import AppKit
import SwiftData
import KidicomKit

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

            let before = studies().count
            let study = Study(studyUID: "1.2.3.selftest")
            study.patientName = "TESTE^PACIENTE"
            context.insert(study)
            try? context.save()
            check("a study is saved", studies().count == before + 1)
            check("the patient name reads well", study.displayName == "Teste, Paciente")
            check("a new import is recent", SidebarItem.recent.includes(study))
            study.importedAt = Date.now.addingTimeInterval(-30 * 86_400)
            check("an old import is not recent", !SidebarItem.recent.includes(study))
            context.delete(study)
            try? context.save()
            check("deleting the study removes it", studies().count == before)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
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
