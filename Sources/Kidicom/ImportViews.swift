import SwiftUI

/// The Import sheet: Copy to Library or Keep in Place.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var mode: ImportMode = .copy
    @State private var remember = false

    private var scanCount: Int { model.importer.pendingCount }
    private var fromZip: Bool { model.importer.pendingFromZip }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Import \(scanCount) Images")
                .font(.headline)
            Picker("Files", selection: $mode) {
                choice("Copy to Library", detail: "Files stay available if the original folder is moved or removed.")
                    .tag(ImportMode.copy)
                choice("Keep in Place", detail: "Uses no extra disk space. The study goes offline if the files move.")
                    .tag(ImportMode.keepInPlace)
                    .selectionDisabled(fromZip)
                    .opacity(fromZip ? 0.5 : 1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            VStack(alignment: .leading, spacing: Space.xs) {
                if fromZip {
                    Label("Files from zips are always copied.", systemImage: "doc.zipper")
                }
                if model.importer.alreadyImported > 0 {
                    Label("Already in the worklist and skipped: ^[\(model.importer.alreadyImported) image](inflect: true).", systemImage: "checkmark.circle")
                }
                if model.importer.pendingSkipped > 0 {
                    Label("Not DICOM images, skipped: ^[\(model.importer.pendingSkipped) file](inflect: true).", systemImage: "doc")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Toggle("Always do this", isOn: $remember)
                .disabled(fromZip)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.importer.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.importer.confirm(mode: fromZip ? .copy : mode, remember: remember) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.xl)
        .frame(width: 440)
        .fitsContent()
        .noInitialFocus()
        .onAppear {
            if fromZip { mode = .copy } else if let remembered = ImportMode.remembered { mode = remembered }
        }
    }

    private func choice(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Space.xs)
    }
}

/// The footer under the worklist: scan and import progress, then the result.
struct ImportStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let phase = model.importer.phase
        if phase != .idle && phase != .confirm {
            HStack(spacing: Space.md) {
                content(phase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .task(id: phase) {
                // Results stay for five seconds, then the bar goes away.
                guard case .finished = phase else { return }
                try? await Task.sleep(for: .seconds(5))
                model.importer.dismissMessage()
            }
        }
    }

    @ViewBuilder
    private func content(_ phase: Importer.Phase) -> some View {
        switch phase {
        case .scanning:
            ProgressView().controlSize(.small)
            Text("Looking for DICOM files…")
            cancelButton
        case .importing(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 160)
                .accessibilityLabel("Importing")
                .accessibilityValue(Text("\(done) of \(total) images"))
            Text("Importing \(done) of \(total) images")
                .monospacedDigit()
            cancelButton
        case .finished(let summary):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text(summaryText(summary))
        case .nothingFound(let skipped):
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text("No DICOM images found in the selection. Skipped: ^[\(skipped) file](inflect: true).")
            closeButton
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(message)
            closeButton
        case .idle, .confirm:
            EmptyView()
        }
    }

    private func summaryText(_ s: ImportSummary) -> String {
        // Inflection makes "1 study" and "2 studies" agree, in each language.
        func text(_ value: AttributedString) -> String { String(value.characters) }
        var parts = [text(AttributedString(localized: "Imported ^[\(s.studies) study](inflect: true), ^[\(s.images) image](inflect: true)."))]
        if s.duplicates > 0 { parts.append(text(AttributedString(localized: "Already in the worklist: ^[\(s.duplicates) image](inflect: true)."))) }
        if s.skipped > 0 { parts.append(text(AttributedString(localized: "Skipped: ^[\(s.skipped) file](inflect: true)."))) }
        if s.failed > 0 { parts.append(text(AttributedString(localized: "Unreadable: ^[\(s.failed) file](inflect: true)."))) }
        return parts.joined(separator: " ")
    }

    private var cancelButton: some View {
        Button("Cancel") { model.importer.cancel() }
            .controlSize(.small)
    }

    private var closeButton: some View {
        Button("Close") { model.importer.dismissMessage() }
            .controlSize(.small)
    }
}
