import AppKit
import SwiftData
import SwiftUI

// Kidicom
//   Kidicom                      the app
//   APP_STORE=<file> Kidicom     use another database (tests, experiments)
//   APP_SNAPSHOT=<dir> Kidicom   save a PNG of every sidebar page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 Kidicom           fill an empty /tmp store with sample items (tools/snap.sh)
//   Kidicom --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Kidicom      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Kidicom           draw the 8 pt grid and the layout probes over the window

@main
struct KidicomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    var body: some Scene {
        Window("Kidicom", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 760, minHeight: 480)
        }
        .modelContainer(model.container)
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Import…") { model.importFiles() }
                    .disabled(model.importer.isBusy)
                    .keyboardShortcut("o")
            }
        }

        WindowGroup("Viewer", id: "viewer", for: UUID.self) { $uid in
            if let uid {
                ViewerView(studyUID: uid)
                    .environment(model)
                    .themed()
                    // Reading happens in the dark, like a radiology workstation.
                    .preferredColorScheme(.dark)
            }
        }
        .modelContainer(model.container)
        .defaultSize(width: 1200, height: 860)
        // A restored viewer would point at a study from another session.
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once its model exists; files opened before that wait here.
    static var openFiles: ([URL]) -> Void = { pending.append(contentsOf: $0) }
    static var pending: [URL] = []

    /// Files, folders, and zips dropped on the Dock icon or opened with
    /// Kidicom arrive as an Open Documents Apple event. Kidicom handles it
    /// itself: SwiftUI's handler activates a window per file, which makes
    /// the window flicker and resize for thousands of files.
    func applicationWillFinishLaunching(_ notification: Notification) {
        installOpenHandler()
    }

    private func installOpenHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        if list.numberOfItems == 0 {
            if let url = list.coerce(toDescriptorType: typeFileURL)?.fileURLValue { urls.append(url) }
        } else {
            for index in 1 ... list.numberOfItems {
                if let url = list.atIndex(index)?.coerce(toDescriptorType: typeFileURL)?.fileURLValue { urls.append(url) }
            }
        }
        Self.openFiles(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Again after SwiftUI set up its own handlers.
        installOpenHandler()
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where the data lives: ~/Library/Application Support/Kidicom/Kidicom.store
nonisolated enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "Kidicom", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Kidicom.store")
    }

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Study.self, Series.self, ImageFile.self, Album.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }
}
