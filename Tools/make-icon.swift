// Draws DeskKit's app icon (two displays with their own Docks, a keyboard and a mouse on a desk)
// and writes Resources/AppIcon.icns and Resources/AppIcon.png.
// Run from the repository root:  swift Tools/make-icon.swift
import AppKit

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let white = NSColor(white: 1, alpha: 0.96)

    // Body on Apple's 824 pt icon grid, with a soft shadow.
    let body = roundedRect(NSRect(x: 100, y: 100, width: 824, height: 824), 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.17, blue: 0.52, alpha: 1),
               ending: NSColor(srgbRed: 0.30, green: 0.54, blue: 0.98, alpha: 1))!.draw(in: body, angle: 90)

    // The desk: a lighter band across the bottom.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSColor(white: 1, alpha: 0.13).setFill()
    NSRect(x: 100, y: 100, width: 824, height: 262).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Two displays, each with its own Dock.
    let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.85, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.48, blue: 1.00, alpha: 1),
    ]
    for originX in [172.0, 532.0] {
        let screen = NSRect(x: originX, y: 470, width: 320, height: 232)
        let frame = roundedRect(screen, 30)
        NSColor(white: 1, alpha: 0.16).setFill()
        frame.fill()
        white.setStroke()
        frame.lineWidth = 16
        frame.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: screen.midX - 30, y: 392))
        stand.line(to: NSPoint(x: screen.midX + 30, y: 392))
        stand.line(to: NSPoint(x: screen.midX + 20, y: screen.minY - 8))
        stand.line(to: NSPoint(x: screen.midX - 20, y: screen.minY - 8))
        stand.close()
        white.setFill()
        stand.fill()
        roundedRect(NSRect(x: screen.midX - 66, y: 376, width: 132, height: 22), 11).fill()

        let dock = NSRect(x: screen.midX - 112, y: screen.minY + 22, width: 224, height: 56)
        NSColor(white: 1, alpha: 0.9).setFill()
        roundedRect(dock, 20).fill()
        for (i, color) in colors.enumerated() {
            color.setFill()
            roundedRect(NSRect(x: dock.minX + 16 + CGFloat(i) * 50, y: dock.minY + 10, width: 42, height: 36), 10).fill()
        }
    }

    // A keyboard and a mouse in front.
    let keyboard = NSRect(x: 220, y: 196, width: 420, height: 112)
    white.setFill()
    roundedRect(keyboard, 22).fill()
    NSColor(srgbRed: 0.20, green: 0.36, blue: 0.80, alpha: 0.55).setFill()
    for row in 0..<3 {
        let y = keyboard.minY + 16 + CGFloat(row) * 28
        if row == 0 {
            roundedRect(NSRect(x: keyboard.minX + 96, y: y, width: 228, height: 20), 7).fill()
            for x in [keyboard.minX + 20, keyboard.minX + 58, keyboard.maxX - 96, keyboard.maxX - 58] {
                roundedRect(NSRect(x: x, y: y, width: 30, height: 20), 7).fill()
            }
        } else {
            let offset: CGFloat = row == 1 ? 20 : 32
            var x = keyboard.minX + offset
            while x + 30 <= keyboard.maxX - 16 {
                roundedRect(NSRect(x: x, y: y, width: 30, height: 20), 7).fill()
                x += 38
            }
        }
    }

    let mouse = roundedRect(NSRect(x: 712, y: 176, width: 104, height: 152), 52)
    white.setFill()
    mouse.fill()
    NSColor(srgbRed: 0.20, green: 0.36, blue: 0.80, alpha: 0.55).setFill()
    roundedRect(NSRect(x: 757, y: 262, width: 14, height: 38), 7).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * factor).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try render(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
