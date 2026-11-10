// Genera icon_1024.png: mosaico Bayer RGGB (il RAW) + triangolo play + scritta DNG. Uso: swift make-icon.swift && ./build.sh
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Griglia icone macOS: quadrato 824 pt centrato, angoli arrotondati.
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185).addClip()
NSColor(white: 0.07, alpha: 1).setFill()
r.fill()

let n = 6, cell = r.width / CGFloat(n)
for y in 0..<n {
    for x in 0..<n {
        let c: NSColor = x % 2 == 0 && y % 2 == 1 ? NSColor(red: 0.93, green: 0.23, blue: 0.2, alpha: 1)
            : x % 2 == 1 && y % 2 == 0 ? NSColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
            : NSColor(red: 0.25, green: 0.78, blue: 0.36, alpha: 1)
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(x) * cell + 8, y: r.minY + CGFloat(y) * cell + 8,
                                         width: cell - 16, height: cell - 16), xRadius: 22, yRadius: 22).fill()
    }
}
// Vignettatura per staccare il triangolo dal mosaico.
NSGradient(colors: [NSColor(white: 0, alpha: 0.88), NSColor(white: 0, alpha: 0.72), NSColor(white: 0, alpha: 0.25)])!
    .draw(in: r, relativeCenterPosition: .zero)

let play = NSBezierPath()
play.move(to: NSPoint(x: 432, y: 770))
play.line(to: NSPoint(x: 432, y: 530))
play.line(to: NSPoint(x: 642, y: 650))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 44
NSColor.white.set()
play.fill()
play.stroke()

let base = NSFont.systemFont(ofSize: 250, weight: .black)
let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 250) } ?? base
let label = NSAttributedString(string: "DNG", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 6])
label.draw(at: NSPoint(x: 512 - label.size().width / 2, y: 190))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
