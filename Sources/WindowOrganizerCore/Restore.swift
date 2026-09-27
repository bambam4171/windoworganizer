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
/// unknown is skipped; every other arrangement stays as it was. Returns the number of windows remembered.
public func rememberDesktop(_ layouts: inout Layouts, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) -> Int {
    let setup = ScreenSetup(screens: screens)
    var count = 0
    for screen in screens {
        guard let desktop = desktops[screen.uuid] else { continue }
        let arrangement = remember(windows, on: screen)
        if case .snapshot(let places) = arrangement.kind { count += places.count }
        layouts.set(arrangement, setup: setup, desktop: desktop, screen: screen.uuid)
    }
    return count
}

/// The moves that put the current desktop back as remembered, nil when nothing is remembered for it.
/// All screens' places are matched in one pass, so a window is never claimed by two screens.
public func planRestore(_ layouts: Layouts, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) -> Plan? {
    let setup = ScreenSetup(screens: screens)
    var places: [(Placement, ScreenInfo)] = []
    var found = false
    for screen in screens {
        guard let desktop = desktops[screen.uuid],
              let arrangement = layouts.arrangement(setup: setup, desktop: desktop, screen: screen.uuid) else { continue }
        found = true
        if case .snapshot(let ps) = arrangement.kind { places += ps.map { ($0, screen) } }
    }
    guard found else { return nil }
    let match = matchWindows(places.map(\.0.matcher), windows)
    var plan = Plan(moves: [], skipped: [], unchanged: 0)
    for ((place, screen), window) in zip(places, match.assigned) {
        guard let w = window else { plan.skipped.append(place.matcher); continue }
        let exact = place.screenUUID == screen.uuid && place.visibleFrame == screen.visibleFrame
        let target = exact ? place.pixel : place.fraction.frame(in: screen.visibleFrame)
        if close(w.frame, target) { plan.unchanged += 1 }
        else { plan.moves.append(Move(windowID: w.windowID, from: w.frame, to: target)) }
    }
    return plan
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

    public init(placed: Int, keptMinimum: Int, failed: Int, unchanged: Int, notOpen: Int) {
        self.placed = placed; self.keptMinimum = keptMinimum; self.failed = failed
        self.unchanged = unchanged; self.notOpen = notOpen
    }
}

/// Set, read back, one retry (plan §3). A window at its place but larger counts as "kept its minimum size".
public func applyPlan(_ plan: Plan, mover: WindowMover) -> ApplyResult {
    var r = ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: plan.skipped.count)
    for move in plan.moves {
        mover.setFrame(move.to, of: move.windowID)
        var now = mover.frame(of: move.windowID)
        if let f = now, close(f, move.to) { r.placed += 1; continue }
        mover.setFrame(move.to, of: move.windowID)
        now = mover.frame(of: move.windowID)
        guard let f = now else { r.failed += 1; continue }
        if close(f, move.to) { r.placed += 1 }
        else if abs(f.x - move.to.x) <= 1, abs(f.y - move.to.y) <= 1,
                f.width >= move.to.width - 1, f.height >= move.to.height - 1 { r.keptMinimum += 1 }
        else { r.failed += 1 }
    }
    return r
}

/// The menu's last-result line (plan §4): what happened, on which desktop, when.
public enum ResultLine {
    public static func restored(_ r: ApplyResult, desktop: Int?, at time: String) -> String {
        let inPlace = r.placed + r.unchanged
        var parts: [String] = []
        if inPlace == 0 && r.keptMinimum == 0 && r.failed == 0 {
            parts.append(r.notOpen == 0 ? "nothing to place"
                         : "none of the \(r.notOpen) remembered \(r.notOpen == 1 ? "window is" : "windows is") open")
        } else {
            parts.append("\(plural(inPlace, "window")) placed")
            if r.keptMinimum > 0 { parts.append("\(r.keptMinimum) kept \(r.keptMinimum == 1 ? "its" : "their") minimum size") }
            if r.failed > 0 { parts.append("\(r.failed) could not be moved") }
            if r.notOpen > 0 { parts.append("\(r.notOpen) not open") }
        }
        return "\(name(desktop)): \(parts.joined(separator: ", ")) · \(time)"
    }

    public static func nothingRemembered(desktop: Int?, at time: String) -> String {
        "\(name(desktop)): nothing remembered yet · \(time)"
    }

    public static func remembered(windows: Int, screens: Int, desktop: Int?, at time: String) -> String {
        "\(name(desktop)): remembered \(plural(windows, "window")) on \(plural(screens, "screen")) · \(time)"
    }

    private static func name(_ desktop: Int?) -> String { desktop.map { "Desktop \($0)" } ?? "Desktop unknown" }
    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// The global Restore shortcut. Fixed in S3; Settings makes it editable later.
public struct Shortcut: Equatable, Sendable {
    public var key: String
    public var display: String

    public static let restore = Shortcut(key: "r", display: "⌃⌥⌘R")
}

/// Where layouts.json lives (plan §1). WO_STATE_DIR points a live check at a throwaway folder.
public func stateDirectory(environment: [String: String], home: URL) -> URL {
    if let dir = environment["WO_STATE_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
    return home.appendingPathComponent("Library/Application Support/WindowOrganizer")
}
