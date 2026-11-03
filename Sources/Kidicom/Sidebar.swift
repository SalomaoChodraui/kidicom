import SwiftData
import SwiftUI

/// The worklist sidebar: library pages, one page per modality group in
/// use, and the person's albums.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Query private var studies: [Study]
    @Query(sort: \Album.name) private var albums: [Album]
    @State private var renaming: Album?
    @State private var newName = ""

    private var live: [Study] { studies.filter { $0.trashedAt == nil } }

    /// Modality groups that have studies, in a fixed order, with counts.
    private var groups: [(ModalityGroup, Int)] {
        var counts: [ModalityGroup: Int] = [:]
        for study in live {
            for group in ModalityGroup.groups(of: study) { counts[group, default: 0] += 1 }
        }
        return ModalityGroup.allCases.compactMap { group in counts[group].map { (group, $0) } }
    }

    /// Library pages with something in them; All Studies always shows.
    private var libraryPages: [SidebarItem] {
        SidebarItem.library.filter { page in page == .all || live.contains { page.includes($0) } }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            librarySection
            modalitySection
            albumSection
        }
        // A page that empties (last CT deleted) falls back to All Studies.
        .onChange(of: groups.map(\.0)) { _, inUse in
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

    private var librarySection: some View {
        Section("Library") {
            ForEach(libraryPages) { page in
                Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                    .badge(live.filter { page.includes($0) }.count)
                    .tag(page)
            }
        }
    }

    @ViewBuilder
    private var modalitySection: some View {
        let inUse = groups
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
    @Query private var studies: [Study]
    let album: Album
    @State private var isTargeted = false

    var body: some View {
        Label { Text(album.name) } icon: { Image(systemName: "rectangle.stack.badge.person.crop") }
            .badge(album.studies.filter { $0.trashedAt == nil }.count)
            .padding(.vertical, 1)
            .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Space.xs))
            .dropDestination(for: String.self) { ids, _ in
                let uids = Set(ids.compactMap(UUID.init(uuidString:)))
                let dropped = studies.filter { uids.contains($0.uid) }
                guard !dropped.isEmpty else { return false }
                model.add(dropped, to: album)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
