// Run: swift tools/generate-app-icon.swift /tmp/Scriptser.iconset
// Then: iconutil -c icns /tmp/Scriptser.iconset -o Sources/Scriptser/Resources/AppIcon.icns
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.34, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.52, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.28, alpha: 1))!.draw(in: tile, angle: -65)
    let terminal = NSBezierPath(roundedRect: NSRect(x: 170, y: 240, width: 684, height: 544), xRadius: 58, yRadius: 58)
    NSColor(calibratedRed: 0.035, green: 0.07, blue: 0.12, alpha: 1).setFill()
    terminal.fill()
    NSColor.white.withAlphaComponent(0.2).setStroke()
    terminal.lineWidth = 3
    terminal.stroke()
    for (index, color) in [NSColor(calibratedRed: 1, green: 0.43, blue: 0.40, alpha: 1),
                           NSColor(calibratedRed: 1, green: 0.77, blue: 0.35, alpha: 1),
                           NSColor(calibratedRed: 0.35, green: 0.84, blue: 0.64, alpha: 1)].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 220 + index * 48, y: 710, width: 24, height: 24)).fill()
    }
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 280, y: 590))
    prompt.line(to: NSPoint(x: 410, y: 486))
    prompt.line(to: NSPoint(x: 280, y: 382))
    prompt.lineWidth = 46
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    NSColor(calibratedRed: 0.44, green: 0.95, blue: 0.78, alpha: 1).setStroke()
    prompt.stroke()
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 490, y: 382))
    cursor.line(to: NSPoint(x: 686, y: 382))
    cursor.lineWidth = 46
    cursor.lineCapStyle = .round
    NSColor(calibratedWhite: 0.97, alpha: 1).setStroke()
    cursor.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
