// Renders Resources/AppIcon.icns: dark rounded square, white waveform — same look as the overlay pill.
// Usage: swift scripts/make-icon.swift
import AppKit

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let square = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.20, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1))!
        .draw(in: square, angle: -90)
    let heights: [CGFloat] = [0.22, 0.44, 0.68, 0.92, 0.56, 0.78, 0.40, 0.62, 0.28]
    let barWidth = s * 0.043, gap = s * 0.033, maxHeight = s * 0.42
    var x = (s - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap)) / 2
    NSColor.white.setFill()
    for h in heights {
        let barHeight = maxHeight * h
        NSBezierPath(roundedRect: NSRect(x: x, y: (s - barHeight) / 2, width: barWidth, height: barHeight),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let png = draw(pixels: px).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")
