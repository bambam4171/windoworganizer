import AppKit
import WindowOrganizerCore

// WindowOrganizer (S3): a menu-bar app that remembers the current desktop's windows and puts them back (⌃⌥⌘R).
// `--list` prints what it sees as JSON and quits: the live check, run as the .app (`open -n --stdout`, spike limit 3).

@MainActor
func snapshot() -> (ListReport, Listing) {
    let screens = currentScreens()
    let trusted = Permission.trusted
    let listing = trusted ? listWindows(screens: screens) : Listing()
    return (ListReport(trusted: trusted, desktop: SkyLight.desktop(screens: screens), screens: screens, windows: listing.windows), listing)
}

if CommandLine.arguments.contains("--list") {
    let (report, _) = snapshot()
    FileHandle.standardOutput.write((try? report.json()) ?? Data("{}".utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    /// What the last Remember or Restore did; shown until the next one.
    var lastResult: String?

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Organizer")
        menu.delegate = self
        item.menu = menu
        if !HotKey.register(.restore, action: { [weak self] in self?.restore() }) {
            lastResult = "The shortcut \(Shortcut.restore.display) is taken by another app"
        }
    }

    /// Rebuilt on every open, so the status line is always the current desktop's.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (report, _) = snapshot()
        let status = StatusLine.text(trusted: report.trusted, desktop: report.desktop,
                                     windows: report.windows.count, screens: report.screens.count)
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        if let lastResult { menu.addItem(NSMenuItem(title: lastResult, action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let restore = NSMenuItem(title: "Restore", action: report.trusted ? #selector(restore) : nil, keyEquivalent: Shortcut.restore.key)
        restore.keyEquivalentModifierMask = [.control, .option, .command]
        restore.target = self
        menu.addItem(restore)
        let remember = NSMenuItem(title: "Remember this desktop", action: report.trusted ? #selector(remember) : nil, keyEquivalent: "")
        remember.target = self
        menu.addItem(remember)
        if !report.trusted {
            let open = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Window Organizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func restore() { lastResult = restoreNow() }
    @objc func remember() { lastResult = rememberNow() }
    @objc func openSettings() { NSWorkspace.shared.open(Permission.settingsURL) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
app.run()
