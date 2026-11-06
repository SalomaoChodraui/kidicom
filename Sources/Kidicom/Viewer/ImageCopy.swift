import AppKit
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
        Button(viewer?.overlay.nextTitle ?? "Hide Patient Name") { viewer?.overlay = viewer?.overlay.next ?? .full }
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(viewer == nil)
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
