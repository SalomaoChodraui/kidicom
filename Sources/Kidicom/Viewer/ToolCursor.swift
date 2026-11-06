import AppKit

/// Pointers that show what the mouse does right now, drawn from the same
/// SF Symbols as the toolbar: white with a dark outline, so they read on
/// black, gray, and white images.
enum ToolCursor {
    private static var cache: [String: NSCursor] = [:]

    static func symbol(_ name: String) -> NSCursor {
        if let cached = cache[name] { return cached }
        let size = NSSize(width: 28, height: 28)
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return .arrow
        }
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolSize = base.size
            let origin = NSPoint(x: (rect.width - symbolSize.width) / 2, y: (rect.height - symbolSize.height) / 2)
            // Dark outline: the symbol drawn in black around the white one.
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                tinted(base, .black).draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 0.85)
            }
            tinted(base, .white).draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
        cache[name] = cursor
        return cursor
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// The pointer for a left-button tool.
    static func cursor(for tool: MeasureTool) -> NSCursor {
        switch tool {
        case .navigate: symbol("circle.lefthalf.filled")
        case .scroll: symbol("arrow.up.and.down")
        case .rotate: symbol("rotate.right")
        case .distance, .angle, .area: .crosshair
        }
    }

    static var zoom: NSCursor { symbol("plus.magnifyingglass") }
    static var rotate: NSCursor { symbol("rotate.3d") }
    static var pan: NSCursor { .closedHand }
}
