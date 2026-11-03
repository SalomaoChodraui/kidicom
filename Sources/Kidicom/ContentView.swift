import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            StudyList(page: model.sidebar ?? .all)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            StudyDetail()
        }
        .task {
            SeedData.insertIfRequested(into: model)
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
    let page: SidebarItem

    private var visible: [Study] { studies.filter { page.includes($0) } }

    var body: some View {
        @Bindable var model = model
        List(visible, selection: $model.selection) { study in
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(study.displayName)
                Text("\(study.modalities) · \(study.studyDescription)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .tag(study.id)
            .contextMenu {
                Button("Delete", role: .destructive) { context.delete(study) }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView(
                    "No Studies",
                    systemImage: page.symbol,
                    description: Text("Press Command-O or drop DICOM files here.")
                )
            }
        }
        .navigationTitle(Text(page.title))
        .toolbar {
            ToolbarItem {
                Button("Import", systemImage: "plus") { model.importFiles() }
                    .help("Import DICOM files, folders, or zips (Command-O)")
            }
        }
    }
}

struct StudyDetail: View {
    @Environment(AppModel.self) private var model
    @Query private var studies: [Study]

    var body: some View {
        if let study = studies.first(where: { $0.id == model.selection }) {
            Form {
                LabeledContent("Patient", value: study.displayName)
                LabeledContent("Patient ID", value: study.patientID)
                LabeledContent("Study Date") {
                    Text(study.studyDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                LabeledContent("Description", value: study.studyDescription)
                LabeledContent("Modalities", value: study.modalities)
                LabeledContent("Images", value: study.imageCount.formatted())
                LabeledContent("Files") {
                    Text(study.isCopied ? "Copied to library" : "Kept in place")
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
