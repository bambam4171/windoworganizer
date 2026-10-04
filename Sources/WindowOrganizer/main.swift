import AppKit
import WindowOrganizerCore

@MainActor
func snapshot(screenUUID: String? = nil) -> (ListReport, Listing) {
    let screens = currentScreens(), trusted = Permission.trusted
    let listing = trusted ? listWindows(screens: screens, screenUUID: screenUUID) : Listing()
    return (ListReport(trusted: trusted, desktop: SkyLight.desktop(screens: screens), screens: screens, windows: listing.windows), listing)
}

if CommandLine.arguments.contains("--ui-smoke") { exit(runUISmoke()) }
if CommandLine.arguments.contains("--migrate") { exit(runMigrate(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)) }

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
    var screenWatch = ScreenWatch(known: Set(currentScreens().map(\.uuid)))

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
            guard let self else { return }; self.generation += 1; LaunchBatch.current?.contextMayHaveChanged(); LayoutsWindow.shown?.workspaceDidChange(); self.trigger(.spaceChanged(displays: self.displays()))
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }; self.generation += 1; LaunchBatch.current?.contextMayHaveChanged()
            // Geometry changes matter even if the display UUIDs stayed the same.
            LayoutsWindow.shown?.workspaceDidChange()
            self.scheduleScreens()
        }
        observe(NotificationCenter.default, Preferences.changed) { [weak self] in self?.generation += 1 }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { [weak self] in self?.stop() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.refreshPermission(); self?.scheduleScreens()
        }
        LaunchBatch.deliver = { [weak self] in self?.lastResult = $0 }
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
        if trusted, !wasTrusted { watcher = WindowWatcher { [weak self] element, app, bundle in self?.windowCreated(element, app: app, bundleID: bundle) } }
        if !trusted, wasTrusted { watcher?.stop(); watcher = nil; generation += 1 }
        wasTrusted = trusted
        if SettingsWindow.shown?.window.isVisible == true { SettingsWindow.shown?.refresh() }
    }
    func windowCreated(_ element: AXUIElement, app: String, bundleID: String? = nil) {
        let batch = LaunchBatch.owner(of: bundleID)
        guard Preferences.arrangeNewWindows || batch != nil, triggers.handle(.windowCreated) == .placeWindow else { return }
        let before = generation
        let desktops = displays().map(\.current)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.generation == before, !self.triggers.paused, self.displays().map(\.current) == desktops else {
                batch?.contextMayHaveChanged(); return
            }
            if let batch, !batch.finished, let bundleID {
                // A window of a started app: placed even with new-window placing off; Undo still reverts the Restore.
                if let (r, _) = placeNew(element, recordUndo: false) { batch.windowPlaced(bundleID: bundleID, result: r) }
                return
            }
            guard Preferences.arrangeNewWindows, LaunchBatch.current == nil else { return }
            if let line = placeNewWindow(element, app: app) { self.lastResult = line }
        }
    }
    func displays() -> [DisplaySpaces] {
        let screens = currentScreens()
        return SkyLight.displaySpaces(mainUUID: screens.first?.uuid, screenUUIDs: screens.map(\.uuid))
    }
    func scheduleScreens() {
        settle?.cancel()
        guard Preferences.restoreOnScreens, !triggers.paused else { _ = screenWatch.settle(Set(currentScreens().map(\.uuid))); return }
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, Preferences.restoreOnScreens, !self.triggers.paused else { return }
            self.trigger(.screensSettled(displays: self.displays()))
        }
    }
    func trigger(_ event: TriggerEvent) {
        let action = triggers.handle(event)
        defer { if case .spaceChanged = event, let line = applyPendingGroups(paused: triggers.paused) { lastResult = line } }
        var plugged = false
        if case .screensSettled = event {
            plugged = screenWatch.settle(Set(currentScreens().map(\.uuid)))
        }
        let permitted: Bool
        if case .start = event { permitted = Preferences.restoreAtLaunch }
        else { permitted = Preferences.restoreOnScreens }
        switch action {
        case .none, .placeWindow, .autoCheck: break  // .autoCheck is wired in AUTO-MODE S2
        case .arrange:
            // Only a start (login switch) or a screen that was not there at the previous settle may start apps.
            let launch = launchTrigger(for: event, plugged: plugged)
            if permitted, let line = restoreNow(automatic: true, launch: launch) { lastResult = line }
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
        addGroupsMenu(screens: screens)
        let pause = add("Pause automatic arrangement", #selector(togglePause)); pause.state = triggers.paused ? .on : .off
        if triggers.paused { add("Automatic arrangement is paused", nil) }
        if !trusted { add("Enable Accessibility…", #selector(openPermission)) }
        add("Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add("About Window Organizer", #selector(about))
        let quit = NSMenuItem(title: "Quit Window Organizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
    }
    func addGroupsMenu(screens: [ScreenInfo]) {
        guard let layouts = try? layoutStore().load(),
              let parent = groupsMenuItem(layouts: layouts, screens: screens, desktops: WorkspaceContext.live().desktops, trusted: Permission.trusted,
                                          session: GroupState.session, target: self, action: #selector(applyGroup(_:))) else { return }
        menu.addItem(parent)
    }
    @objc func applyGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let line = applyGroupNow(id) { lastResult = line }
    }
    @objc func restore() {
        let desktops = WorkspaceContext.live().desktops
        GroupState.session.clear(desktops.map { GroupKey(screen: $0.key, desktop: $0.value) })
        lastResult = restoreNow(launch: .restore)
    }
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
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        alert.informativeText = "Version \(version) (build \(build))\nRemember and restore window positions for each display setup and desktop. Use zones, app rules or automatic tiling.\n\nOnly visible standard windows are arranged. Windows are never sent to another desktop."
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
app.delegate = controller
app.run()
