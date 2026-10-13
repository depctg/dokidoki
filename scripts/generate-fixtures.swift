// Run with `swift scripts/generate-fixtures.swift` from the repository root.
// Original geometric illustrations; no downloaded comic artwork.
import AppKit
import ImageIO
import UniformTypeIdentifiers

for number in 1...4 {
    let width = number == 3 ? 1440 : 800
    let height = 1100
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.98, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    let panel = NSRect(x: 50, y: 70, width: width - 100, height: height - 140)
    NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.23, alpha: 1).setFill(); panel.fill()
    for star in 0..<38 {
        NSColor(calibratedRed: 0.87, green: 0.81, blue: 0.62, alpha: 1).setFill()
        let x = 70 + (star * 137 + number * 71) % (width - 150)
        let y = 100 + (star * 79 + number * 51) % 850
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 4, height: 4)).fill()
    }
    NSColor(calibratedRed: 0.34, green: 0.57, blue: 0.62, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: width / 2 - 150, y: 290, width: 300, height: 300)).fill()
    NSColor(calibratedRed: 0.91, green: 0.77, blue: 0.44, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: width / 2 + 25, y: 620, width: 105, height: 105)).fill()
    if number == 3 { NSColor(white: 0.98, alpha: 1).setFill(); NSRect(x: width / 2 - 24, y: 70, width: 48, height: height - 140).fill() }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .light), .foregroundColor: NSColor.white]
    ("THE OBSERVATORY" as NSString).draw(at: NSPoint(x: 85, y: 880), withAttributes: attributes)
    (["", "01 / ARRIVAL", "02 / THE QUIET SKY", "03 / A WIDER WORLD", "04 / STARLIGHT"][number] as NSString).draw(at: NSPoint(x: 85, y: 805), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.white])
    image.unlockFocus()
    var rect = NSRect(origin: .zero, size: image.size)
    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    let url = URL(fileURLWithPath: "Packages/MangaCore/Sources/MangaCore/Resources/Fixtures/\(number).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg, nil); CGImageDestinationFinalize(destination)
}
