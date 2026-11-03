import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        @Bindable var importer = model.importer
        NavigationSplitView {
            sidebar
        } detail: {
            StudyTable(page: model.sidebar ?? .all)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ImportStatusBar() }
        .fileImporter(
            isPresented: $model.showsOpenPanel,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importer.begin(urls) }
        }
        .fileDialogMessage("Choose DICOM files, folders, or zips to import.")
        .fileDialogConfirmationLabel("Import")
        .sheet(isPresented: Binding(
            get: { importer.phase == .confirm },
            set: { if !$0 && importer.phase == .confirm { importer.cancel() } }
        )) {
            ImportSheet()
                .environment(model)
        }
        .onAppear {
            if !Store.isOverridden || ProcessInfo.processInfo.environment["APP_SEED"] == nil { model.purgeTrash() }
            model.openViewer = { openWindow(id: "viewer", value: $0) }
            AppDelegate.openFiles = { [model] urls in model.importer.gather(urls) }
            if !AppDelegate.pending.isEmpty {
                model.importer.gather(AppDelegate.pending)
                AppDelegate.pending = []
            }
        }
        .task {
            await SeedData.insertIfRequested(into: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings, openWindow: openWindow)
        }
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(SidebarItem.allCases, selection: $model.sidebar) { page in
            Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                .tag(page)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

struct StudyTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var studies: [Study]
    @Environment(\.undoManager) private var undoManager
    @AppStorage("confirmDelete") private var confirmDelete = true
    @State private var pendingDelete: [Study] = []
    @State private var isTargeted = false
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Study.sortDate, order: .reverse)]
    let page: SidebarItem

    private var visible: [Study] {
        studies
            .filter { page.includes($0) && $0.matches(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = visible
        // The table selects by the model id; the app keeps the stable uid.
        let selection = Binding<PersistentIdentifier?>(
            get: { rows.first { $0.uid == model.selection }?.persistentModelID },
            set: { id in model.selection = rows.first { $0.persistentModelID == id }?.uid }
        )
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Patient", value: \.displayName) { study in
                Text(study.displayName).help(study.displayName)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Patient ID", value: \.patientID)
                .width(min: 70, ideal: 90)
            TableColumn("Study Date", value: \.sortDate) { study in
                Text(study.studyDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 96)
            TableColumn("Modality", value: \.modalities)
                .width(min: 56, ideal: 72)
            TableColumn("Description", value: \.studyDescription) { study in
                Text(study.studyDescription).help(study.studyDescription)
            }
            .width(min: 140, ideal: 260)
            TableColumn("Images", value: \.imageCount) { study in
                Text(study.imageCount.formatted())
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 52, ideal: 64)
            TableColumn("Files", value: \.filesOrder) { study in
                FilesLabel(study: study)
            }
            .width(min: 64, ideal: 80)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { selection in
            Button("Delete…", role: .destructive) {
                askToDelete(studies.filter { selection.contains($0.persistentModelID) })
            }
        } primaryAction: { selection in
            if let study = studies.first(where: { selection.contains($0.persistentModelID) }) { model.open(study.uid) }
        }
        .onDeleteCommand {
            askToDelete(studies.filter { $0.uid == model.selection })
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                model.trash(pendingDelete, undoManager: undoManager)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Copied files go to the Trash. Files kept in place are not touched. You can undo with ⌘Z.")
        }
        .searchable(text: $search, placement: .toolbar, prompt: Text("Search patient, ID, or description"))
        .overlay {
            if rows.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label("No Studies", systemImage: page.symbol)
                    } description: {
                        Text("Drop DICOM files, folders, or zips here.")
                    } actions: {
                        Button("Import…") { model.importFiles() }
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(.tint, lineWidth: Space.xs)
                    .padding(Space.xs)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importer.begin(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle(Text(page.title))
        .toolbar {
            ToolbarItem {
                Button("Import…", systemImage: "plus") { model.importFiles() }
                    .help("Import DICOM files, folders, or zips (⌘O)")
                    .disabled(model.importer.isBusy)
            }
        }
    }
}

/// Where a study's files are: Library, In Place, or Offline.
extension StudyTable {
    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(localized: "Delete the study of \(pendingDelete[0].displayName)?")
            : String(localized: "Delete \(pendingDelete.count) studies?")
    }

    private func askToDelete(_ chosen: [Study]) {
        guard !chosen.isEmpty else { return }
        if confirmDelete { pendingDelete = chosen } else { model.trash(chosen, undoManager: undoManager) }
    }
}

struct FilesLabel: View {
    let study: Study

    var body: some View {
        if study.isOffline {
            Label("Offline", systemImage: "externaldrive.badge.xmark")
                .foregroundStyle(.secondary)
                .help("The files of this study were moved or removed.")
        } else if study.isCopied {
            Text("Library").foregroundStyle(.secondary)
        } else {
            Text("In Place").foregroundStyle(.secondary)
                .help("The files stay where they were imported from.")
        }
    }
}
