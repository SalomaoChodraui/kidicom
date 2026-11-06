import AppKit
import KidicomKit
import SwiftUI

/// How much text the viewer draws over the images. Tab steps through them.
enum OverlayLevel: Int, CaseIterable {
    /// Patient, study, and image data.
    case full
    /// Everything but the patient's name and ID.
    case noNames
    /// The image alone, with its measurements.
    case hidden

    var next: OverlayLevel { OverlayLevel(rawValue: (rawValue + 1) % OverlayLevel.allCases.count) ?? .full }

    /// The menu item that moves on to the next level.
    var nextTitle: LocalizedStringResource {
        switch self {
        case .full: "Hide Patient Name"
        case .noNames: "Hide Image Data"
        case .hidden: "Show Image Data"
        }
    }
}

/// The viewer of the focused window, for the menu bar.
extension FocusedValues {
    @Entry var viewer: ViewerModel?
}

/// View menu items for the viewer.
struct ViewerCommands: View {
    @FocusedValue(\.viewer) private var viewer

    var body: some View {
        Button(viewer?.showsSeries == false ? "Show Series" : "Hide Series") { viewer?.showsSeries.toggle() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(viewer == nil)
        Button(viewer?.overlay.nextTitle ?? "Hide Patient Name") { viewer?.overlay = viewer?.overlay.next ?? .full }
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(viewer == nil)
        Button("DICOM Tags") { viewer?.showsTags.toggle() }
            .keyboardShortcut("i")
            .disabled(viewer == nil || viewer?.volume3D != nil)
        Divider()
        layoutMenu
        toolMenu
        windowMenu
        Button("Reset View") {
            if let session = viewer?.volume3D { session.resetCamera() } else { viewer?.active?.reset() }
        }
        .keyboardShortcut("r")
        .disabled(viewer == nil)
        Button(viewer?.active?.isPlaying == true ? "Pause" : "Play") { viewer?.active?.togglePlay() }
            .keyboardShortcut(.space, modifiers: [.control, .shift])
            .disabled(viewer == nil || viewer?.volume3D != nil || (viewer?.active?.count ?? 0) < 2)
        Divider()
        Button(viewer?.mpr == nil ? "MPR" : "Leave MPR") { viewer?.toggleMPR() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(viewer == nil || viewer?.buildProgress != nil || (viewer?.mpr == nil && viewer?.mprCandidate == nil))
        Button(viewer?.volume3D == nil ? "3D" : "Leave 3D") { viewer?.toggle3D() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(viewer == nil || viewer?.buildProgress != nil || (viewer?.volume3D == nil && viewer?.mpr == nil && viewer?.mprCandidate == nil))
    }

    private var layoutMenu: some View {
        Menu("Layout") {
            ForEach(Array(ViewerLayout.allCases.enumerated()), id: \.element.id) { index, layout in
                Toggle(isOn: Binding(get: { viewer?.layout == layout }, set: { _ in viewer?.layout = layout })) {
                    Text(layout.title)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .shift])
            }
        }
        .disabled(viewer == nil || viewer?.mpr != nil || viewer?.volume3D != nil || viewer?.buildProgress != nil)
    }

    private var toolMenu: some View {
        Menu("Tool") {
            ForEach(MeasureTool.allCases) { tool in
                Toggle(isOn: Binding(get: { viewer?.tool == tool }, set: { _ in viewer?.tool = tool })) {
                    Text(tool.title(in3D: viewer?.volume3D != nil))
                }
                // Modified shortcuts keep typing in the tag inspector available.
                .keyboardShortcut(KeyEquivalent(tool.key.first ?? "w"), modifiers: [.control, .shift])
                .disabled(viewer?.volume3D != nil && tool != .navigate && tool != .scroll && tool != .rotate)
            }
        }
        .disabled(viewer == nil)
    }

    private var windowMenu: some View {
        Menu("Window Presets") {
            ForEach(WindowPreset.allCases, id: \.self) { preset in
                Button(WindowPresets.title(preset)) { viewer?.active?.apply(preset) }
                    .keyboardShortcut(KeyEquivalent(Character(String(preset.rawValue))), modifiers: [.command, .option])
            }
        }
        .disabled(viewer == nil || viewer?.volume3D != nil || viewer?.active?.slice?.isColor != false)
    }

}

/// Puts what a viewport shows, with the text drawn over it, on the clipboard.
enum ImageCopy {
    /// The self-test swaps in a private pasteboard.
    static var pasteboard = NSPasteboard.general

    /// `base` is the picture at `scale` pixels per point, `size` in points.
    @discardableResult
    static func copy(_ base: CGImage, size: CGSize, scale: CGFloat, @ViewBuilder overlay: () -> some View) -> Bool {
        let content = ZStack {
            Image(decorative: base, scale: scale)
                .resizable()
            overlay()
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }
}
