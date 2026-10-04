import AppKit
import ApplicationServices
import WindowOrganizerCore

// New windows go straight to their place (plan §3, slice S5): one AXObserver per running app reports kAXWindowCreated.
// Observers are attached at start and on launch and dropped on quit (the spike saw no close events when an app quits).

@MainActor
final class WindowWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let created: (AXUIElement, String, String?) -> Void

    /// `created` gets the new window's AX element, its app's name and its bundle ID.
    init(created: @escaping (AXUIElement, String, String?) -> Void) {
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
        let running = NSRunningApplication(processIdentifier: pid)
        created(element, running?.localizedName ?? "app", running?.bundleIdentifier)
    }
}

/// Moves one new window to its remembered place; nothing else moves. Nil when it has no place.
/// `recordUndo: false` keeps the Undo entries of the Restore that started the app.
@MainActor
func placeNew(_ element: AXUIElement, recordUndo: Bool = true, _ p: WorkspaceProviders = .live) -> (ApplyResult, desktop: Int?)? {
    if LayoutsWindow.shown?.dirty == true { return nil }
    guard let (report, listing, ctx) = try? guardedSnapshot(p),
          report.trusted, listing.warnings.isEmpty,
          let id = listing.elements.first(where: { CFEqual($0.value, element) })?.key,
          let layouts = try? p.store().load(),
          let plan = planRestore(layouts, windows: report.windows, screens: report.screens, desktops: ctx.desktops)
    else { return nil }
    let r = RestoreSession.shared.apply(onlyWindow(plan, id), listing: listing, context: ctx, mover: p.mover(listing), stillValid: { p.context() == ctx }, recordUndo: recordUndo)
    return (r, report.desktop?.number)
}

/// The menu line for a new window placed by `placeNew`; nil when it had no place (the menu keeps its line).
@MainActor
func placeNewWindow(_ element: AXUIElement, app: String, _ p: WorkspaceProviders = .live) -> String? {
    guard let (r, desktop) = placeNew(element, p) else { return nil }
    return ResultLine.newWindow(r, app: app, desktop: desktop, at: clock())
}
