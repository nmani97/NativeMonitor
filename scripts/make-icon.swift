// Draws the app icon (1024×1024, macOS icon grid): swift scripts/make-icon.swift <out.png>
import AppKit

let S: CGFloat = 1024
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple-style continuous-corner tile (superellipse), not a plain rounded rect.
func squircle(_ r: NSRect, n: CGFloat = 4) -> NSBezierPath {
    let p = NSBezierPath(), cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
    }
    p.close(); return p
}

func shadow(_ color: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = color; sh.shadowBlurRadius = blur; sh.shadowOffset = NSSize(width: 0, height: y); sh.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func symbol(_ name: String, size: CGFloat, at c: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [.white]))
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    s.draw(in: NSRect(x: c.x - s.size.width / 2, y: c.y - s.size.height / 2, width: s.size.width, height: s.size.height))
}

let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    // Tile: 824 pt on the 1024 grid, with the system-style drop shadow.
    let tile = squircle(NSRect(x: 100, y: 100, width: 824, height: 824))
    shadow(NSColor.black.withAlphaComponent(0.35), blur: 28, y: -12) { rgb(0x101634).setFill(); tile.fill() }
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    NSGradient(colors: [rgb(0x22307A), rgb(0x141C4A), rgb(0x0B1030)])!.draw(in: tile, angle: -90)
    NSGradient(colors: [rgb(0x6B7CFF, 0.45), rgb(0x6B7CFF, 0)])!                       // light from the top
        .draw(fromCenter: NSPoint(x: 512, y: 900), radius: 0, toCenter: NSPoint(x: 512, y: 900), radius: 620, options: [])
    NSGradient(colors: [rgb(0x7A5CFF, 0.55), rgb(0x2E8BFF, 0)])!                       // screen glow on the tile
        .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 430, options: [])

    // Stand: aluminium neck and foot.
    let neck = NSBezierPath(); neck.move(to: NSPoint(x: 470, y: 400)); neck.line(to: NSPoint(x: 554, y: 400))
    neck.line(to: NSPoint(x: 572, y: 290)); neck.line(to: NSPoint(x: 452, y: 290)); neck.close()
    NSGradient(colors: [rgb(0x8E939E), rgb(0xD5D9E0), rgb(0x9DA2AC)])!.draw(in: neck, angle: 0)
    let foot = NSBezierPath(roundedRect: NSRect(x: 372, y: 262, width: 280, height: 34), xRadius: 17, yRadius: 17)
    shadow(NSColor.black.withAlphaComponent(0.45), blur: 18, y: -8) { rgb(0xB9BDC6).setFill(); foot.fill() }
    NSGradient(colors: [rgb(0xE4E7EC), rgb(0x9EA3AD)])!.draw(in: foot, angle: -90)

    // Monitor: ultrawide aluminium body.
    let body = NSBezierPath(roundedRect: NSRect(x: 172, y: 388, width: 680, height: 336), xRadius: 34, yRadius: 34)
    shadow(NSColor.black.withAlphaComponent(0.55), blur: 40, y: -18) { rgb(0x2A2D35).setFill(); body.fill() }
    NSGradient(colors: [rgb(0x4A4E59), rgb(0x2B2E36), rgb(0x1C1E24)])!.draw(in: body, angle: -90)
    rgb(0xFFFFFF, 0.18).setStroke(); body.lineWidth = 3; body.stroke()

    // Screen: glowing violet → blue, with a glass reflection.
    let screenRect = NSRect(x: 194, y: 410, width: 636, height: 292)
    let screen = NSBezierPath(roundedRect: screenRect, xRadius: 16, yRadius: 16)
    NSGradient(colors: [rgb(0x8A5CFF), rgb(0x5A6BFF), rgb(0x2E9BFF)])!.draw(in: screen, angle: -25)
    NSGraphicsContext.saveGraphicsState(); screen.addClip()
    let glare = NSBezierPath(); glare.move(to: NSPoint(x: 194, y: 702)); glare.line(to: NSPoint(x: 560, y: 702))
    glare.line(to: NSPoint(x: 400, y: 410)); glare.line(to: NSPoint(x: 194, y: 410)); glare.close()
    NSGradient(colors: [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0.0)])!.draw(in: glare, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // What the app does: brightness and volume.
    shadow(rgb(0x1A0B5C, 0.45), blur: 12, y: -4) {
        symbol("sun.max.fill", size: 118, at: NSPoint(x: 400, y: 556))
        symbol("speaker.wave.2.fill", size: 112, at: NSPoint(x: 630, y: 556))
    }
    NSGraphicsContext.restoreGraphicsState()

    // Thin bright rim on the tile edge, like system icons.
    rgb(0xFFFFFF, 0.10).setStroke(); tile.lineWidth = 2; tile.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: S, height: S))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
