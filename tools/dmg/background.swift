// Draws the DMG window background: title, drag-to-install arrow, note.
// Usage: swift tools/dmg/background.swift <out.png> <scale>
// Window is 640 x 420 points; app icon centered at (170, 186), Aplicativos at (470, 186)
// in Finder's top-left coordinates.
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = NSSize(width: 640, height: 420)

let petrol = NSColor(srgbRed: 0.02, green: 0.25, blue: 0.38, alpha: 1)
let teal = NSColor(srgbRed: 0.27, green: 0.69, blue: 0.60, alpha: 1)
let pale = NSColor(srgbRed: 0.87, green: 0.95, blue: 0.995, alpha: 1)
let soft = NSColor(srgbRed: 0.96, green: 0.985, blue: 1.0, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: soft vertical gradient in the icon's blue.
NSGradient(starting: soft, ending: pale)!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// AppKit draws from the bottom; Finder places icons from the top.
func y(_ top: CGFloat) -> CGFloat { size.height - top }

func text(_ string: String, font: NSFont, color: NSColor, centerX: CGFloat, top: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let bounds = attributed.size()
    attributed.draw(at: NSPoint(x: centerX - bounds.width / 2, y: y(top) - bounds.height))
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

// Title.
text("Kidicom, o DICOM da Kida!", font: rounded(28, .bold), color: petrol, centerX: size.width / 2, top: 26)

// Arrow from the app to Applications, a gentle arc with a rounded head.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 250, y: y(176)))
arrow.curve(to: NSPoint(x: 384, y: y(176)), controlPoint1: NSPoint(x: 290, y: y(144)), controlPoint2: NSPoint(x: 344, y: y(144)))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
teal.setStroke()
arrow.setLineDash([1, 14], count: 2, phase: 0)
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 372, y: y(160)))
head.line(to: NSPoint(x: 392, y: y(179)))
head.line(to: NSPoint(x: 366, y: y(188)))
head.lineWidth = 6
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Instruction under the icons (icon labels end near 290).
text("Arraste o Kidicom para a pasta Aplicativos", font: rounded(15, .semibold), color: petrol, centerX: size.width / 2, top: 298)

// Note.
let line = NSBezierPath(roundedRect: NSRect(x: size.width / 2 - 24, y: y(330), width: 48, height: 3), xRadius: 1.5, yRadius: 1.5)
teal.withAlphaComponent(0.6).setFill()
line.fill()
text("Feito com carinho, do Salo, para Kida", font: rounded(13, .medium), color: petrol.withAlphaComponent(0.75), centerX: size.width / 2, top: 342)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
