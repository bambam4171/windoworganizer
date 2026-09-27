import AppKit
import ApplicationServices
import Carbon
import WindowOrganizerCore

// Remember this desktop and Restore (plan §3, §4): the core decides, this file reads the screen and moves windows.

/// Moves windows through Accessibility: position, then size, then position again, because an app that clamps the size
/// to its screen may shift the window while resizing.
struct AXMover: WindowMover {
    let elements: [Int: AXUIElement]

    func frame(of id: Int) -> Frame? { elements[id].flatMap(axFrame) }

    func setFrame(_ f: Frame, of id: Int) {
        guard let e = elements[id] else { return }
        var pt = CGPoint(x: f.x, y: f.y), sz = CGSize(width: f.width, height: f.height)
        guard let p = AXValueCreate(.cgPoint, &pt), let s = AXValueCreate(.cgSize, &sz) else { return }
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
    }
}

/// layouts.json in Application Support, or in WO_STATE_DIR for a live check.
func layoutStore() -> LayoutStore {
    LayoutStore(directory: stateDirectory(environment: ProcessInfo.processInfo.environment,
                                          home: FileManager.default.homeDirectoryForCurrentUser))
}

func clock() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date())
}

/// Every display's own desktop number, keyed like the screens.
@MainActor
func desktopNumbers(screens: [ScreenInfo]) -> [String: Int] {
    currentDesktops(SkyLight.displaySpaces(mainUUID: screens.first?.uuid))
}

/// "Remember this desktop": one snapshot per screen, saved at once. Returns the menu's result line.
@MainActor
func rememberNow() -> String {
    let (report, _) = snapshot()
    guard report.trusted else { return StatusLine.text(trusted: false, desktop: nil, windows: 0, screens: 0) }
    let desktops = desktopNumbers(screens: report.screens)
    let store = layoutStore()
    do {
        var layouts = try store.load()
        let n = rememberDesktop(&layouts, windows: report.windows, screens: report.screens, desktops: desktops)
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.save(layouts)
        let screens = report.screens.filter { desktops[$0.uuid] != nil }.count
        return ResultLine.remembered(windows: n, screens: screens, desktop: report.desktop?.number, at: clock())
    } catch {
        return "Not remembered: \(error)"
    }
}

/// "Restore": puts this desktop's windows back where they were remembered. Returns the menu's result line.
@MainActor
func restoreNow() -> String {
    let (report, listing) = snapshot()
    guard report.trusted else { return StatusLine.text(trusted: false, desktop: nil, windows: 0, screens: 0) }
    let desktop = report.desktop?.number
    do {
        let layouts = try layoutStore().load()
        guard let plan = planRestore(layouts, windows: report.windows, screens: report.screens,
                                     desktops: desktopNumbers(screens: report.screens))
        else { return ResultLine.nothingRemembered(desktop: desktop, at: clock()) }
        return ResultLine.restored(applyPlan(plan, mover: AXMover(elements: listing.elements)), desktop: desktop, at: clock())
    } catch {
        return "Not restored: \(error)"
    }
}

/// The global Restore shortcut through Carbon's RegisterEventHotKey: no Input Monitoring permission needed.
@MainActor
enum HotKey {
    static var action: (() -> Void)?
    static var ref: EventHotKeyRef?

    static let keyCodes: [String: Int] = ["r": kVK_ANSI_R]

    @discardableResult
    static func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        guard let code = keyCodes[shortcut.key] else { return false }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x574F5247), id: 1)   // "WORG"
        return RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey | cmdKey), id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
