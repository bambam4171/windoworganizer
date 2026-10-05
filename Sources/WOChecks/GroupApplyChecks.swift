import Foundation
import WindowOrganizerCore

// WO-GROUPS G3: apply a group. The last applied group decides a shared window; nothing crosses screens or desktops.

private let anywhere = Frame(x: 900, y: 300, width: 400, height: 300)
private func grp(_ id: String, _ name: String, _ apps: [String], screen: String = "MBP", desktops: [Int] = [1], mode: GroupMode = .tiled) -> WindowGroup {
    WindowGroup(id: id, name: name, members: apps.map { ZoneMember(bundleID: $0) }, screen: screen, desktops: desktops, mode: mode)
}
private func layouts(_ gs: [WindowGroup]) -> Layouts { var l = Layouts(); for g in gs { l.setGroup(g) }; return l }
private func session(_ gs: [WindowGroup], desktops: [String: Int] = ["MBP": 1]) -> GroupSession {
    var s = GroupSession(); for g in gs { s.apply(g, desktops: desktops) }; return s
}
private func arrange(_ l: Layouts, _ s: GroupSession, _ ws: [WindowInfo], screens: [ScreenInfo] = [laptop], desktops: [String: Int] = ["MBP": 1]) -> Plan? {
    planArrange(l, session: s, windows: ws, screens: screens, desktops: desktops)
}
private func target(_ p: Plan?, _ id: Int) -> Frame? { p?.moves.first { $0.windowID == id }?.to }

