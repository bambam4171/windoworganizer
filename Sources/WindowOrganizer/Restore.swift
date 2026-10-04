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
        guard f.isValid, let e = elements[id] else { return }
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
    let displays = SkyLight.displaySpaces(mainUUID: screens.first?.uuid, screenUUIDs: screens.map(\.uuid))
    let numbers = currentDesktops(displays)
    // Explicit manual fallback uses its own key, never overwriting Desktop 1.
    return displays.isEmpty ? Dictionary(uniqueKeysWithValues: screens.map { ($0.uuid, 0) }) : numbers
}

/// Everything an action reads or writes outside the process, in one place so a check can inject all of it.
@MainActor
struct WorkspaceProviders {
    var context: () -> WorkspaceContext = { WorkspaceContext.live() }
    var snapshot: () -> (ListReport, Listing) = { WindowOrganizer.snapshot() }
    var mover: (Listing) -> WindowMover = { AXMover(elements: $0.elements) }
    var store: () -> LayoutStore = { layoutStore() }
    var running: () -> Set<String> = { liveRunning() }
    var launch: (String, @escaping @MainActor (LaunchOutcome) -> Void) -> Void = { liveLaunch($0, $1) }
    var appName: (String) -> String = { liveAppName($0) }
    static var live: WorkspaceProviders { WorkspaceProviders() }
}

let desktopChangedText = "The desktop or screen changed. Try again after the switch finishes."

/// The one guarded read for every action: the context before, the snapshot, and the context again. A difference means
/// the user switched desktop or screen meanwhile, and nothing may be planned or saved from this read.
/// `before` and `after` let the editor add its own checks in between.
@MainActor
func guardedSnapshot(_ p: WorkspaceProviders = .live,
                     before check: (WorkspaceContext) throws -> Void = { _ in },
                     after verify: (ListReport, Listing) throws -> Void = { _, _ in }) throws -> (ListReport, Listing, WorkspaceContext) {
    let before = p.context()
    try check(before)
    let (report, listing) = p.snapshot()
    try verify(report, listing)
    guard report.screens == before.screens, p.context() == before else { throw WorkspaceActionError(message: desktopChangedText) }
    return (report, listing, before)
}

/// "Remember this desktop": one snapshot per screen, saved at once. Returns the menu's result line.
@MainActor
func rememberNow(_ p: WorkspaceProviders = .live) -> String {
    do {
        let (report, listing, ctx) = try guardedSnapshot(p)
        guard report.trusted else { return StatusLine.text(trusted: false, desktop: nil, windows: 0, screens: 0) }
        guard listing.warnings.isEmpty else { return "Not remembered: " + listing.warnings.joined(separator: " ") }
        guard ctx.isIdentified else { return "Not remembered: this Space is fullscreen or could not be identified." }
        let desktops = ctx.desktops
        let store = p.store()
        var layouts = try store.load()
        let kept = zoneScreens(layouts, screens: report.screens, desktops: desktops)
        let auto = report.screens.filter { screen in
            guard let d = desktops[screen.uuid], case .autoTile? = layouts.arrangement(setup: ScreenSetup(screens: report.screens), desktop: d, screen: screen.uuid)?.kind else { return false }
            return true
        }.count
        let n = rememberDesktop(&layouts, windows: report.windows, screens: report.screens, desktops: desktops)
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard p.context() == ctx else { return "Not remembered: the desktop changed. Try again after the switch finishes." }
        try store.save(layouts)
        let screens = report.screens.filter { desktops[$0.uuid] != nil }.count - kept - auto
        return ResultLine.remembered(windows: n, screens: screens, keptZones: kept, desktop: report.desktop?.number, at: clock()) + (auto == 0 ? "" : ", \(auto) screen(s) keep automatic tiling")
    } catch {
        return "Not remembered: \(error)"
    }
}

/// The groups applied in this session (WO-GROUPS-G3). Memory only: a restart arranges from the stored layouts.
@MainActor
enum GroupState { static var session = GroupSession() }

