import Foundation
import WindowOrganizerCore

// AUTO-MODE S1 (D-1943): the setting, planAuto for one screen, the set guard, and the trigger.

private let autoSetup = ScreenSetup(screens: [laptop, dell])

private func win(_ id: Int, _ bundle: String, on screen: String, at: Frame, order: Int = 0) -> WindowInfo {
    WindowInfo(windowID: id, bundleID: bundle, title: "", frame: at, screenUUID: screen, order: order)
}

private let nowhere = Frame(x: 5, y: 5, width: 100, height: 100)

private func unwrap<T>(_ v: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let v else { throw CheckFailure(description: "\(file):\(line): nil") }
    return v
}

private func twoScreens(_ kind: ScreenArrangement.Kind) -> Layouts {
    var l = Layouts()
    l.set(ScreenArrangement(kind: kind), setup: autoSetup, desktop: 1, screen: "MBP")
    l.set(ScreenArrangement(kind: .autoTile), setup: autoSetup, desktop: 1, screen: "DELL")
    return l
}

private let kindWindows = [win(1, "a", on: "MBP", at: nowhere), win(2, "b", on: "MBP", at: nowhere, order: 1),
                           win(3, "c", on: "DELL", at: nowhere), win(4, "d", on: "DELL", at: nowhere, order: 1)]

private func movedOnA(_ l: Layouts) -> Set<Int>? {
    planAuto(l, windows: kindWindows, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1], screen: "MBP").map { Set($0.moves.map(\.windowID)) }
}

let autoChecks: [(String, @Sendable () throws -> Void)] = [
    ("auto setting is optional: an old file decodes and re-encodes byte-identical", {
        var l = Layouts()
        l.setArrangeSettings(ArrangeSettings(gap: 8), desktop: 1, screen: "MBP")
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(l)
        let back = try JSONDecoder().decode(Layouts.self, from: data)
        try expectEqual(try enc.encode(back), data)
        try expect(!String(decoding: data, as: UTF8.self).contains("autoArrange"), "untouched file has no autoArrange")
        try expect(!back.arrangeSettings(desktop: 1, screen: "MBP").arrangesAutomatically, "default is off")
    }),
    ("auto setting is per desktop and screen, and an all-default record drops", {
        var l = Layouts()
        l.setArrangeSettings(ArrangeSettings(autoArrange: true), desktop: 2, screen: "MBP")
        try expect(l.arrangeSettings(desktop: 2, screen: "MBP").arrangesAutomatically, "desktop 2 screen MBP on")
        try expect(!l.arrangeSettings(desktop: 1, screen: "MBP").arrangesAutomatically, "desktop 1 off")
        try expect(!l.arrangeSettings(desktop: 2, screen: "DELL").arrangesAutomatically, "other screen off")
        l.setArrangeSettings(ArrangeSettings(autoArrange: nil), desktop: 2, screen: "MBP")
        try expect(l.arrange.isEmpty, "entry dropped")
    }),
    ("planAuto moves this screen only", {
        let moved = try unwrap(movedOnA(twoScreens(.autoTile)))
        try expectEqual(moved, [1, 2])
    }),
    ("planAuto: a snapshot place on B never pulls a window off A", {
        var l = twoScreens(.autoTile)
        let place = Placement(matcher: Matcher(bundleID: "c"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5),
                              pixel: Frame(x: 1500, y: 100, width: 300, height: 300), screenUUID: "DELL", visibleFrame: dell.visibleFrame)
        l.set(ScreenArrangement(kind: .snapshot([place])), setup: autoSetup, desktop: 1, screen: "DELL")
        let moved = try unwrap(movedOnA(l))
        try expect(moved.isSubset(of: [1, 2]), "only A's windows move: \(moved)")
    }),
    ("planAuto drops a move whose target lies off the screen", {
        var l = Layouts()
        let off = Placement(matcher: Matcher(bundleID: "a"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5),
                            pixel: Frame(x: 3000, y: 100, width: 300, height: 300), screenUUID: "MBP", visibleFrame: laptop.visibleFrame)
        let on = Placement(matcher: Matcher(bundleID: "b"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5),
                           pixel: Frame(x: 100, y: 100, width: 300, height: 300), screenUUID: "MBP", visibleFrame: laptop.visibleFrame)
        l.set(ScreenArrangement(kind: .snapshot([off, on])), setup: autoSetup, desktop: 1, screen: "MBP")
        let desktops = ["MBP": 1, "DELL": 1]
        let restore = try unwrap(planRestore(l, windows: kindWindows, screens: [laptop, dell], desktops: desktops))
        try expect(restore.moves.contains { $0.windowID == 1 }, "Restore itself would send window 1 off screen")
        let auto = try unwrap(planAuto(l, windows: kindWindows, screens: [laptop, dell], desktops: desktops, screen: "MBP"))
        try expectEqual(auto.moves.map(\.windowID), [2])
    }),
    ("planAuto per kind: zones and auto-tile give Restore's plan restricted to A", {
        let zone = Zone(rect: UnitRect(x: 0, y: 0, width: 1, height: 1), members: [ZoneMember(bundleID: "a"), ZoneMember(bundleID: "b")])
        let zoned = try unwrap(movedOnA(twoScreens(.zones([zone]))))
        try expectEqual(zoned, [1, 2])
        let tiled = try unwrap(movedOnA(twoScreens(.autoTile)))
        try expectEqual(tiled, [1, 2])
    }),
    ("planAuto is nil without an arrangement on that desktop, and for an unknown screen", {
        var l = Layouts()
        l.set(ScreenArrangement(kind: .autoTile), setup: autoSetup, desktop: 1, screen: "DELL")
        try expect(movedOnA(l) == nil, "MBP has none")
        try expect(planAuto(twoScreens(.autoTile), windows: kindWindows, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1], screen: "GONE") == nil, "unknown screen")
        try expect(planAuto(twoScreens(.autoTile), windows: kindWindows, screens: [laptop, dell], desktops: ["MBP": 2, "DELL": 1], screen: "MBP") == nil, "desktop 2 has none")
    }),
    ("same set, no arrange: true once, then false; a changed set and forget are true", {
        var s = AutoState()
        let k = AutoState.key(desktop: 1, screen: "MBP")
        try expect(s.shouldArrange(key: k, ids: [1, 2]), "first time")
        try expect(!s.shouldArrange(key: k, ids: [1, 2]), "same set")
        try expect(s.shouldArrange(key: k, ids: [1, 2, 3]), "an open")
        try expect(s.shouldArrange(key: k, ids: [1, 3]), "a close")
        try expect(!s.shouldArrange(key: k, ids: [3, 1]), "same set in another order")
        s.forget(key: k)
        try expect(s.shouldArrange(key: k, ids: [1, 3]), "after forget")
        try expect(s.shouldArrange(key: AutoState.key(desktop: 2, screen: "MBP"), ids: [1, 3]), "another desktop has its own set")
    }),
    ("paused or no desktops, no check", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP"], displays: [DisplaySpaces(display: "MBP", current: 1, spaces: [1])]))
        try expectEqual(t.handle(.windowsChanged), .autoCheck)
        t.paused = true
        try expectEqual(t.handle(.windowsChanged), .none)
        var u = TriggerState()
        _ = u.handle(.start(screens: ["MBP"], displays: []))
        try expectEqual(u.handle(.windowsChanged), .none)
        try expectEqual(u.handle(.windowCreated), .none)
    }),
]
