import Foundation

// Remember this desktop and Restore (plan §3, §4, slice S3). Pure: the app hands in what AX, NSScreen and SkyLight see,
// and moves windows through a WindowMover.

/// Screen UUID → that display's own current desktop number. With "Displays have separate Spaces" each display has its own.
public func currentDesktops(_ displays: [DisplaySpaces]) -> [String: Int] {
    var out: [String: Int] = [:]
    for d in displays {
        if let i = d.spaces.firstIndex(of: d.current) { out[d.display] = i + 1 }
    }
    return out
}

/// Stores one snapshot per screen under the current setup, that screen's desktop and the screen. A screen whose desktop is
/// unknown is skipped, and so is one with zones (drawn in the editor, never overwritten by a snapshot); every other
/// arrangement stays as it was. Returns the number of windows remembered.
public func rememberDesktop(_ layouts: inout Layouts, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) -> Int {
    let setup = ScreenSetup(screens: screens)
    var count = 0
    for screen in screens {
        guard let desktop = desktops[screen.uuid] else { continue }
        if let kind = layouts.arrangement(setup: setup, desktop: desktop, screen: screen.uuid)?.kind {
            switch kind { case .zones, .autoTile: continue; case .snapshot: break }
        }
        let arrangement = remember(windows, on: screen)
        if case .snapshot(let places) = arrangement.kind { count += places.count }
        layouts.set(arrangement, setup: setup, desktop: desktop, screen: screen.uuid)
    }
    return count
}

/// The moves that put the current desktop back as remembered, nil when nothing is remembered for it.
/// All screens' places are matched in one pass, so a window is never claimed by two screens. Zones then take the
/// windows no place claimed, screen by screen and zone by zone, and tile them.
public func planRestore(_ layouts: Layouts, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int], scope: WorkspaceSelection? = nil) -> Plan? {
    let setup = ScreenSetup(screens: screens)
    let eligibleScreens = scope.map { selected in screens.filter { $0.uuid == selected.screenUUID && desktops[$0.uuid] == selected.desktop } } ?? screens
    let windows = scope.map { selected in windows.filter { $0.screenUUID == selected.screenUUID } } ?? windows
    var places: [(Placement, ScreenInfo)] = []
    var zoned: [(Zone, ScreenInfo)] = []
    var automatic: [ScreenInfo] = []
    var found = false
    for screen in eligibleScreens {
        guard let desktop = desktops[screen.uuid],
              let arrangement = layouts.arrangement(setup: setup, desktop: desktop, screen: screen.uuid) else { continue }
        found = true
        switch arrangement.kind {
        case .snapshot(let ps): places += ps.map { ($0, screen) }
        case .zones(let zs): zoned += zs.map { ($0, screen) }
        case .autoTile: automatic.append(screen)
        }
    }
    // App rules win (plan §1): an active rule's app leaves the snapshot and the zones to the rule.
    let active = layouts.rules.compactMap { rule in
        eligibleScreens.first { $0.uuid == rule.screen && desktops[$0.uuid] == rule.desktop }.map { (rule, $0) }
    }
    guard found || !active.isEmpty else { return nil }
    let ruled = Set(active.map(\.0.bundleID))
    places.removeAll { ruled.contains($0.0.matcher.bundleID) }
    let free = windows.filter { !ruled.contains($0.bundleID) }
    let match = matchWindows(places.map(\.0.matcher), free)
    var plan = Plan(moves: [], skipped: [], unchanged: 0)
    // Every (window, target) pair is collected first, so the gap can be applied per screen before anything is compared.
    var wanted: [(screen: String, window: WindowInfo, target: Frame)] = []
    let areas = Dictionary(screens.map { ($0.uuid, $0.visibleFrame) }, uniquingKeysWith: { a, _ in a })
    for ((place, screen), window) in zip(places, match.assigned) {
        guard let w = window else { plan.skipped.append(place.matcher); continue }
        let exact = place.screenUUID == screen.uuid && place.visibleFrame == screen.visibleFrame
        wanted.append((screen.uuid, w, exact ? place.pixel : place.fraction.frame(in: screen.visibleFrame).contained(in: screen.visibleFrame)))
    }
    var claimed = Set(match.assigned.compactMap { $0?.windowID })
    func group(_ ws: [WindowInfo], in area: Frame, on screen: ScreenInfo) {
        guard !ws.isEmpty else { return }
        plan.tiles.append(ws.map(\.windowID))
        for (w, target) in zip(ws, tile(ws.count, in: area)) { wanted.append((screen.uuid, w, target)) }
    }
    for (zone, screen) in zoned {
        var mine: [WindowInfo] = []
        for member in zone.members {
            let taken = free.filter { !claimed.contains($0.windowID) && member.matches($0) }.sorted { $0.order < $1.order }
            mine += taken
            claimed.formUnion(taken.map(\.windowID))
        }
        group(mine, in: zone.rect.frame(in: screen.visibleFrame), on: screen)
    }
    for screen in automatic {
        let settings = desktops[screen.uuid].map { layouts.arrangeSettings(desktop: $0, screen: screen.uuid) } ?? ArrangeSettings()
        let mine = arrangeOrder(free.filter { $0.screenUUID == screen.uuid && !claimed.contains($0.windowID) }
            .sorted { ($0.bundleID, $0.order, $0.windowID) < ($1.bundleID, $1.order, $1.windowID) }, settings: settings)
        claimed.formUnion(mine.map(\.windowID))
        plan.tiles.append(mine.map(\.windowID))
        for (w, target) in zip(mine, gridTile(mine.count, in: screen.visibleFrame)) { wanted.append((screen.uuid, w, target)) }
    }
    for (rule, screen) in active {
        group(windows.filter { $0.bundleID == rule.bundleID }.sorted { $0.order < $1.order }, in: rule.area.frame(in: screen.visibleFrame), on: screen)
    }
    // The gap goes between windows of one screen only, using that desktop's setting; a screen without room keeps none.
    var gapped = Dictionary(uniqueKeysWithValues: wanted.indices.map { ($0, wanted[$0].target) })
    for screen in Set(wanted.map(\.screen)) {
        guard let desktop = desktops[screen] else { continue }
        let gap = layouts.arrangeSettings(desktop: desktop, screen: screen).gapPoints
        let indices = wanted.indices.filter { wanted[$0].screen == screen }
        let result = applyGap(indices.map { wanted[$0].target }, gap: gap)
        if result.skipped { plan.gapSkipped = true }
        for (i, frame) in zip(indices, result.frames) { gapped[i] = frame }
    }
    for i in wanted.indices {
        let w = wanted[i].window, target = gapped[i] ?? wanted[i].target
        if close(w.frame, target) { plan.unchanged += 1 }
        else { plan.moves.append(Move(windowID: w.windowID, from: w.frame, to: target, area: areas[wanted[i].screen])) }
    }
    return plan
}

