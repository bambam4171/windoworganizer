import AppKit
import WindowOrganizerCore

struct PreviewWindow: Equatable {
    var frame: Frame
    var title: String
    var bundleID: String
    var windowID: Int? = nil
}

/// Interactive geometry only; this view never moves another app itself.
@MainActor
final class ScreenPreview: NSView {
    var screen: ScreenInfo?
    var windows: [PreviewWindow] = []
    var message = ""
    var editable = false
    var selectedID: Int?
    var changed: ((Int, Frame) -> Void)?
    private var drag: (id: Int, start: CGPoint, frame: Frame, resize: Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { editable }
    func displayRect() -> CGRect {
        guard let screen, screen.frame.isValid else { return .zero }
        let area = bounds.insetBy(dx: 24, dy: 20)
        let scale = min(area.width / screen.frame.width, area.height / screen.frame.height)
        let size = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
    func previewRect(_ frame: Frame) -> CGRect {
        guard let screen, screen.frame.isValid else { return .zero }
        let display = displayRect(), scale = display.width / screen.frame.width
        return CGRect(x: display.minX + (frame.x - screen.frame.x) * scale, y: display.minY + (frame.y - screen.frame.y) * scale, width: frame.width * scale, height: frame.height * scale)
    }
    func transformed(_ frame: Frame, delta: CGPoint, resize: Bool) -> Frame {
        guard let screen else { return frame }
        let scale = displayRect().width / screen.frame.width
        guard scale > 0 else { return frame }
        var next = frame
        if resize {
            next.width = max(min(180, screen.visibleFrame.width), frame.width + delta.x / scale)
            next.height = max(min(120, screen.visibleFrame.height), frame.height + delta.y / scale)
        } else { next.x += delta.x / scale; next.y += delta.y / scale }
        return next.contained(in: screen.visibleFrame)
    }
    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let item = windows.first(where: { previewRect($0.frame).contains(point) }), let id = item.windowID else { selectedID = nil; needsDisplay = true; return }
        let rect = previewRect(item.frame)
        selectedID = id; window?.makeFirstResponder(self)
        drag = (id, point, item.frame, point.x > rect.maxX - 20 && point.y > rect.maxY - 20)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let i = windows.firstIndex(where: { $0.windowID == drag.id }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = transformed(drag.frame, delta: CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y), resize: drag.resize)
        windows[i].frame = frame; changed?(drag.id, frame); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
    override func keyDown(with event: NSEvent) {
        guard editable, let id = selectedID, let item = windows.first(where: { $0.windowID == id }) else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 20 : 4
        let delta: CGPoint
        switch event.keyCode {
        case 123: delta = CGPoint(x: -step, y: 0)
        case 124: delta = CGPoint(x: step, y: 0)
        case 125: delta = CGPoint(x: 0, y: step)
        case 126: delta = CGPoint(x: 0, y: -step)
        default: super.keyDown(with: event); return
        }
        changed?(id, transformed(item.frame, delta: delta, resize: event.modifierFlags.contains(.option)))
    }
    func updateAccessibility() {
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Screen canvas: \(screen?.name ?? "no screen"). \(windows.count) windows. \(editable ? "Drag windows to move, drag bottom-right corners to resize. Arrow keys move; Option resizes." : message)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        guard let screen else { return }
        let display = displayRect(), desktop = NSBezierPath(roundedRect: display, xRadius: 10, yRadius: 10)
        NSGradient(colors: [NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.39, blue: 0.50, alpha: 1)])?.draw(in: desktop, angle: 45)
        NSGraphicsContext.saveGraphicsState(); desktop.addClip()
        let usable = previewRect(screen.visibleFrame)
        NSColor.white.withAlphaComponent(0.10).setFill(); NSBezierPath(rect: CGRect(x: display.minX, y: display.minY, width: display.width, height: max(0, usable.minY - display.minY))).fill()
        for item in windows.reversed() {
            let rect = previewRect(item.frame)
            guard rect.intersects(display) else { continue }
            let selected = editable && item.windowID != nil && item.windowID == selectedID
            let hue = Double(item.bundleID.utf8.reduce(0) { ($0 * 31 + Int($1)) % 360 }) / 360
            let color = NSColor(calibratedHue: hue, saturation: 0.40, brightness: 0.85, alpha: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 7; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            (selected ? NSColor.controlAccentColor : color).setStroke(); path.lineWidth = selected ? 3 : 1; path.stroke()
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            color.withAlphaComponent(0.22).setFill(); NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(32, rect.height))).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (item.title as NSString).draw(in: rect.insetBy(dx: 12, dy: 9), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            if editable && rect.width > 35 && rect.height > 35 {
                let grip = NSBezierPath(); grip.move(to: CGPoint(x: rect.maxX - 16, y: rect.maxY - 5)); grip.line(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - 16)); grip.move(to: CGPoint(x: rect.maxX - 10, y: rect.maxY - 5)); grip.line(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - 10)); grip.lineWidth = 2; NSColor.secondaryLabelColor.setStroke(); grip.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if windows.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (message as NSString).draw(in: CGRect(x: usable.minX + 30, y: usable.midY - 25, width: max(0, usable.width - 60), height: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
