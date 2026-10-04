import AppKit
import ApplicationServices
import WindowOrganizerCore

func axAttr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func axFrame(_ element: AXUIElement) -> Frame? {
    guard let p: AXValue = axAttr(element, kAXPositionAttribute),
          let s: AXValue = axAttr(element, kAXSizeAttribute),
          AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &pt), AXValueGetValue(s, .cgSize, &sz) else { return nil }
    let frame = Frame(x: pt.x, y: pt.y, width: sz.width, height: sz.height)
    return frame.isValid ? frame : nil
}

struct Listing {
    var windows: [WindowInfo] = []
    var elements: [Int: AXUIElement] = [:]
    var warnings: [String] = []
}

/// AXWindows alone is not a current-Space filter. Intersect with WindowServer's onscreen IDs.
/// The optional private AX ID function is dynamically resolved; the conservative fallback requires a unique frame.
enum WindowIdentity {
    typealias GetID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let getID: GetID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetID.self)
    }()
    static func id(_ element: AXUIElement) -> Int? {
        guard let getID else { return nil }
        var id: CGWindowID = 0
        return getID(element, &id) == .success && id != 0 ? Int(id) : nil
    }
}

/// Limit WindowServer identities before querying AX, so other desktops and monitors do not block this screen.
func visibleWindows(_ info: [[String: Any]], on selected: String?, screens: [ScreenInfo]) -> [[String: Any]] {
    info.filter { entry in
        guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
        guard let selected else { return true }
        guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        let frame = Frame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        return screenUUID(for: frame, in: screens) == selected
    }
}

@MainActor
func listWindows(screens: [ScreenInfo], screenUUID selected: String? = nil, timeoutPerApp: Float = 0.2) -> Listing {
    var out = Listing()
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        out.warnings = ["Could not identify windows on the current desktop."]; return out
    }
    let visible = visibleWindows(info, on: selected, screens: screens)
    let visiblePIDs = Set(visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
    let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && visiblePIDs.contains($0.processIdentifier) }
        .sorted { $0.processIdentifier < $1.processIdentifier }
    for app in apps {
        guard let bundleID = app.bundleIdentifier, !app.isHidden else { continue }
        let ae = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ae, timeoutPerApp)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ae, kAXWindowsAttribute as CFString, &raw)
        if error == .attributeUnsupported || error == .noValue { continue }
        guard error == .success, let elements = raw as? [AXUIElement] else {
            out.warnings.append("\(app.localizedName ?? bundleID) did not respond."); continue
        }
        let frames = elements.map(axFrame)
        var entries: [(Int, AXUIElement, Frame)] = []
        for (index, w) in elements.enumerated() {
            guard WindowFilter.counts(subrole: axAttr(w, kAXSubroleAttribute) ?? "",
                                      fullScreen: (axAttr(w, "AXFullScreen") as NSNumber?)?.boolValue ?? false,
                                      minimized: (axAttr(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false),
                  let frame = frames[index] else { continue }
            let id: Int?
            if let stable = WindowIdentity.id(w) { id = visibleIDs.contains(stable) ? stable : nil }
            else {
                let candidates = visible.filter { d in
                    guard (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                          let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                          let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                    return abs(rect.minX - frame.x) < 1 && abs(rect.minY - frame.y) < 1 && abs(rect.width - frame.width) < 1 && abs(rect.height - frame.height) < 1
                }
                // Identical bounds on another Space are ambiguous without AX IDs: leave both alone.
                id = candidates.count == 1 && frames.filter({ $0 == frame }).count == 1
                    ? (candidates[0][kCGWindowNumber as String] as? NSNumber)?.intValue : nil
            }
            guard let id, out.elements[id] == nil, screenUUID(for: frame, in: screens) != nil else { continue }
            entries.append((id, w, frame))
        }
        for (order, entry) in entries.sorted(by: { $0.0 < $1.0 }).enumerated() {
            let (id, w, frame) = entry
            guard let screen = screenUUID(for: frame, in: screens) else { continue }
            out.windows.append(WindowInfo(windowID: id, bundleID: bundleID, title: axAttr(w, kAXTitleAttribute) ?? "",
                                          frame: frame, screenUUID: screen, order: order))
            out.elements[id] = w
        }
    }
    return out
}

enum Permission {
    static var trusted: Bool { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
