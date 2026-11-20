// Draws the app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100, r = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1), NSColor(red: 0.10, green: 0.55, blue: 0.98, alpha: 1)])!
        .draw(in: shape, angle: -70)
    let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let s = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        s.draw(in: NSRect(x: (size - s.size.width) / 2, y: (size - s.size.height) / 2 + 30, width: s.size.width, height: s.size.height))
    }
    let small = NSImage.SymbolConfiguration(pointSize: 150, weight: .bold).applying(.init(paletteColors: [NSColor(red: 0.25, green: 0.40, blue: 0.97, alpha: 1)]))
    if let s = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(small) {
        s.draw(in: NSRect(x: (size - s.size.width) / 2, y: 470, width: s.size.width, height: s.size.height))
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