/// Splits a zone along its longer side into n equal parts. Edges are rounded once, so neighbours share them: no gap.
public func tile(_ n: Int, in area: Frame) -> [Frame] { tile(n, in: area, across: area.width >= area.height) }

/// The same, along a chosen direction (the Columns and Rows presets).
public func tile(_ n: Int, in area: Frame, across: Bool) -> [Frame] {
    guard n > 0, area.isValid else { return [] }
    let start = across ? area.x : area.y, length = across ? area.width : area.height
    let edges = (0...n).map { i in i == n ? start + length : (start + Double(i) * length / Double(n)).rounded() }
    return (0..<n).map { i in
        across ? Frame(x: edges[i], y: area.y, width: edges[i + 1] - edges[i], height: area.height)
               : Frame(x: area.x, y: edges[i], width: area.width, height: edges[i + 1] - edges[i])
    }
}

/// How many of the current desktop's screens have zones (kept by Remember this desktop).
public func zoneScreens(_ layouts: Layouts, screens: [ScreenInfo], desktops: [String: Int]) -> Int {
    let setup = ScreenSetup(screens: screens)
    return screens.filter { s in
        guard let d = desktops[s.uuid], case .zones? = layouts.arrangement(setup: setup, desktop: d, screen: s.uuid)?.kind
        else { return false }
        return true
    }.count
}

