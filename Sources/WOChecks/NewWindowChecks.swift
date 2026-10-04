import Foundation
import WindowOrganizerCore

// WO-S5 (plan §3 "new window of a known app"): a new window goes straight to its remembered place, and nothing else moves.

let newWindowChecks: [(String, @Sendable () throws -> Void)] = [
    ("only the new window's move is kept", {
        let a = Frame(x: 0, y: 40, width: 800, height: 600), b = Frame(x: 100, y: 100, width: 300, height: 200)
        let plan = Plan(moves: [Move(windowID: 1, from: a, to: b), Move(windowID: 2, from: b, to: a)],
                        skipped: [Matcher(bundleID: safari)], unchanged: 4)
        try expectEqual(onlyWindow(plan, 2), Plan(moves: [Move(windowID: 2, from: b, to: a)], skipped: [], unchanged: 0))
        try expectEqual(onlyWindow(plan, 9), Plan(moves: [], skipped: [], unchanged: 0))
    }),
    ("the second Terminal opened after one is placed takes the second remembered place", {
        var layouts = Layouts()
        let first = Frame(x: 10, y: 50, width: 700, height: 500), second = Frame(x: 720, y: 50, width: 700, height: 500)
        _ = rememberDesktop(&layouts, windows: [window(1, term, "a", 0, first), window(2, term, "b", 1, second)],
                            screens: [laptop], desktops: ["MBP": 1])
        let now = [window(5, term, "a", 0, first), window(6, term, "new", 1, Frame(x: 200, y: 200, width: 500, height: 400))]
        guard let plan = planRestore(layouts, windows: now, screens: [laptop], desktops: ["MBP": 1])
        else { throw CheckFailure(description: "no plan") }
        try expectEqual(onlyWindow(plan, 6).moves, [Move(windowID: 6, from: now[1].frame, to: second)])
    }),
    ("a created window is placed unless paused", {
        var t = TriggerState()
        try expectEqual(t.handle(.windowCreated), .placeWindow)
        t.paused = true
        try expectEqual(t.handle(.windowCreated), .none)
    }),
    ("new-window lines: placed, kept its minimum, could not be moved, nothing to say", {
        let r = { (p: Int, k: Int, f: Int) in ApplyResult(placed: p, keptMinimum: k, failed: f, unchanged: 0, notOpen: 0) }
        try expectEqual(ResultLine.newWindow(r(1, 0, 0), app: "Terminal", desktop: 2, at: "22:41"),
                        "Desktop 2: new Terminal window placed · 22:41")
        try expectEqual(ResultLine.newWindow(r(0, 1, 0), app: "Mail", desktop: 1, at: "22:41"),
                        "Desktop 1: new Mail window placed, it kept its minimum size · 22:41")
        try expectEqual(ResultLine.newWindow(r(0, 0, 1), app: "Mail", desktop: nil, at: "22:41"),
                        "Desktop unknown: new Mail window could not be moved · 22:41")
        try expectEqual(ResultLine.newWindow(r(0, 0, 0), app: "Mail", desktop: 1, at: "22:41"), nil)
    }),
]
