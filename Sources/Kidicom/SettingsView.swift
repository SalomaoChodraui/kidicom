import AppKit
import KidicomKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic. Each tab is a
/// grouped Form that sizes to its content.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) } }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .tools: ToolSettings()
            case .windows: WindowSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, tools, windows, appearance

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .tools: "Tools"
        case .windows: "Windows"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tools: "computermouse"
        case .windows: "circle.lefthalf.filled"
        case .appearance: "paintpalette"
        }
    }
}

/// How imports store files, deleting, and where the Library is.
struct GeneralSettings: View {
    @AppStorage("confirmDelete") private var confirmDelete = true
    @State private var importChoice: String = ImportMode.remembered?.rawValue ?? "ask"

    var body: some View {
        Section("Import") {
            Picker("When importing", selection: $importChoice) {
                Text("Ask Each Time").tag("ask")
                Text("Copy to Library").tag(ImportMode.copy.rawValue)
                Text("Keep in Place").tag(ImportMode.keepInPlace.rawValue)
            }
            .onChange(of: importChoice) { _, value in ImportMode.remembered = ImportMode(rawValue: value) }
            Text("Files from zips are always copied.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section("Studies") {
            Toggle("Ask before deleting a study", isOn: $confirmDelete)
            LibraryLocationRow()
        }
    }
}

/// Where copied files live, with Change… to move them (to an external
/// disk, say) and Use Default to bring them back to Application Support.
struct LibraryLocationRow: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var moving: (done: Int, total: Int)?
    @State private var error: String?
    /// Bumped after a move so the path and buttons refresh.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let root = Library.root
        LabeledContent("Library") {
            HStack(spacing: Space.sm) {
                Text(root.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(root.path(percentEncoded: false))
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
                .disabled(!Library.isAvailable)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { move(to: folder) }
        }
        .fileDialogMessage("Choose where to keep the Library. A folder named “Kidicom Library” is created inside it.")
        .fileDialogConfirmationLabel("Move Library Here")
        .alert("Unable to Move the Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        if let moving {
            LabeledContent {
                ProgressView(value: Double(moving.done), total: Double(max(moving.total, 1)))
                    .frame(width: 160)
            } label: {
                Text("Moving \(moving.done) of \(moving.total) Files…")
            }
        } else {
            LabeledContent {
                HStack(spacing: Space.sm) {
                    if Library.customRoot != nil {
                        Button("Use Default") { move(to: nil) }
                    }
                    Button("Change…") { choosing = true }
                }
                .disabled(model.importer.isBusy)
            } label: {
                if Library.isAvailable {
                    Text("Copied files can live on another disk. The database stays on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The Library disk is not connected. Copied studies are offline.", systemImage: "externaldrive.badge.xmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func move(to folder: URL?) {
        if let folder, Library.isInICloud(folder) {
            error = Library.MoveError.iCloud.errorDescription
            return
        }
        let destination = Library.destination(for: folder)
        moving = (0, 0)
        Task {
            do {
                try await Library.move(to: destination) { done, total in
                    Task { @MainActor in moving = (done, total) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            moving = nil
            revision += 1
            Availability.shared.refresh()
        }
    }
}

/// The keys that pick the left-button tool in the viewer.
struct ToolSettings: View {
    private let keys = ToolKeys.shared

    var body: some View {
        Section {
            ForEach(MeasureTool.allCases) { tool in
                ToolKeyRow(tool: tool)
            }
        } header: {
            Text("Left-Button Tools")
        } footer: {
            HStack {
                Text("Press the key in a viewport to pick the tool. Right button zooms, wheel button pans, wheel scrolls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { keys.reset() }
            }
        }
    }
}

struct ToolKeyRow: View {
    let tool: MeasureTool
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: Space.xs) {
                TextField("Key", text: $text, prompt: Text("Key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 48)
                    .accessibilityLabel(Text("Key for \(String(localized: tool.title))"))
                    .onChange(of: text) { _, value in apply(value) }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        } label: {
            Label { Text(tool.title) } icon: { tool.icon() }
        }
        .onAppear { text = ToolKeys.shared.key(for: tool).uppercased() }
        .onChange(of: ToolKeys.shared.key(for: tool)) { _, key in text = key.uppercased() }
    }

    private func apply(_ value: String) {
        let key = String(value.suffix(1)).lowercased()
        guard !key.isEmpty else { return }
        if key.uppercased() != value { text = key.uppercased() }
        problem = ToolKeys.shared.problem(with: key, for: tool)
        if problem == nil { ToolKeys.shared.set(key, for: tool) }
    }
}

/// Window presets for keys 1 to 4, in Hounsfield units.
struct WindowSettings: View {
    private let presets = WindowPresets.shared

    var body: some View {
        Section {
            ForEach([WindowPreset.softTissue, .lung, .bone, .brain], id: \.self) { preset in
                PresetRow(preset: preset)
            }
        } header: {
            Text("Window Presets")
        } footer: {
            HStack {
                Text("Keys 1 to 4 apply these to grayscale images; 0 returns to the window in the file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { presets.reset() }
            }
        }
    }
}

struct PresetRow: View {
    let preset: WindowPreset

    var body: some View {
        let presets = WindowPresets.shared
        let window = presets.window(for: preset) ?? VOIWindow(center: 0, width: 1)
        LabeledContent {
            HStack(spacing: Space.sm) {
                Text("WL").foregroundStyle(.secondary)
                TextField("WL", value: Binding(get: { window.center }, set: { presets.set(VOIWindow(center: $0, width: window.width), for: preset) }), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("WW").foregroundStyle(.secondary)
                TextField("WW", value: Binding(get: { window.width }, set: { presets.set(VOIWindow(center: window.center, width: max(1, $0)), for: preset) }), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            .monospacedDigit()
        } label: {
            Text("\(preset.rawValue)  \(String(localized: WindowPresets.title(preset)))")
        }
    }
}

/// The person's window presets, saved in UserDefaults.
@Observable
final class WindowPresets {
    static let shared = WindowPresets()
    private var custom: [WindowPreset: VOIWindow] = [:]

    init() {
        for preset in WindowPreset.allCases {
            let d = UserDefaults.standard
            if d.object(forKey: "preset.\(preset.rawValue).width") != nil {
                custom[preset] = VOIWindow(center: d.double(forKey: "preset.\(preset.rawValue).center"),
                                           width: d.double(forKey: "preset.\(preset.rawValue).width"))
            }
        }
    }

    static func title(_ preset: WindowPreset) -> LocalizedStringResource {
        switch preset {
        case .fileDefault: "File Window"
        case .softTissue: "Soft Tissue"
        case .lung: "Lung"
        case .bone: "Bone"
        case .brain: "Brain"
        }
    }

    func window(for preset: WindowPreset) -> VOIWindow? { custom[preset] ?? preset.window }

    func set(_ window: VOIWindow, for preset: WindowPreset) {
        custom[preset] = window
        guard !Store.isOverridden else { return }
        UserDefaults.standard.set(window.center, forKey: "preset.\(preset.rawValue).center")
        UserDefaults.standard.set(window.width, forKey: "preset.\(preset.rawValue).width")
    }

    func reset() {
        custom = [:]
        for preset in WindowPreset.allCases {
            UserDefaults.standard.removeObject(forKey: "preset.\(preset.rawValue).center")
            UserDefaults.standard.removeObject(forKey: "preset.\(preset.rawValue).width")
        }
    }
}
