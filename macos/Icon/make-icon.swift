// Renders the app icon PNG (no external assets/API): a blue→teal squircle with
// a white doorbell glyph. Usage: swift make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237  // ~Apple squircle corner
NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()

NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.36, blue: 0.82, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.70, blue: 0.69, alpha: 1),
])!.draw(in: rect, angle: -45)

let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let names = ["door.left.hand.closed", "bell.fill"]  // door is macOS 14+; bell fallback
if let glyph = names.lazy.compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
    .first?.withSymbolConfiguration(cfg) {
    let g = glyph.size
    glyph.draw(at: NSPoint(x: (size - g.width) / 2, y: (size - g.height) / 2),
               from: .zero, operation: .sourceOver, fraction: 1)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
