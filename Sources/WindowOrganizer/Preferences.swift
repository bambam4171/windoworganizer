import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import WindowOrganizerCore

@MainActor
enum Preferences {
    static let changed = Notification.Name("WindowOrganizerPreferencesChanged")
    static let defaults = UserDefaults.standard
    static var paused: Bool { get { defaults.bool(forKey: "paused") } set { defaults.set(newValue, forKey: "paused") } }
    static var restoreAtLaunch: Bool { defaults.bool(forKey: "restoreAtLaunch") }
    static var restoreOnScreens: Bool { defaults.bool(forKey: "restoreOnScreens") }
    static var arrangeNewWindows: Bool { defaults.bool(forKey: "arrangeNewWindows") }
    /// Start-missing-apps switches (WO-LAUNCH-MISSING S2): unset means the trigger's default, never `defaults.bool`.
    static func starts(_ trigger: LaunchTrigger) -> Bool {
        defaults.object(forKey: "startMissing." + trigger.rawValue) as? Bool ?? trigger.defaultOn
    }
    static var key: String { defaults.string(forKey: "restoreKey") ?? "r" }
    static var shortcut: Shortcut { Shortcut(key: key, display: "⌃⌥⌘" + key.uppercased()) }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static var shown: SettingsWindow?
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let message = NSTextField(wrappingLabelWithString: "")
    let permission = NSTextField(wrappingLabelWithString: "")
    let shortcut = NSPopUpButton()
    let login = NSButton(checkboxWithTitle: "Open Window Organizer at login", target: nil, action: nil)
    var toggles: [NSButton] = []
    var startToggles: [NSButton] = []
    static func show() {
        let s = shown ?? SettingsWindow(); shown = s; s.refresh()
        NSApp.activate(ignoringOtherApps: true); s.window.center(); s.window.makeKeyAndOrderFront(nil)
    }
    override init() {
        super.init()
        window.title = "Window Organizer — Settings"; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Make your workspace feel familiar.")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Remember an arrangement, then restore it with one shortcut. Automatic actions are optional.")
        intro.textColor = .secondaryLabelColor
        let permissionButton = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openPermission))
        let items = [("Restore when this app opens", "restoreAtLaunch"),
                     ("Restore after displays change, and on pending desktops", "restoreOnScreens"),
                     ("Place new windows in their remembered positions or zones", "arrangeNewWindows")]
        for (text, key) in items {
            let b = NSButton(checkboxWithTitle: text, target: self, action: #selector(toggle(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key); toggles.append(b)
        }
        let startItems: [(LaunchTrigger, String)] = [(.restore, "When I restore the arrangement"), (.applySave, "When I use Apply & Save"),
                                                     (.screenPlug, "When a display is plugged in"), (.login, "When Window Organizer opens")]
        for (trigger, text) in startItems {
            let b = NSButton(checkboxWithTitle: text, target: self, action: #selector(toggleStart(_:)))
            b.identifier = NSUserInterfaceItemIdentifier("startMissing." + trigger.rawValue); startToggles.append(b)
        }
        let startNote = NSTextField(wrappingLabelWithString: "Apps in a layout that are not running are opened, and their windows are placed. Each switch is separate.")
        startNote.textColor = .secondaryLabelColor; startNote.font = .systemFont(ofSize: 11)
        shortcut.addItems(withTitles: HotKey.keyCodes.keys.sorted().map { "⌃⌥⌘" + $0.uppercased() })
        shortcut.target = self; shortcut.action = #selector(changeShortcut)
        login.target = self; login.action = #selector(toggleLogin)
        let data = NSStackView(views: [NSButton(title: "Export layouts…", target: self, action: #selector(exportLayouts)),
                                       NSButton(title: "Import layouts…", target: self, action: #selector(importLayouts)),
                                       NSButton(title: "Show saved files", target: self, action: #selector(showFiles))])
        let privacy = NSTextField(wrappingLabelWithString: "Layouts stay on this Mac and may contain window titles. Settings and layouts are saved in ~/Library/Application Support/WindowOrganizer.")
        privacy.textColor = .secondaryLabelColor; privacy.font = .systemFont(ofSize: 11)
        let all = NSStackView(views: [title, intro, permission, permissionButton, NSBox(),
            heading("Automatic arrangement"), toggles[0], toggles[1], toggles[2], login,
            NSStackView(views: [NSTextField(labelWithString: "Restore shortcut"), shortcut]), NSBox(), heading("Start missing apps"), startNote, startToggles[0], startToggles[1], startToggles[2], startToggles[3], NSBox(), heading("Your layouts"), NSButton(title: "Open Layouts…", target: self, action: #selector(openLayouts)), data, NSButton(title: "Recover previous saved layout…", target: self, action: #selector(recoverPrevious)), privacy, message])
        all.orientation = .vertical; all.alignment = .leading; all.spacing = 12
        all.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        for v in all.arrangedSubviews where v is NSBox { (v as? NSBox)?.boxType = .separator }
        all.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(all)
        NSLayoutConstraint.activate([all.leadingAnchor.constraint(equalTo: content.leadingAnchor), all.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            all.topAnchor.constraint(equalTo: content.topAnchor), all.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        window.setContentSize(NSSize(width: 610, height: all.fittingSize.height))
        message.textColor = .secondaryLabelColor
    }
    func heading(_ text: String) -> NSTextField { let v = NSTextField(labelWithString: text); v.font = .systemFont(ofSize: 13, weight: .semibold); return v }
    func refresh() {
        permission.stringValue = Permission.trusted ? "✓ Accessibility access is enabled." : "Enable Window Organizer under Privacy & Security → Accessibility to read and move windows."
        permission.textColor = Permission.trusted ? .systemGreen : .labelColor
        for b in toggles { b.state = Preferences.defaults.bool(forKey: b.identifier!.rawValue) ? .on : .off }
        for b in startToggles { b.state = Preferences.defaults.object(forKey: b.identifier!.rawValue) as? Bool ?? (b.identifier!.rawValue != "startMissing.login") ? .on : .off }
        shortcut.selectItem(withTitle: Preferences.shortcut.display)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc func toggle(_ b: NSButton) {
        guard let key = b.identifier?.rawValue else { return }
        Preferences.defaults.set(b.state == .on, forKey: key)
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
    }
    @objc func toggleStart(_ b: NSButton) {
        guard let key = b.identifier?.rawValue else { return }
        Preferences.defaults.set(b.state == .on, forKey: key)
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
    }
    @objc func changeShortcut() {
        guard let text = shortcut.titleOfSelectedItem, let key = text.last?.lowercased(), key != Preferences.key else { return }
        let next = Shortcut(key: key, display: text)
        guard HotKey.register(next, action: HotKey.action ?? {}) else {
            message.stringValue = "That shortcut is already in use. The previous shortcut remains active."; refresh(); return
        }
        Preferences.defaults.set(key, forKey: "restoreKey")
        message.stringValue = "Restore shortcut updated."
    }
    @objc func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message.stringValue = SMAppService.mainApp.status == .requiresApproval ? "Allow Window Organizer in System Settings → Login Items." : "Login preference updated."
        } catch { message.stringValue = "Could not change login preference: \(error.localizedDescription)" }
        refresh()
    }
    @objc func openLayouts() { LayoutsWindow.show() }
    @objc func openPermission() { NSWorkspace.shared.open(Permission.settingsURL) }
    @objc func showFiles() {
        let folder = layoutStore().file.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc func recoverPrevious() {
        do {
            _ = try LayoutStore.decode(Data(contentsOf: layoutStore().previous))
            let alert = NSAlert(); alert.messageText = "Recover the previous saved layout?"
            alert.informativeText = "The current file will be preserved separately. Recovery does not move windows."
            alert.addButton(withTitle: "Recover"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try layoutStore().restorePrevious(); message.stringValue = "Previous layout recovered."
        } catch { message.stringValue = "Recovery failed: \(error)" }
    }
    @objc func exportLayouts() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "WindowOrganizer-layouts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let layouts = try layoutStore().load(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layouts).write(to: url, options: .atomic); message.stringValue = "Layouts exported."
        } catch { message.stringValue = "Export failed: \(error)" }
    }
    @objc func importLayouts() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try LayoutStore.decode(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "Replace this edition’s saved layouts?"
            alert.informativeText = "Import contains \(imported.setups.count) display setup(s) and \(imported.rules.count) app rule(s). The current valid layout will be kept as layouts.prev.json."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try layoutStore().save(imported); message.stringValue = "Layouts imported. Open Layouts to inspect them."
        } catch { message.stringValue = "Import failed: \(error)" }
    }
}
