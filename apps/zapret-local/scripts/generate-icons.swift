#!/usr/bin/swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icons = root.appendingPathComponent("resources/icons")
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)

func render(size: Int, appIcon: Bool = false) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let transform = AffineTransform(scale: CGFloat(size) / 32)
    let circle = NSBezierPath(ovalIn: NSRect(x: 3.75, y: 3.75, width: 24.5, height: 24.5))
    circle.transform(using: transform)
    let bolt = NSBezierPath()
    // Flip SVG y coordinates into AppKit's bottom-left coordinate system.
    let points: [(CGFloat, CGFloat)] = [(18.3, 6.8), (9.8, 17.1), (14.9, 17.1),
        (13.7, 25.2), (22.2, 14.2), (17.1, 14.2)]
    bolt.move(to: NSPoint(x: points[0].0, y: 32 - points[0].1))
    for p in points.dropFirst() { bolt.line(to: NSPoint(x: p.0, y: 32 - p.1)) }
    bolt.close()
    bolt.transform(using: transform)
    if appIcon {
        // Narrow white keyline remains readable on dark Finder backgrounds;
        // all other pixels outside the mark stay transparent.
        NSColor.white.setStroke()
        circle.lineWidth = 3.5 * CGFloat(size) / 32
        circle.stroke()
        bolt.lineWidth = 1.1 * CGFloat(size) / 32
        bolt.lineJoinStyle = .round
        bolt.stroke()
    }
    NSColor.black.setStroke()
    NSColor.black.setFill()
    circle.lineWidth = 2.5 * CGFloat(size) / 32
    circle.stroke()
    bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for (name, size) in [("tray.png", 32), ("tray@2x.png", 64)] {
    try render(size: size).write(to: icons.appendingPathComponent(name))
}
for size in [32, 128, 256] {
    try render(size: size, appIcon: true).write(to: icons.appendingPathComponent("\(size)x\(size).png"))
}
try render(size: 1024, appIcon: true).write(to: icons.appendingPathComponent("icon.png"))
let iconset = icons.appendingPathComponent("icon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size: size, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icons.appendingPathComponent("icon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
print("Generated transparent monochrome app and template tray icons.")
