import AppKit
import ApplicationServices
import WindowOrganizerCore

// Accessibility (plan §3): lists the windows of the desktop Tom is on. AX sees only the active desktop (spike limit 1).

func axAttr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func axFrame(_ e: AXUIElement) -> Frame? {
    guard let p: AXValue = axAttr(e, kAXPositionAttribute), let s: AXValue = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
    return Frame(x: pt.x, y: pt.y, width: sz.width, height: sz.height)
}

/// The listed windows plus their AX elements by window ID, which S3 needs to move them.
struct Listing {
    var windows: [WindowInfo] = []
    var elements: [Int: AXUIElement] = [:]
}

/// Standard windows of regular apps on the current desktop. `order` is the app's own window order, 0 = oldest,
/// and the window ID is the app pid × 1000 + that order: stable within one listing, which is all S1's planner needs.
@MainActor
func listWindows(screens: [ScreenInfo], timeoutPerApp: Float = 1.0) -> Listing {
    var out = Listing()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let bundleID = app.bundleIdentifier, app.processIdentifier != getpid() else { continue }
        let ae = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ae, timeoutPerApp)
        // AX lists front to back; reversed, the oldest-opened window tends to come first.
        let elements: [AXUIElement] = (axAttr(ae, kAXWindowsAttribute) ?? []).reversed()
        var order = 0
        for w in elements {
            let fullScreen = (axAttr(w, "AXFullScreen") as NSNumber?)?.boolValue ?? false
            let minimized = (axAttr(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
            guard WindowFilter.counts(subrole: axAttr(w, kAXSubroleAttribute) ?? "", fullScreen: fullScreen, minimized: minimized),
                  let frame = axFrame(w), let screen = screenUUID(for: frame, in: screens) else { continue }
            let id = Int(app.processIdentifier) * 1000 + order
            out.windows.append(WindowInfo(windowID: id, bundleID: bundleID, title: axAttr(w, kAXTitleAttribute) ?? "",
                                          frame: frame, screenUUID: screen, order: order))
            out.elements[id] = w
            order += 1
        }
    }
    return out
}

enum Permission {
    /// Never shows the system prompt; the menu offers the Settings page instead. (The key spelled out: the
    /// kAXTrustedCheckOptionPrompt global is not concurrency-safe under Swift 6.)
    static var trusted: Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