/// The "Groups" submenu (WO-GROUPS-G3): nil without groups, a disabled reason per group that cannot apply,
/// a check on the group applied last on a visible desktop.
@MainActor
func groupsMenuItem(layouts: Layouts, screens: [ScreenInfo], desktops: [String: Int], trusted: Bool, session: GroupSession,
                    target: AnyObject, action: Selector) -> NSMenuItem? {
    guard !layouts.groups.isEmpty else { return nil }
    let sub = NSMenu(); sub.autoenablesItems = false
    let checked = Set(desktops.compactMap { session.last(GroupKey(screen: $0.key, desktop: $0.value), layouts: layouts)?.id })
    for g in layouts.groups {
        let reason = !g.isAssigned ? "Not assigned" : (screens.contains { $0.uuid == g.screen } ? nil : "Display not connected")
        let entry = NSMenuItem(title: reason.map { "\(g.name) · \($0)" } ?? g.name, action: reason == nil ? action : nil, keyEquivalent: "")
        entry.target = target; entry.representedObject = g.id; entry.isEnabled = reason == nil && trusted
        entry.state = checked.contains(g.id) ? .on : .off
        sub.addItem(entry)
    }
    let parent = NSMenuItem(title: "Groups", action: nil, keyEquivalent: ""); parent.submenu = sub
    return parent
}

/// A group chosen in the menu, or a pending desktop visited: places the group's windows through the same seam as Restore.
/// `only` limits the apply to one key (a visit), otherwise the group goes on every visible desktop it is assigned to.
@MainActor
func applyGroupNow(_ id: String, only key: GroupKey? = nil, _ p: WorkspaceProviders = .live) -> String? {
    do {
        let (report, listing, ctx) = try guardedSnapshot(p)
        guard report.trusted else { return StatusLine.text(trusted: false, desktop: nil, windows: 0, screens: 0) }
        guard listing.warnings.isEmpty else { return "Not placed: " + listing.warnings.joined(separator: " ") }
        let layouts = try p.store().load()
        guard let g = layouts.group(id: id), g.isAssigned, let screen = g.screen, report.screens.contains(where: { $0.uuid == screen }) else {
            return "Group could not be applied: it is not assigned or its display is not connected."
        }
        let desktop = ctx.desktops[screen] ?? report.desktop?.number
        let later: [Int]
        let visible: Int?
        if let key {
            visible = key.desktop; later = []
        } else {
            let r = GroupState.session.apply(g, desktops: ctx.desktops)
            visible = r.now?.desktop; later = r.later.map(\.desktop).sorted()
        }
        guard let visible else { return ResultLine.group(g.name, nil, later: later, desktop: desktop, at: clock()) }
        let plan = planArrange(layouts, session: GroupState.session, windows: report.windows, screens: report.screens, desktops: ctx.desktops,
                               scope: WorkspaceSelection(screenUUID: screen, desktop: visible))
        guard let plan else { return ResultLine.group(g.name, ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: 0, notOpen: 0), later: later, desktop: desktop, at: clock()) }
        let applied = RestoreSession.shared.apply(plan, listing: listing, context: ctx, mover: p.mover(listing), stillValid: { p.context() == ctx })
        return ResultLine.group(g.name, applied, later: later, desktop: desktop, at: clock())
    } catch {
        return "Not placed: \(error)"
    }
}

/// Visiting a desktop where a group waits: applies it for that key only, never while paused.
@MainActor
func applyPendingGroups(paused: Bool, _ p: WorkspaceProviders = .live) -> String? {
    guard !paused, !GroupState.session.pending.isEmpty else { return nil }
    let ctx = p.context()
    var line: String?
    for (uuid, desktop) in ctx.desktops.sorted(by: { $0.key < $1.key }) {
        let key = GroupKey(screen: uuid, desktop: desktop)
        guard GroupState.session.visited(key) else { continue }
        let layouts = try? p.store().load()
        guard let layouts, let g = GroupState.session.last(key, layouts: layouts) else { continue }
        if let l = applyGroupNow(g.id, only: key, p) { line = l }
    }
    return line
}