let groupApplyChecks: [(String, @Sendable () throws -> Void)] = [
    ("group apply 1: the group applied last places a shared window, and applying the other again moves it back", {
        let a = grp("a", "A", [safari, term]), b = grp("b", "B", [safari])
        let l = layouts([a, b])
        let ws = [window(1, safari, "s", 0, anywhere), window(2, term, "t", 0, anywhere)]
        let ab = arrange(l, session([a, b]), ws)
        // B (last) takes Safari alone and fills the screen, A tiles Terminal alone and fills it too
        try expectEqual(target(ab, 1), laptop.visibleFrame)
        let ba = arrange(l, session([b, a]), ws)
        // A is last now: it claims both windows and tiles them in two
        try expectEqual(ba?.tiles, [[1, 2]])
        try expectEqual(target(ba, 1), tile(2, in: laptop.visibleFrame)[0])
    }),
    ("group apply 2: a window of a member app on another screen does not move", {
        let a = grp("a", "A", [term])
        let ws = [window(1, term, "t", 0, anywhere), window(2, term, "u", 0, anywhere, on: dell)]
        let p = arrange(layouts([a]), session([a]), ws, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1])
        try expectEqual(p?.moves.map(\.windowID), [1])
        try expectEqual(target(p, 1), laptop.visibleFrame)
    }),
    ("group apply 3: desktops 2 and 3 with 2 visible: 2 moves now, 3 is pending until it is visited", {
        let a = grp("a", "A", [term], desktops: [2, 3])
        var s = GroupSession()
        let r = s.apply(a, desktops: ["MBP": 2])
        try expectEqual(r.now, GroupKey(screen: "MBP", desktop: 2))
        try expectEqual(r.later, [GroupKey(screen: "MBP", desktop: 3)])
        try expect(s.pending == [GroupKey(screen: "MBP", desktop: 3)], "3 pending")
        let l = layouts([a])
        let p = arrange(l, s, [window(1, term, "t", 0, anywhere)], desktops: ["MBP": 2])
        try expectEqual(target(p, 1), laptop.visibleFrame)
        try expect(!s.visited(GroupKey(screen: "MBP", desktop: 2)), "2 was not pending")
        try expect(s.visited(GroupKey(screen: "MBP", desktop: 3)), "3 pending once")
        try expect(!s.visited(GroupKey(screen: "MBP", desktop: 3)), "and only once")
        let q = arrange(l, s, [window(1, term, "t", 0, anywhere)], desktops: ["MBP": 3])
        try expectEqual(target(q, 1), laptop.visibleFrame)
    }),
    ("group apply 4: a group deleted, unassigned or moved after apply is ignored", {
        let a = grp("a", "A", [term]), ws = [window(1, term, "t", 0, anywhere)]
        let s = session([a])
        try expect(arrange(Layouts(), s, ws) == nil, "deleted")
        var un = a; un.desktops = []
        try expect(arrange(layouts([un]), s, ws) == nil, "unassigned")
        var other = a; other.screen = "DELL"
        try expect(arrange(layouts([other]), s, ws) == nil, "moved to another screen")
        var d2 = a; d2.desktops = [2]
        try expect(arrange(layouts([d2]), s, ws) == nil, "moved to another desktop")
        try expect(s.order(GroupKey(screen: "MBP", desktop: 1), layouts: layouts([a])).map(\.id) == ["a"], "kept while assigned")
    }),
    ("group apply 5: tiled uses the sort order and the gap, saved maps fractions, clamps, and counts a missing window", {
        var l = layouts([grp("a", "A", [term])])
        l.setArrangeSettings(ArrangeSettings(gap: 10, sortByName: true), desktop: 1, screen: "MBP")
        let ws = [window(1, term, "b", 0, anywhere), window(2, term, "a", 1, anywhere)]
        let s = session([grp("a", "A", [term])])
        let t = arrange(l, s, ws)
        try expectEqual(t?.tiles, [[2, 1]])
        let gapped = applyGap(gridTile(2, in: laptop.visibleFrame), gap: 10).frames
        try expectEqual(target(t, 2), gapped[0])
        try expectEqual(target(t, 1), gapped[1])
        let pos = [GroupPosition(matcher: Matcher(bundleID: term, order: 0), fraction: UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
                   GroupPosition(matcher: Matcher(bundleID: term, order: 1), fraction: UnitRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)),
                   GroupPosition(matcher: Matcher(bundleID: term, order: 2), fraction: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1))]
        let sv = grp("v", "V", [term], mode: .saved(pos))
        let small = ScreenInfo(uuid: "MBP", name: "Small", frame: Frame(x: 0, y: 0, width: 800, height: 600), visibleFrame: Frame(x: 0, y: 20, width: 800, height: 580))
        let p = planArrange(layouts([sv]), session: session([sv]), windows: ws, screens: [small], desktops: ["MBP": 1])
        try expectEqual(target(p, 1), Frame(x: 400, y: 310, width: 400, height: 290))
        let clamped = target(p, 2)
        try expect(clamped.map { $0.x + $0.width <= 800 && $0.y + $0.height <= 600 } == true, "clamped \(String(describing: clamped))")
        try expectEqual(p?.skipped.count, 1)
    }),
    ("group apply 6: with an empty session planArrange is planRestore, for snapshots, zones, rules and automatic tiling", {
        var l = Layouts()
        let ws = [window(1, term, "a", 0, anywhere), window(2, mail, "m", 0, anywhere), window(3, safari, "s", 0, anywhere)]
        l.setRule(AppRule(bundleID: mail, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.5, height: 1)))
        var snap = Layouts()
        _ = rememberDesktop(&snap, windows: ws, screens: [laptop], desktops: ["MBP": 1])
        let setup = ScreenSetup(screens: [laptop])
        var zoned = Layouts()
        zoned.set(ScreenArrangement(kind: .zones([Zone(rect: UnitRect(x: 0, y: 0, width: 0.5, height: 1), members: [ZoneMember(bundleID: term)])])), setup: setup, desktop: 1, screen: "MBP")
        var auto = Layouts()
        auto.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 1, screen: "MBP")
        for layout in [l, snap, zoned, auto, Layouts()] {
            try expect(arrange(layout, GroupSession(), ws) == planRestore(layout, windows: ws, screens: [laptop], desktops: ["MBP": 1]), "same plan")
        }
    }),
    ("group apply 7: a rule app claimed by an applied group follows the group, unclaimed rule windows follow the rule", {
        var l = layouts([grp("a", "A", [term])])
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.25, height: 0.25)))
        l.setRule(AppRule(bundleID: mail, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let ws = [window(1, term, "t", 0, anywhere), window(2, mail, "m", 0, anywhere)]
        let p = arrange(l, session([grp("a", "A", [term])]), ws)
        try expectEqual(target(p, 1), laptop.visibleFrame)
        try expectEqual(target(p, 2), UnitRect(x: 0, y: 0, width: 0.5, height: 0.5).frame(in: laptop.visibleFrame))
    }),
    ("group apply 8: clear drops the named keys only", {
        let a = grp("a", "A", [term], desktops: [1, 2])
        var s = session([a])
        s.clear([GroupKey(screen: "MBP", desktop: 1)])
        try expect(s.applied[GroupKey(screen: "MBP", desktop: 1)] == nil, "1 cleared")
        try expect(s.applied[GroupKey(screen: "MBP", desktop: 2)] == ["a"], "2 kept")
        try expect(s.pending == [GroupKey(screen: "MBP", desktop: 2)], "2 pending kept")
        s.clear([GroupKey(screen: "MBP", desktop: 2)])
        try expect(s.isEmpty && s.pending.isEmpty, "empty")
    }),
    ("group apply 9: the moves of a group apply carry the old frames, so Undo puts them back", {
        let a = grp("a", "A", [safari, term])
        let ws = [window(1, safari, "s", 0, anywhere), window(2, term, "t", 0, Frame(x: 50, y: 60, width: 300, height: 200))]
        let p = arrange(layouts([a]), session([a]), ws)
        let undo = (p?.moves ?? []).map { Move(windowID: $0.windowID, from: $0.to, to: $0.from, area: nil) }
        try expectEqual(undo.map(\.to), [anywhere, Frame(x: 50, y: 60, width: 300, height: 200)])
        try expectEqual(undo.map(\.windowID), [1, 2])
    }),
    // WO-GROUPS G4: a new window of an applied group. placeNew and LaunchBatch plan with planArrange and keep onlyWindow's moves.
    ("group new window 1: a tiled group re-grids with the new window, onlyWindow keeps the whole group", {
        let a = grp("a", "A", [term]), l = layouts([a]), s = session([a])
        let grid = tile(2, in: laptop.visibleFrame)
        let old = [window(1, term, "a", 0, grid[0]), window(2, term, "b", 1, grid[1])]
        try expectEqual(arrange(l, s, old)?.moves.count, 0)
        let now = old + [window(3, term, "c", 2, anywhere)]
        guard let plan = arrange(l, s, now) else { throw CheckFailure(description: "no plan") }
        try expectEqual(plan.tiles, [[1, 2, 3]])
        try expectEqual(onlyWindow(plan, 3).moves.map(\.windowID), [1, 2, 3])
        try expectEqual(target(onlyWindow(plan, 3), 3), tile(3, in: laptop.visibleFrame)[2])
    }),
    ("group new window 2: a saved group gives the new window a free position, with none free it stays where it is", {
        let pos = [GroupPosition(matcher: Matcher(bundleID: term, order: 0), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                   GroupPosition(matcher: Matcher(bundleID: term, order: 1), fraction: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))]
        let sv = grp("v", "V", [term], mode: .saved(pos))
        var l = layouts([sv])
        _ = rememberDesktop(&l, windows: [window(9, term, "x", 0, Frame(x: 5, y: 45, width: 300, height: 200))], screens: [laptop], desktops: ["MBP": 1])
        let s = session([sv])
        let left = pos[0].fraction.frame(in: laptop.visibleFrame), right = pos[1].fraction.frame(in: laptop.visibleFrame)
        let none = Plan(moves: [], skipped: [], unchanged: 0)
        let one = [window(1, term, "a", 0, left), window(2, term, "n", 1, anywhere)]
        try expectEqual(onlyWindow(arrange(l, s, one) ?? none, 2).moves.map(\.to), [right])
        let full = [window(1, term, "a", 0, left), window(2, term, "b", 1, right), window(3, term, "n", 2, anywhere)]
        let plan = arrange(l, s, full)
        try expect(plan != nil, "the claimed window still makes a plan")
        try expectEqual(onlyWindow(plan ?? none, 3).moves.count, 0)
    }),
    ("group new window 3: the group beats a rule for the new window, a non-member goes by the layout", {
        var l = layouts([grp("a", "A", [term])])
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.25, height: 0.25)))
        l.setRule(AppRule(bundleID: mail, desktop: 1, screen: "MBP", area: UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        let s = session([grp("a", "A", [term])])
        let ws = [window(1, term, "a", 0, anywhere), window(2, mail, "m", 0, anywhere)]
        let plan = arrange(l, s, ws) ?? Plan(moves: [], skipped: [], unchanged: 0)
        try expectEqual(target(onlyWindow(plan, 1), 1), laptop.visibleFrame)
        try expectEqual(target(onlyWindow(plan, 2), 2), UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5).frame(in: laptop.visibleFrame))
        try expectEqual(onlyWindow(plan, 2).moves.map(\.windowID), [2])
    }),
    ("group new window 4: a window on a screen or desktop with no applied group goes as without groups", {
        let a = grp("a", "A", [term])
        var l = layouts([a])
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: "DELL", area: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let ws = [window(1, term, "t", 0, anywhere, on: dell)]
        let screens = [laptop, dell], desks = ["MBP": 1, "DELL": 1]
        try expect(arrange(l, session([a]), ws, screens: screens, desktops: desks) == planRestore(l, windows: ws, screens: screens, desktops: desks), "other screen")
        let w2 = [window(2, term, "t", 0, anywhere)]
        try expect(arrange(l, session([a]), w2, desktops: ["MBP": 2]) == planRestore(l, windows: w2, screens: [laptop], desktops: ["MBP": 2]), "other desktop")
    }),
    ("group new window 5: after an explicit Restore clears the session the new window goes by the layout again", {
        var l = layouts([grp("a", "A", [term])])
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.25, height: 0.25)))
        var s = session([grp("a", "A", [term])])
        let ws = [window(1, term, "a", 0, anywhere)]
        try expectEqual(target(arrange(l, s, ws), 1), laptop.visibleFrame)
        s.clear([GroupKey(screen: "MBP", desktop: 1)])
        try expectEqual(target(arrange(l, s, ws), 1), UnitRect(x: 0, y: 0, width: 0.25, height: 0.25).frame(in: laptop.visibleFrame))
    }),
    ("group new window 6: a group deleted or unassigned in the editor is ignored for a new window", {
        let a = grp("a", "A", [term]), s = session([a])
        var rule = Layouts()
        rule.setRule(AppRule(bundleID: term, desktop: 1, screen: "MBP", area: UnitRect(x: 0, y: 0, width: 0.25, height: 0.25)))
        let ws = [window(1, term, "a", 0, anywhere)]
        let quarter = UnitRect(x: 0, y: 0, width: 0.25, height: 0.25).frame(in: laptop.visibleFrame)
        try expectEqual(target(arrange(rule, s, ws), 1), quarter)
        var un = a; un.desktops = []
        var l2 = rule; l2.setGroup(un)
        try expectEqual(target(arrange(l2, s, ws), 1), quarter)
    }),
]
