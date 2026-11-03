import KidicomKit
import SwiftUI

/// The DICOM attributes of the image in the active viewport.
struct TagInspector: View {
    let viewport: Viewport?
    @State private var rows: [TagRow] = []
    @State private var search = ""

    private var url: URL? {
        guard let viewport, let stack = viewport.stack, stack.slices.indices.contains(viewport.index) else { return nil }
        return stack.slices[viewport.index].url
    }

    private var visible: [TagRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            [row.tag.description, row.name, row.value].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search tags", text: $search, prompt: Text("Search tag, name, or value"))
                .textFieldStyle(.roundedBorder)
                .padding(Space.sm)
            Divider()
            table
        }
    }

    private var table: some View {
        Table(visible) {
            TableColumn("Tag") { row in
                Text(row.tag.description).monospaced().foregroundStyle(.secondary)
            }
            .width(min: 88, ideal: 92)
            TableColumn("Name") { row in
                Text(row.name)
                    .padding(.leading, CGFloat(row.depth) * Space.md)
                    .help(row.name)
            }
            .width(min: 120, ideal: 160)
            TableColumn("VR") { row in
                Text(row.vr).monospaced().foregroundStyle(.secondary)
            }
            .width(min: 28, ideal: 32)
            TableColumn("Value") { row in
                Text(row.value).textSelection(.enabled).help(row.value)
            }
            .width(min: 120, ideal: 280)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No Image", systemImage: "doc.text.magnifyingglass")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .task(id: url) {
            guard let url else { rows = []; return }
            rows = await Self.load(url)
        }
    }

    @concurrent
    nonisolated static func load(_ url: URL) async -> [TagRow] {
        guard let file = try? DicomParser.parse(contentsOf: url, headerOnly: true) else { return [] }
        return DicomDump.rows(file)
    }
}
