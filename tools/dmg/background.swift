// Draws the DMG window background: a light neutral field, a drag arrow, one line of text.
// Usage: swift tools/dmg/background.swift <out.png> <scale>
// Window is 640 x 420 points; app icon centered at (170, 186), Aplicativos at (470, 186)
// in Finder's top-left coordinates.
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = NSSize(width: 640, height: 420)

let top = NSColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1)
let bottom = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.935, alpha: 1)
let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// AppKit draws from the bottom; Finder places icons from the top.
func y(_ top: CGFloat) -> CGFloat { size.height - top }

// Arrow from the app to Applications: a gentle dotted arc with a rounded head.
ink.withAlphaComponent(0.35).setStroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 256, y: y(176)))
arrow.curve(to: NSPoint(x: 374, y: y(172)), controlPoint1: NSPoint(x: 292, y: y(148)), controlPoint2: NSPoint(x: 344, y: y(148)))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.setLineDash([0.5, 13], count: 2, phase: 0)
arrow.stroke()
let head = NSBezierPath()
// The head follows the arc's direction at its end.
head.move(to: NSPoint(x: 373.5, y: y(159.5)))
head.line(to: NSPoint(x: 385, y: y(177)))
head.line(to: NSPoint(x: 364.5, y: y(181)))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// One line under the icons (icon labels end near 290).
let style = NSMutableParagraphStyle()
style.alignment = .center
let line = NSAttributedString(string: "Arraste para Aplicativos", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: ink.withAlphaComponent(0.6),
    .paragraphStyle: style,
])
let bounds = line.size()
line.draw(at: NSPoint(x: size.width / 2 - bounds.width / 2, y: y(318) - bounds.height))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
