import Foundation
import WindowOrganizerCore

// WO-S3 (plan §3, §4): Remember this desktop and Restore. Remembering and planning are pure; applying goes through a
// WindowMover, here a fake that clamps like a real app with a minimum size or refuses like a stuck one.

/// Stands in for the AX mover: keeps frames by window ID, clamps to a minimum size, and can ignore the first set.
final class FakeMover: WindowMover, @unchecked Sendable {
    var frames: [Int: Frame]
    var minimum: [Int: (Double, Double)] = [:]
    var ignoreFirst: Set<Int> = []
    var stuck: Set<Int> = []
    var sets: [Int] = []

    init(_ windows: [WindowInfo]) {
        frames = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.frame) })
    }

    func frame(of id: Int) -> Frame? { frames[id] }

    func setFrame(_ f: Frame, of id: Int) {
        sets.append(id)
        if stuck.contains(id) { return }
        if ignoreFirst.remove(id) != nil { return }
        var f = f
        if let (w, h) = minimum[id] { f.width = max(f.width, w); f.height = max(f.height, h) }
        frames[id] = f
    }
}

let restoreChecks: [(String, @Sendable () throws -> Void)] = [
    ("each display's own current desktop number", {
        let displays = [DisplaySpaces(display: "MBP", current: 29, spaces: [1, 5, 29]),
                        DisplaySpaces(display: "DELL", current: 40, spaces: [40, 41]),
                        DisplaySpaces(display: "GONE", current: 99, spaces: [98])]
        try expectEqual(currentDesktops(displays), ["MBP": 3, "DELL": 1])
    }),
    ("remember: one snapshot per screen under that screen's desktop, others kept", {
        var layouts = Layouts()
        let setup = ScreenSetup(screens: [laptop, dell])
        let old = ScreenArrangement(kind: .snapshot([]))
        layouts.set(old, setup: setup, desktop: 1, screen: "MBP")
        let windows = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500)),
                       window(2, mail, "Inbox", 0, Frame(x: 1600, y: 40, width: 900, height: 700), on: dell)]
        let n = rememberDesktop(&layouts, windows: windows, screens: [laptop, dell], desktops: ["MBP": 3, "DELL": 2])
        try expectEqual(n, 2)
        try expectEqual(layouts.arrangement(setup: setup, desktop: 1, screen: "MBP"), old)
        guard case .snapshot(let mbp)? = layouts.arrangement(setup: setup, desktop: 3, screen: "MBP")?.kind,
              case .snapshot(let d)? = layouts.arrangement(setup: setup, desktop: 2, screen: "DELL")?.kind
        else { throw CheckFailure(description: "missing arrangement") }
        try expectEqual(mbp.map(\.matcher.bundleID), [term])
        try expectEqual(d.map(\.matcher.bundleID), [mail])
    }),
    ("remember skips a screen whose desktop is unknown", {
        var layouts = Layouts()
        let windows = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500))]
        try expectEqual(rememberDesktop(&layouts, windows: windows, screens: [laptop, dell], desktops: ["DELL": 1]), 0)
        try expectEqual(layouts.setups["DELL+MBP"]?["1"]?["MBP"], nil)
    }),
    ("restore: one matching pass over all screens, a window is never claimed twice", {
        var layouts = Layouts()
        // one Terminal on each screen remembered; now only one Terminal is open, on the Dell
        let before = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500)),
                      window(2, term, "b", 1, Frame(x: 1600, y: 40, width: 900, height: 700), on: dell)]
        let desktops = ["MBP": 1, "DELL": 1]
        _ = rememberDesktop(&layouts, windows: before, screens: [laptop, dell], desktops: desktops)
        let now = [window(7, term, "a", 0, Frame(x: 2000, y: 300, width: 500, height: 400), on: dell)]
        guard let plan = planRestore(layouts, windows: now, screens: [laptop, dell], desktops: desktops)
        else { throw CheckFailure(description: "no plan") }
        try expectEqual(plan.moves, [Move(windowID: 7, from: now[0].frame, to: before[0].frame)])
        try expectEqual(plan.skipped.count, 1)
    }),
    ("restore with nothing remembered for this desktop is nil", {
        try expect(planRestore(Layouts(), windows: [], screens: [laptop], desktops: ["MBP": 1]) == nil, "nil")
    }),
    ("apply: placed, retried once, kept its minimum size, failed", {
        let ws = (1...4).map { window($0, term, "w\($0)", $0 - 1, Frame(x: 0, y: 40, width: 800, height: 600)) }
        let target = Frame(x: 100, y: 100, width: 300, height: 200)
        let plan = Plan(moves: ws.map { Move(windowID: $0.windowID, from: $0.frame, to: target) },
                        skipped: [Matcher(bundleID: safari)], unchanged: 5)
        let mover = FakeMover(ws)
        mover.ignoreFirst = [2]
        mover.minimum = [3: (500, 400)]
        mover.stuck = [4]
        let r = applyPlan(plan, mover: mover)
        try expectEqual(r, ApplyResult(placed: 2, keptMinimum: 1, failed: 1, unchanged: 5, notOpen: 1))
        try expectEqual(mover.sets, [1, 2, 2, 3, 3, 4, 4])
        try expectEqual(mover.frames[3], Frame(x: 100, y: 100, width: 500, height: 400))
    }),
    ("result lines", {
        try expectEqual(ResultLine.restored(ApplyResult(placed: 9, keptMinimum: 1, failed: 0, unchanged: 5, notOpen: 1), desktop: 2, at: "23:59"),
                        "Desktop 2: 14 windows placed, 1 kept its minimum size, 1 not open · 23:59")
        try expectEqual(ResultLine.restored(ApplyResult(placed: 0, keptMinimum: 0, failed: 2, unchanged: 1, notOpen: 0), desktop: nil, at: "08:00"),
                        "Desktop unknown: 1 window placed, 2 could not be moved · 08:00")
        try expectEqual(ResultLine.restored(ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: 0, notOpen: 3), desktop: 4, at: "08:00"),
                        "Desktop 4: none of the 3 remembered windows is open · 08:00")
        try expectEqual(ResultLine.nothingRemembered(desktop: 2, at: "23:59"), "Desktop 2: nothing remembered yet · 23:59")
        try expectEqual(ResultLine.remembered(windows: 14, screens: 2, desktop: 2, at: "23:58"),
                        "Desktop 2: remembered 14 windows on 2 screens · 23:58")
        try expectEqual(ResultLine.remembered(windows: 1, screens: 1, desktop: 3, at: "23:58"),
                        "Desktop 3: remembered 1 window on 1 screen · 23:58")
    }),
    ("the Restore shortcut is ⌃⌥⌘R", {
        try expectEqual(Shortcut.restore.display, "⌃⌥⌘R")
        try expectEqual(Shortcut.restore.key, "r")
    }),
    ("layouts live in Application Support unless WO_STATE_DIR says otherwise", {
        let home = URL(fileURLWithPath: "/Users/x")
        try expectEqual(stateDirectory(environment: [:], home: home).path, "/Users/x/Library/Application Support/WindowOrganizerGPTReview")
        try expectEqual(stateDirectory(environment: ["WO_STATE_DIR": "/tmp/wo"], home: home).path, "/tmp/wo")
    }),
]
