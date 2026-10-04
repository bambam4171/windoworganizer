import AppKit
import WindowOrganizerCore

@MainActor
func snapshot(screenUUID: String? = nil) -> (ListReport, Listing) {
    let screens = currentScreens(), trusted = Permission.trusted
    let listing = trusted ? listWindows(screens: screens, screenUUID: screenUUID) : Listing()
    return (ListReport(trusted: trusted, desktop: SkyLight.desktop(screens: screens), screens: screens, windows: listing.windows), listing)
}

if CommandLine.arguments.contains("--ui-smoke") { exit(runUISmoke()) }

if CommandLine.arguments.contains("--list") || CommandLine.arguments.contains("--diagnostics") {
    let (report, listing) = snapshot()
    do {
        if CommandLine.arguments.contains("--diagnostics") {
            let data = try JSONSerialization.jsonObject(with: report.json())
            let diagnostics: [String: Any] = ["snapshot": data, "warnings": listing.warnings, "stateFile": layoutStore().file.path,
                "desktopAdapterAvailable": !SkyLight.displaySpaces(mainUUID: report.screens.first?.uuid, screenUUIDs: report.screens.map(\.uuid)).isEmpty]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]))
        } else { FileHandle.standardOutput.write(try report.json()) }
        FileHandle.standardOutput.write(Data("\n".utf8)); exit(0)
    } catch { FileHandle.standardError.write(Data("Diagnostics failed: \(error)\n".utf8)); exit(1) }
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var lastResult: String?
    var triggers = TriggerState()
    var settle: Task<Void, Never>?
    var watcher: WindowWatcher?
    var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    var permissionTimer: Timer?
    var wasTrusted = false
    var generation = 0

    override init() {
        super.init()
        triggers.paused = Preferences.paused
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Organizer")
        item.button?.toolTip = "Window Organizer — remember and restore your workspace"
        installApplicationMenu()
        menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
        if !HotKey.register(Preferences.shortcut, action: { [weak self] in self?.restore() }) {
            lastResult = "Shortcut \(Preferences.shortcut.display) is already in use. Choose another in Settings."
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            guard let self else { return }; self.generation += 1; LayoutsWindow.shown?.workspaceDidChange(); self.trigger(.spaceChanged(displays: self.displays()))
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }; self.generation += 1
            // Geometry changes matter even if the display UUIDs stayed the same.
            LayoutsWindow.shown?.workspaceDidChange()
            self.scheduleScreens()
        }
        observe(NotificationCenter.default, Preferences.changed) { [weak self] in self?.generation += 1 }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { [weak self] in self?.stop() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.refreshPermission(); self?.scheduleScreens()
        }
        refreshPermission()
        trigger(.start(screens: currentScreens().map(\.uuid), displays: displays()))
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindow.show() }
        else { LayoutsWindow.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LayoutsWindow.show(); return true
    }
    func installApplicationMenu() {
        let bar = NSMenu()
        let application = NSMenu(title: "Window Organizer")
        let root = NSMenuItem(); root.submenu = application; bar.addItem(root)
        for (title, selector, key) in [("About Window Organizer", #selector(about), ""),
                                      ("Settings…", #selector(openSettings), ","),
                                      ("Layouts…", #selector(openLayouts), "l")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; application.addItem(item)
        }
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Window Organizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let fileRoot = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File"); fileRoot.submenu = file; bar.addItem(fileRoot)
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit"); editRoot.submenu = edit; bar.addItem(editRoot)
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = bar
    }
    func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        notifications.append((center, token))
    }
    func stop() {
        generation += 1; settle?.cancel(); permissionTimer?.invalidate(); watcher?.stop(); HotKey.stop()
        for (center, token) in notifications { center.removeObserver(token) }; notifications = []
    }
    func refreshPermission() {
        let trusted = Permission.trusted
        if trusted, !wasTrusted { watcher = WindowWatcher { [weak self] element, app in self?.windowCreated(element, app: app) } }
        if !trusted, wasTrusted { watcher?.stop(); watcher = nil; generation += 1 }
        wasTrusted = trusted
        if SettingsWindow.shown?.window.isVisible == true { SettingsWindow.shown?.refresh() }
    }
    func windowCreated(_ element: AXUIElement, app: String) {
        guard Preferences.arrangeNewWindows, triggers.handle(.windowCreated) == .placeWindow else { return }
        let before = generation
        let desktops = displays().map(\.current)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.generation == before, !self.triggers.paused, Preferences.arrangeNewWindows,
                  self.displays().map(\.current) == desktops else { return }
            if let line = placeNewWindow(element, app: app) { self.lastResult = line }
        }
    }
    func displays() -> [DisplaySpaces] {
        let screens = currentScreens()
        return SkyLight.displaySpaces(mainUUID: screens.first?.uuid, screenUUIDs: screens.map(\.uuid))
    }
    func scheduleScreens() {
        settle?.cancel()
        guard Preferences.restoreOnScreens, !triggers.paused else { return }
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, Preferences.restoreOnScreens, !self.triggers.paused else { return }
            self.trigger(.screensSettled(displays: self.displays()))
        }
    }
    func trigger(_ event: TriggerEvent) {
        let action = triggers.handle(event)
        let permitted: Bool
        if case .start = event { permitted = Preferences.restoreAtLaunch }
        else { permitted = Preferences.restoreOnScreens }
        switch action {
        case .none, .placeWindow: break
        case .arrange: if permitted, let line = restoreNow(automatic: true) { lastResult = line }
        case .settle: scheduleScreens()
        }
    }
    @discardableResult
    func add(_ title: String, _ action: Selector?, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.isEnabled = enabled && action != nil; menu.addItem(entry); return entry
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let screens = currentScreens(), trusted = Permission.trusted
        let desktop = SkyLight.desktop(screens: screens)
        add("Window Organizer", nil)
        add(desktop.map { "Desktop \($0.number) · \(screens.count) display(s)" } ?? "Desktop unknown · manual layout", nil)
        if let lastResult { add(lastResult, nil) }
        menu.addItem(.separator())
        let r = add("Restore arrangement", #selector(restore), enabled: trusted, key: Preferences.key)
        r.keyEquivalentModifierMask = [.control, .option, .command]
        add("Remember this desktop", #selector(remember), enabled: trusted)
        add("Undo last arrangement", #selector(undo), enabled: trusted && RestoreSession.shared.canUndo)
        menu.addItem(.separator())
        add("Layouts…", #selector(openLayouts))
        let pause = add("Pause automatic arrangement", #selector(togglePause)); pause.state = triggers.paused ? .on : .off
        if triggers.paused { add("Automatic arrangement is paused", nil) }
        if !trusted { add("Enable Accessibility…", #selector(openPermission)) }
        add("Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add("About Window Organizer", #selector(about))
        let quit = NSMenuItem(title: "Quit Window Organizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
    }
    @objc func restore() { lastResult = restoreNow() }
    @objc func remember() { lastResult = rememberNow() }
    @objc func undo() { lastResult = RestoreSession.shared.undo() }
    @objc func togglePause() {
        triggers.paused.toggle(); Preferences.paused = triggers.paused; generation += 1
        if triggers.paused { settle?.cancel() }
        item.button?.appearsDisabled = triggers.paused
    }
    @objc func openLayouts() { LayoutsWindow.show() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func openPermission() { NSWorkspace.shared.open(Permission.settingsURL) }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "Window Organizer"
        alert.informativeText = "Review edition 1.3\nRemember and restore window positions for each display setup and desktop. Use zones, app rules or automatic tiling.\n\nOnly visible standard windows are arranged. Windows are never sent to another desktop."
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
app.delegate = controller
app.run()
