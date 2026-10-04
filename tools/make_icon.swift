import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: NSColor(red: 0.15, green: 0.40, blue: 0.87, alpha: 1), ending: NSColor(red: 0.23, green: 0.68, blue: 0.89, alpha: 1))!.draw(in: background, angle: 70)
        let rects = [NSRect(x: p * 0.21, y: p * 0.25, width: p * 0.26, height: p * 0.5),
                     NSRect(x: p * 0.53, y: p * 0.52, width: p * 0.26, height: p * 0.23),
                     NSRect(x: p * 0.53, y: p * 0.25, width: p * 0.26, height: p * 0.21)]
        NSColor.white.withAlphaComponent(0.94).setFill()
        for rect in rects { NSBezierPath(roundedRect: rect, xRadius: p * 0.035, yRadius: p * 0.035).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
