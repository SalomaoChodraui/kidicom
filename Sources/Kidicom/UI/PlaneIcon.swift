import AppKit
import KidicomKit
import SwiftUI

/// Toolbar icons for Axial, Coronal, and Sagittal: a cube in outline with
/// the cutting plane filled. Template images, so they follow the toolbar's
/// colors in light, dark, and when selected.
enum PlaneIcon {
    static func image(_ plane: PatientPlane) -> NSImage {
        if let cached = cache[plane] { return cached }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: true) { _ in
            draw(plane)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title(plane)
        cache[plane] = image
        return image
    }

    static func title(_ plane: PatientPlane) -> String {
        ReformatSource.name(plane)
    }

    private static var cache: [PatientPlane: NSImage] = [:]

    /// Oblique projection: front face from (3, 7) to (13, 17), depth goes up
    /// and right by (4, -4). y grows downward.
    private static func draw(_ plane: PatientPlane) {
        let front = (x0: 3.0, y0: 7.0, x1: 13.0, y1: 17.0)
        let depth = CGVector(dx: 4, dy: -4)
        func p(_ x: Double, _ y: Double, _ d: Double) -> CGPoint {
            CGPoint(x: x + depth.dx * d, y: y + depth.dy * d)
        }

        // The cut, solid.
        let cut = NSBezierPath()
        let corners: [CGPoint]
        // Inset from the edges, so the cut reads as a slice inside the cube.
        let inset = 1.5, d0 = 0.15, d1 = 0.85
        switch plane {
        case .axial:
            let y = (front.y0 + front.y1) / 2
            corners = [p(front.x0 + inset, y, d0), p(front.x1 - inset, y, d0), p(front.x1 - inset, y, d1), p(front.x0 + inset, y, d1)]
        case .coronal:
            let x0 = front.x0 + inset, x1 = front.x1 - inset, y0 = front.y0 + inset, y1 = front.y1 - inset
            corners = [p(x0, y0, 0.5), p(x1, y0, 0.5), p(x1, y1, 0.5), p(x0, y1, 0.5)]
        case .sagittal, .oblique:
            let x = (front.x0 + front.x1) / 2
            corners = [p(x, front.y0 + inset, d0), p(x, front.y0 + inset, d1), p(x, front.y1 - inset, d1), p(x, front.y1 - inset, d0)]
        }
        cut.move(to: corners[0])
        for c in corners.dropFirst() { cut.line(to: c) }
        cut.close()
        NSColor.black.setFill()
        cut.fill()

        // The cube's edges, light.
        let edges = NSBezierPath()
        edges.lineWidth = 1
        edges.lineJoinStyle = .round
        edges.appendRect(NSRect(x: front.x0, y: front.y0, width: front.x1 - front.x0, height: front.y1 - front.y0))
        edges.move(to: p(front.x0, front.y0, 0)); edges.line(to: p(front.x0, front.y0, 1))
        edges.line(to: p(front.x1, front.y0, 1)); edges.line(to: p(front.x1, front.y1, 1))
        edges.line(to: p(front.x1, front.y1, 0))
        edges.move(to: p(front.x1, front.y0, 0)); edges.line(to: p(front.x1, front.y0, 1))
        NSColor.black.withAlphaComponent(0.55).setStroke()
        edges.stroke()
    }
}

/// The plane picker in the viewer's toolbar.
struct PlanePicker: View {
    let viewer: ViewerModel

    var body: some View {
        Picker("Plane", selection: Binding<PatientPlane?>(
            get: { viewer.activePlane == .oblique ? nil : viewer.activePlane },
            set: { plane in if let plane { Task { await viewer.show(plane: plane) } } }
        )) {
            ForEach([PatientPlane.axial, .coronal, .sagittal], id: \.self) { plane in
                Label { Text(PlaneIcon.title(plane)) } icon: { Image(nsImage: PlaneIcon.image(plane)) }
                    .tag(Optional(plane))
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .disabled(!viewer.canChangePlane)
        .help("Show the active series as axial (⌃1), coronal (⌃2), or sagittal (⌃3)")
    }
}
