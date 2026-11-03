import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        @Bindable var importer = model.importer
        NavigationSplitView {
            sidebar
        } content: {
            StudyList(page: model.sidebar ?? .all)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            StudyDetail()
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
        .task {
            await SeedData.insertIfRequested(into: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(SidebarItem.allCases, selection: $model.sidebar) { page in
            Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                .tag(page)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 212)
    }
}

struct StudyList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Study.importedAt, order: .reverse) private var studies: [Study]
    @State private var isTargeted = false
    let page: SidebarItem

    private var visible: [Study] { studies.filter { page.includes($0) } }

    var body: some View {
        @Bindable var model = model
        List(visible, id: \.uid, selection: $model.selection) { study in
            StudyRow(study: study)
                .tag(study.uid)
                .contextMenu {
                    Button("Delete", role: .destructive) { context.delete(study) }
                }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No Studies", systemImage: page.symbol)
                } description: {
                    Text("Drop DICOM files, folders, or zips here.")
                } actions: {
                    Button("Import…") { model.importFiles() }
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

struct StudyRow: View {
    let study: Study

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Text(study.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if study.isOffline {
                    Label("Offline", systemImage: "externaldrive.badge.xmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The files of this study were moved or removed.")
                }
            }
            Text(subtitle)
                .foregroundStyle(.secondary)
                .font(.callout)
                .lineLimit(2)
        }
        .help(study.studyDescription)
    }

    private var subtitle: String {
        let date = study.studyDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
        return [study.modalities, date, study.studyDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct StudyDetail: View {
    @Environment(AppModel.self) private var model
    @Query private var studies: [Study]

    var body: some View {
        if let study = studies.first(where: { $0.uid == model.selection }) {
            Form {
                LabeledContent("Patient", value: study.displayName)
                LabeledContent("Patient ID", value: study.patientID)
                LabeledContent("Study Date") {
                    Text(study.studyDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                LabeledContent("Description", value: study.studyDescription)
                LabeledContent("Modalities", value: study.modalities)
                LabeledContent("Images", value: study.imageCount.formatted())
                LabeledContent("Series", value: study.series.count.formatted())
                LabeledContent("Files") {
                    if study.isOffline {
                        Text("Offline")
                    } else {
                        Text(study.isCopied ? "Copied to Library" : "Kept in Place")
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
