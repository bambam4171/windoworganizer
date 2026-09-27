import AppKit
import WindowOrganizerCore

// WindowOrganizer (S2): a menu-bar app that finds its permission and lists the current desktop's windows.
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

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Organizer")
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt on every open, so the status line is always the current desktop's.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (report, _) = snapshot()
        let status = StatusLine.text(trusted: report.trusted, desktop: report.desktop,
                                     windows: report.windows.count, screens: report.screens.count)
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        if !report.trusted {
            let open = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Window Organizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openSettings() { NSWorkspace.shared.open(Permission.settingsURL) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
app.run()
