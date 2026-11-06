import SwiftData
import SwiftUI

/// The worklist sidebar: library pages, one page per modality group in
/// use, and the person's albums.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Deleted studies are left out by the database.
    @Query(filter: #Predicate<Study> { $0.trashedAt == nil }) private var live: [Study]
    @Query(sort: \Album.name) private var albums: [Album]
    @State private var renaming: Album?
    @State private var newName = ""

    /// Every count the sidebar shows, from one pass over the studies.
    private struct Counts {
        /// Library pages with something in them, with counts; All Studies always shows.
        var pages: [(SidebarItem, Int)] = []
        /// Modality groups that have studies, in a fixed order, with counts.
        var groups: [(ModalityGroup, Int)] = []
    }

    private var counts: Counts {
        let now = Date.now
        var recent = 0
        var byGroup: [ModalityGroup: Int] = [:]
        for study in live {
            if SidebarItem.recent.includes(study, now: now) { recent += 1 }
            for group in ModalityGroup.groups(of: study) { byGroup[group, default: 0] += 1 }
        }
        var counts = Counts()
        counts.pages = SidebarItem.library.compactMap { page in
            switch page {
            case .all: (page, live.count)
            case .recent: recent > 0 ? (page, recent) : nil
            default: nil
            }
        }
        counts.groups = ModalityGroup.allCases.compactMap { group in byGroup[group].map { (group, $0) } }
        return counts
    }

    var body: some View {
        @Bindable var model = model
        let counts = counts
        List(selection: $model.sidebar) {
            librarySection(counts.pages)
            modalitySection(counts.groups)
            albumSection
        }
        // A page that empties (last CT deleted) falls back to All Studies.
        .onChange(of: counts.groups.map(\.0)) { _, inUse in
            if case .modality(let group) = model.sidebar, !inUse.contains(group) { model.sidebar = .all }
        }
        .alert("Rename Album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let album = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { album.name = newName }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func librarySection(_ pages: [(SidebarItem, Int)]) -> some View {
        Section("Library") {
            ForEach(pages, id: \.0) { page, count in
                Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                    .badge(count)
                    .tag(page)
            }
        }
    }

    @ViewBuilder
    private func modalitySection(_ inUse: [(ModalityGroup, Int)]) -> some View {
        if !inUse.isEmpty {
            Section("Modalities") {
                ForEach(inUse, id: \.0) { group, count in
                    Label { Text(group.title) } icon: { Image(systemName: group.symbol) }
                        .badge(count)
                        .tag(SidebarItem.modality(group))
                }
            }
        }
    }

    private var albumSection: some View {
        Section {
            ForEach(albums) { album in
                AlbumRow(album: album)
                    .tag(SidebarItem.album(album.uid))
                    .contextMenu {
                        Button("Rename…") { newName = album.name; renaming = album }
                        Button("Delete Album", role: .destructive) { model.deleteAlbum(album) }
                    }
            }
        } header: {
            HStack {
                Text("Albums")
                Spacer()
                Button("New Album", systemImage: "plus") { model.startNamingAlbum() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Make an album to group studies, like teaching cases")
                    // Line up with the count badges of the rows, not the sidebar edge.
                    .padding(.trailing, Space.md)
            }
        }
    }
}

/// An album in the sidebar; studies dropped on it join it.
struct AlbumRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let album: Album
    @State private var isTargeted = false

    var body: some View {
        Label { Text(album.name) } icon: { Image(systemName: "rectangle.stack.badge.person.crop") }
            .badge(album.studies.count { $0.trashedAt == nil })
            .padding(.vertical, 1)
            .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Space.xs))
            .dropDestination(for: String.self) { ids, _ in
                // Only the dropped studies are fetched, when they drop.
                let uids = ids.compactMap(UUID.init(uuidString:))
                let dropped = (try? context.fetch(FetchDescriptor<Study>(predicate: #Predicate { uids.contains($0.uid) }))) ?? []
                guard !dropped.isEmpty else { return false }
                model.add(dropped, to: album)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
