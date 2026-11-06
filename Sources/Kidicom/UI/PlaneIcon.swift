import AppKit
import KidicomKit
import SwiftUI

/// Toolbar icons for Axial, Coronal, and Sagittal: the head seen from above,
/// from the front, and in profile. Template images, so they follow the
/// toolbar's colors in light, dark, and when selected.
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

    /// Silhouettes on a 20 x 20 canvas, y down.
    private static func draw(_ plane: PatientPlane) {
        NSColor.black.setFill()
        switch plane {
        case .axial:
            // The head from above: nose up, ears at the sides, the midline between the hemispheres.
            let head = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 12, height: 14.5))  // grid: ok icon drawing coordinates
            head.append(NSBezierPath(ovalIn: NSRect(x: 2.6, y: 9, width: 2.4, height: 4.2)))  // grid: ok icon drawing coordinates
            head.append(NSBezierPath(ovalIn: NSRect(x: 15, y: 9, width: 2.4, height: 4.2)))  // grid: ok icon drawing coordinates
            let nose = NSBezierPath()
            nose.move(to: NSPoint(x: 8.5, y: 4.8))
            nose.curve(to: NSPoint(x: 11.5, y: 4.8), controlPoint1: NSPoint(x: 9.2, y: 1.6), controlPoint2: NSPoint(x: 10.8, y: 1.6))
            nose.close()
            head.append(nose)
            head.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            let midline = NSBezierPath()
            midline.move(to: NSPoint(x: 10, y: 7.5)); midline.line(to: NSPoint(x: 10, y: 15.5))
            midline.lineWidth = 0.9
            midline.lineCapStyle = .round
            midline.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .coronal:
            // The head and shoulders from the front.
            let body = NSBezierPath(ovalIn: NSRect(x: 5.6, y: 1.8, width: 8.8, height: 11))  // grid: ok icon drawing coordinates
            body.append(NSBezierPath(rect: NSRect(x: 8.2, y: 11, width: 3.6, height: 5)))  // grid: ok icon drawing coordinates
            let shoulders = NSBezierPath()
            shoulders.move(to: NSPoint(x: 1.5, y: 20))
            shoulders.curve(to: NSPoint(x: 7, y: 15), controlPoint1: NSPoint(x: 1.5, y: 16.6), controlPoint2: NSPoint(x: 3.8, y: 15))
            shoulders.line(to: NSPoint(x: 13, y: 15))
            shoulders.curve(to: NSPoint(x: 18.5, y: 20), controlPoint1: NSPoint(x: 16.2, y: 15), controlPoint2: NSPoint(x: 18.5, y: 16.6))
            shoulders.close()
            body.append(shoulders)
            body.fill()
        case .sagittal, .oblique:
            // The head in profile, facing left.
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 11, y: 1.8))
            p.curve(to: NSPoint(x: 17, y: 8.5), controlPoint1: NSPoint(x: 15.2, y: 1.8), controlPoint2: NSPoint(x: 17, y: 5))
            p.curve(to: NSPoint(x: 14.4, y: 14.2), controlPoint1: NSPoint(x: 17, y: 11.4), controlPoint2: NSPoint(x: 15.8, y: 13.2))
            p.line(to: NSPoint(x: 15.2, y: 20))
            p.line(to: NSPoint(x: 7.6, y: 20))
            p.line(to: NSPoint(x: 7.6, y: 15.6))
            p.curve(to: NSPoint(x: 5.5, y: 13.4), controlPoint1: NSPoint(x: 6.6, y: 15.3), controlPoint2: NSPoint(x: 5.5, y: 14.6))
            p.line(to: NSPoint(x: 5.3, y: 11.9))
            p.line(to: NSPoint(x: 4.6, y: 11.4))
            p.line(to: NSPoint(x: 5.2, y: 10.7))
            p.curve(to: NSPoint(x: 3.8, y: 9.7), controlPoint1: NSPoint(x: 4.4, y: 10.6), controlPoint2: NSPoint(x: 3.8, y: 10.2))
            p.line(to: NSPoint(x: 5.0, y: 7.4))
            p.curve(to: NSPoint(x: 11, y: 1.8), controlPoint1: NSPoint(x: 4.9, y: 4.2), controlPoint2: NSPoint(x: 7.6, y: 1.8))
            p.close()
            p.lineJoinStyle = .round
            p.fill()
        }
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
