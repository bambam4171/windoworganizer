import AppKit
import ApplicationServices
import WindowOrganizerCore

// New windows go straight to their place (plan §3, slice S5): one AXObserver per running app reports kAXWindowCreated.
// Observers are attached at start and on launch and dropped on quit (the spike saw no close events when an app quits).

@MainActor
final class WindowWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let created: (AXUIElement, String) -> Void

    /// `created` gets the new window's AX element and its app's name.
    init(created: @escaping (AXUIElement, String) -> Void) {
        self.created = created
        for app in NSWorkspace.shared.runningApplications { attach(app) }
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.attach(app) } }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.detach(pid) } }
        })
    }

    func stop() {
        for pid in Array(observers.keys) { detach(pid) }
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }; tokens = []
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.windowCreated(element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString,
                                        refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func windowCreated(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app"
        created(element, name)
    }
}

/// Moves one new window to its remembered place; nothing else moves. Nil when it has no place (the menu keeps its line).
@MainActor
func placeNewWindow(_ element: AXUIElement, app: String) -> String? {
    let (report, listing) = snapshot()
    guard report.trusted, listing.warnings.isEmpty,
          let id = listing.elements.first(where: { CFEqual($0.value, element) })?.key,
          let layouts = try? layoutStore().load(),
          let plan = planRestore(layouts, windows: report.windows, screens: report.screens,
                                 desktops: desktopNumbers(screens: report.screens))
    else { return nil }
    let r = RestoreSession.shared.apply(onlyWindow(plan, id), listing: listing, screens: report.screens)
    return ResultLine.newWindow(r, app: app, desktop: report.desktop?.number, at: clock())
}