/// A new window goes to its place and nothing else moves (plan §3): the desktop's plan cut down to that one window,
/// or, in a zone, to that zone, which re-tiles with the new window in it.
public func onlyWindow(_ plan: Plan, _ id: Int) -> Plan {
    let group = Set(plan.tiles.first { $0.contains(id) } ?? [id])
    return Plan(moves: plan.moves.filter { group.contains($0.windowID) }, skipped: [], unchanged: 0)
}

/// Moves windows. The app's is Accessibility; the checks use a fake.
public protocol WindowMover {
    func frame(of id: Int) -> Frame?
    func setFrame(_ frame: Frame, of id: Int)
}

public struct ApplyResult: Equatable, Sendable {
    public var placed: Int
    /// The app kept a larger minimum size; the window is where it belongs, only bigger.
    public var keptMinimum: Int
    public var failed: Int
    public var unchanged: Int
    public var notOpen: Int
    /// Moves not made because the desktop or screen changed while the plan ran.
    public var cancelled: Int
    /// Windows that kept a larger size and were moved back inside their screen (they overlap a neighbour); also counted in keptMinimum.
    public var shiftedIDs: [Int]

    public init(placed: Int, keptMinimum: Int, failed: Int, unchanged: Int, notOpen: Int, cancelled: Int = 0, shiftedIDs: [Int] = []) {
        self.placed = placed; self.keptMinimum = keptMinimum; self.failed = failed
        self.unchanged = unchanged; self.notOpen = notOpen; self.cancelled = cancelled; self.shiftedIDs = shiftedIDs
    }
}

/// Set, read back, one retry (plan §3). A window at its place but larger counts as "kept its minimum size".
/// With a move `area` (WO-OFFSCREEN) the target is first clamped into it, and a window that stayed larger than its tile, or whose
/// origin the app moved, is set once more where it lies inside the area: it overlaps a neighbour on its own screen instead of
/// spilling onto the next one. Only a window bigger than the whole screen stays out, and that counts as failed.
/// `stillValid` is asked before each move; on the first false no further window is touched and the rest count as cancelled.
public func applyPlan(_ plan: Plan, mover: WindowMover, stillValid: () -> Bool = { true }) -> ApplyResult {
    var r = ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: plan.skipped.count)
    for (index, move) in plan.moves.enumerated() {
        guard stillValid() else { r.cancelled = plan.moves.count - index; break }
        guard move.to.isValid else { r.failed += 1; continue }
        let area = move.area.flatMap { $0.isValid ? $0 : nil }
        let to = area.map { move.to.contained(in: $0) } ?? move.to
        mover.setFrame(to, of: move.windowID)
        var now = mover.frame(of: move.windowID)
        if let f = now, close(f, to) { r.placed += 1; continue }
        mover.setFrame(to, of: move.windowID)
        now = mover.frame(of: move.windowID)
        guard let f = now else { r.failed += 1; continue }
        if close(f, to) { r.placed += 1; continue }
        let atLeastTile = f.width >= to.width - 1 && f.height >= to.height - 1
        let sameOrigin = abs(f.x - to.x) <= 1 && abs(f.y - to.y) <= 1
        guard atLeastTile else { r.failed += 1; continue }
        guard let area else {
            if sameOrigin { r.keptMinimum += 1 } else { r.failed += 1 }
            continue
        }
        let fitted = Frame(x: to.x, y: to.y, width: f.width, height: f.height).contained(in: area)
        if close(fitted, f) { if sameOrigin { r.keptMinimum += 1 } else { r.failed += 1 }; continue }
        mover.setFrame(fitted, of: move.windowID)
        if let g = mover.frame(of: move.windowID), g.isInside(area) { r.keptMinimum += 1; r.shiftedIDs.append(move.windowID) }
        else { r.failed += 1 }
    }
    return r
}

/// The app names of the windows `applyPlan` had to move inside their screen, once each, in order.
public func shiftedApps(_ r: ApplyResult, in windows: [WindowInfo]) -> [String] {
    var names: [String] = []
    for id in r.shiftedIDs {
        guard let w = windows.first(where: { $0.windowID == id }) else { continue }
        let name = w.appName ?? w.bundleID
        if !names.contains(name) { names.append(name) }
    }
    return names
}