/// "Restore": puts this desktop's windows back where they were remembered. Returns the menu's result line.
/// An automatic arrange (a trigger, not the menu) stays quiet when there is no permission or nothing remembered: nil,
/// and never moves windows under a canvas preview the editor has not applied.
@MainActor
func restoreNow(automatic: Bool = false, launch: LaunchTrigger? = nil, _ p: WorkspaceProviders = .live) -> String? {
    if automatic && LayoutsWindow.shown?.dirty == true { return nil }
    do {
        let (report, listing, ctx) = try guardedSnapshot(p)
        guard report.trusted else { return automatic ? nil : StatusLine.text(trusted: false, desktop: nil, windows: 0, screens: 0) }
        let desktop = report.desktop?.number
        guard listing.warnings.isEmpty else { return "Not restored: " + listing.warnings.joined(separator: " ") }
        if automatic && !ctx.isIdentified { return nil }
        let layouts = try p.store().load()
        let plan = planArrange(layouts, session: GroupState.session, windows: report.windows, screens: report.screens, desktops: ctx.desktops)
        // Started after the arrangement is read, so the batch places the new windows; its context is this one.
        let starting = startMissingApps(launch, layouts: layouts, report: report, desktops: ctx.desktops, p)
        guard let plan else {
            if !starting.isEmpty { return ResultLine.restored(ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: 0, notOpen: 0), starting: starting, desktop: desktop, at: clock()) }
            return automatic ? nil : ResultLine.nothingRemembered(desktop: desktop, at: clock())
        }
        let applied = RestoreSession.shared.apply(plan, listing: listing, context: ctx, mover: p.mover(listing), stillValid: { p.context() == ctx })
        return ResultLine.restored(applied, starting: starting, shifted: shiftedApps(applied, in: report.windows), desktop: desktop, at: clock())
    } catch {
        return "Not restored: \(error)"
    }
}


/// Undo is session-only and tied to the same displays, desktops, AX identities and post-move frames.
/// A window changed by the user after arranging is left alone.
@MainActor
final class RestoreSession {
    static let shared = RestoreSession()
    private var entries: [(Move, AXUIElement, Frame)] = []
    private var setup = ""
    private var desktops: [String: Int] = [:]
    var canUndo: Bool { !entries.isEmpty }
    func apply(_ plan: Plan, listing: Listing, context: WorkspaceContext, mover: WindowMover? = nil, stillValid: (() -> Bool)? = nil, recordUndo: Bool = true) -> ApplyResult {
        let mover = mover ?? AXMover(elements: listing.elements)
        let result = applyPlan(plan, mover: mover, stillValid: stillValid ?? { WorkspaceContext.live() == context })
        let changed = plan.moves.compactMap { move -> (Move, AXUIElement, Frame)? in
            guard let element = listing.elements[move.windowID], let after = axFrame(element), after != move.from else { return nil }
            return (move, element, after)
        }
        if recordUndo, !changed.isEmpty {
            entries = changed; setup = ScreenSetup(screens: context.screens).key; desktops = context.desktops
        }
        return result
    }
    func undo() -> String {
        let (report, listing) = snapshot()
        guard report.trusted, ScreenSetup(screens: report.screens).key == setup,
              desktopNumbers(screens: report.screens) == desktops else { return "Undo is available on the original desktop and screen setup." }
        let moves = entries.compactMap { move, element, after -> Move? in
            guard let live = listing.elements[move.windowID], CFEqual(live, element), axFrame(live) == after else { return nil }
            return Move(windowID: move.windowID, from: after, to: move.from)
        }
        let r = applyPlan(Plan(moves: moves, skipped: [], unchanged: 0), mover: AXMover(elements: listing.elements))
        let skipped = entries.count - moves.count
        entries = []
        return "Undo: \(r.placed + r.keptMinimum) restored, \(r.failed) failed, \(skipped) changed or unavailable · \(clock())"
    }
}

@MainActor
enum HotKey {
    static var action: (() -> Void)?
    static var ref: EventHotKeyRef?
    static var handler: EventHandlerRef?
    static let keyCodes: [String: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V,
        "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z]
    @discardableResult
    static func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        guard let code = keyCodes[shortcut.key] else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.action?() }; return noErr
            }, 1, &spec, nil, &handler) == noErr else { return false }
        }
        let id = EventHotKeyID(signature: OSType(0x574F5247), id: 1)
        var next: EventHotKeyRef?
        // Acquire the replacement before releasing the old shortcut; a collision leaves the working shortcut intact.
        guard RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey | cmdKey), id,
                                  GetApplicationEventTarget(), 0, &next) == noErr else { return false }
        if let ref { UnregisterEventHotKey(ref) }
        ref = next; self.action = action
        return true
    }
    static func stop() {
        if let ref { UnregisterEventHotKey(ref) }; ref = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        action = nil
    }
}