/// The menu's last-result line (plan §4): what happened, on which desktop, when.
public enum ResultLine {
    public static func restored(_ r: ApplyResult, starting: [String] = [], shifted: [String] = [], desktop: Int?, at time: String) -> String {
        if r.cancelled > 0 { return "Stopped: the desktop changed. Placed \(r.placed + r.keptMinimum), \(r.cancelled) left as they were · \(time)" }
        let inPlace = r.placed + r.unchanged
        var parts: [String] = []
        if inPlace == 0 && r.keptMinimum == 0 && r.failed == 0 {
            parts.append(r.notOpen == 0 ? "nothing to place"
                         : "none of the \(r.notOpen) remembered \(r.notOpen == 1 ? "window is" : "windows is") open")
        } else {
            parts.append("\(plural(inPlace, "window")) placed")
            let moved = min(r.shiftedIDs.count, r.keptMinimum), plain = r.keptMinimum - moved
            if plain > 0 { parts.append("\(plain) kept \(plain == 1 ? "its" : "their") minimum size") }
            if moved > 0 {
                let names = shifted.isEmpty ? "" : ": \(shifted.joined(separator: ", "))"
                parts.append("\(moved) kept \(moved == 1 ? "its minimum size and was" : "their minimum size and were") moved inside the screen\(names)")
            }
            if r.failed > 0 { parts.append("\(r.failed) could not be moved") }
            if r.notOpen > 0 { parts.append("\(r.notOpen) not open") }
        }
        if !starting.isEmpty { parts.append("starting \(starting.joined(separator: ", "))") }
        return "\(name(desktop)): \(parts.joined(separator: ", ")) · \(time)"
    }

    /// The final line of a start-missing-apps batch (WO-LAUNCH-MISSING).
    public static func started(names: [String], placed: Int, late: [String] = [], failed: [String] = [], stopped: Bool = false,
                               desktop: Int?, at time: String) -> String {
        var parts: [String] = []
        if !names.isEmpty { parts.append("started \(list(names)), \(plural(placed, "window")) placed") }
        parts += late.map { "\($0) did not open a window within 20 s" }
        parts += failed.map { "\($0) could not be started" }
        if stopped { parts.append("stopped placing: the desktop changed") }
        if parts.isEmpty { parts.append("nothing started") }
        return "\(name(desktop)): \(parts.joined(separator: "; ")) · \(time)"
    }

    /// After a new window was placed; nil when it had no place to go (then the menu keeps its line).
    public static func newWindow(_ r: ApplyResult, app: String, desktop: Int?, at time: String) -> String? {
        if r.cancelled > 0 { return "Stopped: the desktop changed. New \(app) window left as it was · \(time)" }
        let what: String
        if r.placed > 0 { what = "placed" }
        else if !r.shiftedIDs.isEmpty { what = "placed, it kept its minimum size and was moved inside the screen" }
        else if r.keptMinimum > 0 { what = "placed, it kept its minimum size" }
        else if r.failed > 0 { what = "could not be moved" }
        else { return nil }
        return "\(name(desktop)): new \(app) window \(what) · \(time)"
    }

    public static func nothingRemembered(desktop: Int?, at time: String) -> String {
        "\(name(desktop)): nothing remembered yet · \(time)"
    }

    public static func remembered(windows: Int, screens: Int, keptZones: Int = 0, desktop: Int?, at time: String) -> String {
        let kept = keptZones == 0 ? "" : ", \(plural(keptZones, "screen")) \(keptZones == 1 ? "keeps its" : "keep their") zones"
        return "\(name(desktop)): remembered \(plural(windows, "window")) on \(plural(screens, "screen"))\(kept) · \(time)"
    }

    private static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
    private static func name(_ desktop: Int?) -> String { desktop.map { "Desktop \($0)" } ?? "Desktop unknown" }
    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// The global Restore shortcut. Fixed in S3; Settings makes it editable later.
public struct Shortcut: Equatable, Sendable {
    public var key: String
    public var display: String

    public init(key: String, display: String) { self.key = key; self.display = display }

    public static let restore = Shortcut(key: "r", display: "⌃⌥⌘R")
}

/// Where layouts.json lives (plan §1). WO_STATE_DIR points a live check at a throwaway folder.
public func stateDirectory(environment: [String: String], home: URL) -> URL {
    if let dir = environment["WO_STATE_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
    return home.appendingPathComponent("Library/Application Support/WindowOrganizer")
}
