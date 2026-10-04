import Foundation
import WindowOrganizerCore

// SORT-BY-NAME: the order windows fill tiles in. Finder order is asserted against localizedStandardCompare itself.

private let sortHere = ScreenSetup(screens: [laptop])
private let spot = Frame(x: 900, y: 300, width: 400, height: 300)

private func named(_ id: Int, app: String?, bundle: String = "com.x.app", title: String = "", order: Int = 0) -> WindowInfo {
    WindowInfo(windowID: id, bundleID: bundle, title: title, frame: spot, screenUUID: "MBP", order: order, appName: app)
}

private func autoTilePlan(_ ws: [WindowInfo], sorted: [Int: Bool]) -> Plan? {
    var l = Layouts()
    l.set(ScreenArrangement(kind: .autoTile), setup: sortHere, desktop: 1, screen: "MBP")
    l.set(ScreenArrangement(kind: .autoTile), setup: sortHere, desktop: 2, screen: "MBP")
    for (desktop, on) in sorted { l.setArrangeSettings(ArrangeSettings(sortByName: on ? true : nil), desktop: desktop, screen: "MBP") }
    return planRestore(l, windows: ws, screens: [laptop], desktops: ["MBP": sorted.keys.min() ?? 1])
}

private let shuffled = [named(1, app: "Safari", title: "b"), named(2, app: "Mail", title: "z"), named(3, app: "Terminal", title: "a"),
                        named(4, app: "Mail", title: "a"), named(5, app: "Notes", title: "n"), named(6, app: "Calendar", title: "c")]

let sortChecks: [(String, @Sendable () throws -> Void)] = [
    ("natural order: 2, 3, 10", {
        let ws = [named(1, app: "A", title: "Window 10"), named(2, app: "A", title: "Window 2"), named(3, app: "A", title: "window 3")]
        try expectEqual(sortedByName(ws).map(\.windowID), [2, 3, 1])
    }),
    ("accents and case as the Finder treats them", {
        let names = ["Birne", "Äpfel", "Zebra", "apfel", "Ärger"]
        let ws = names.enumerated().map { named($0.offset, app: $0.element) }
        let got = sortedByName(ws).compactMap(\.appName)
        for (a, b) in zip(got, got.dropFirst()) { try expect(a.localizedStandardCompare(b) != .orderedDescending, "\(a) before \(b)") }
        let apples = sortedByName([named(1, app: "Birne"), named(2, app: "Äpfel")]).compactMap(\.appName)
        try expectEqual(apples, ["Äpfel", "Birne"])
    }),
    ("app name before title, bundle id never; no name falls back to the bundle id", {
        let ws = [named(1, app: "Zulu", bundle: "com.a.zulu"), named(2, app: "Alpha", bundle: "com.z.alpha")]
        try expectEqual(sortedByName(ws).map(\.windowID), [2, 1])
        let mixed = [named(1, app: nil, bundle: "com.b.beta"), named(2, app: "Alpha", bundle: "com.z.x"), named(3, app: nil, bundle: "com.a.alpha")]
        try expectEqual(sortedByName(mixed).map(\.windowID), [3, 1, 2].filter { _ in true }.sorted { id1, id2 in
            let key = { (id: Int) -> String in mixed.first { $0.windowID == id }.map { $0.appName ?? $0.bundleID }! }
            return key(id1).localizedStandardCompare(key(id2)) == .orderedAscending
        })
    }),
    ("equal names keep their input order", {
        let ws = [named(1, app: "Terminal", title: "zsh", order: 1), named(2, app: "Terminal", title: "zsh", order: 0)]
        try expectEqual(sortedByName(ws).map(\.windowID), [1, 2])
        try expectEqual(sortedByName(ws.reversed()).map(\.windowID), [2, 1])
    }),
    ("a sorted 2x3 grid lands in reading order", {
        let ws = sortedByName(shuffled)
        let fs = presetFrames(.grid, count: 6, in: Frame(x: 0, y: 25, width: 1440, height: 875))
        let readingOrder = fs.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        try expectEqual(fs, readingOrder)
        try expectEqual(ws.compactMap(\.appName), ["Calendar", "Mail", "Mail", "Notes", "Safari", "Terminal"])
        try expectEqual(ws.map(\.windowID), [6, 4, 2, 5, 1, 3])
    }),
    ("Columns left to right, Rows top to bottom", {
        let area = Frame(x: 0, y: 25, width: 1440, height: 875)
        let cols = presetFrames(.columns, count: 3, in: area), rows = presetFrames(.rows, count: 3, in: area)
        try expect(cols[0].x < cols[1].x && cols[1].x < cols[2].x, "columns")
        try expect(rows[0].y < rows[1].y && rows[1].y < rows[2].y, "rows")
    }),
    ("switch off = today's order, switch on = by name, in the plans", {
        let off = autoTilePlan(shuffled, sorted: [1: false])
        let none = autoTilePlan(shuffled, sorted: [:])
        try expectEqual(off?.moves, none?.moves)
        let today = shuffled.sorted { ($0.bundleID, $0.order, $0.windowID) < ($1.bundleID, $1.order, $1.windowID) }
        let tiles = gridTile(6, in: laptop.visibleFrame)
        for (w, f) in zip(today, tiles) { try expectEqual(off?.moves.first { $0.windowID == w.windowID }?.to, f) }
        let on = autoTilePlan(shuffled, sorted: [1: true])
        for (w, f) in zip(sortedByName(shuffled), tiles) { try expectEqual(on?.moves.first { $0.windowID == w.windowID }?.to, f) }
        let sel = WorkspaceSelection(screenUUID: "MBP", desktop: 1)
        let draft = try planAutomaticWorkspace(sel, windows: shuffled, screens: [laptop], desktops: ["MBP": 1], settings: ArrangeSettings(sortByName: true))
        for (w, f) in zip(sortedByName(shuffled), tiles) { try expectEqual(draft.moves.first { $0.windowID == w.windowID }?.to, f) }
        let plain = try planAutomaticWorkspace(sel, windows: shuffled, screens: [laptop], desktops: ["MBP": 1])
        for (w, f) in zip(today, tiles) { try expectEqual(plain.moves.first { $0.windowID == w.windowID }?.to, f) }
    }),
    ("a sorted grid keeps the gap", {
        let sel = WorkspaceSelection(screenUUID: "MBP", desktop: 1)
        let p = try planAutomaticWorkspace(sel, windows: shuffled, screens: [laptop], desktops: ["MBP": 1], settings: ArrangeSettings(gap: 8, sortByName: true))
        let first = p.moves.first { $0.windowID == 6 }!.to, second = p.moves.first { $0.windowID == 4 }!.to
        try expectEqual(second.x - (first.x + first.width), 8)
    }),
    ("the setting is per screen and desktop", {
        let two = [named(1, app: "Zed"), named(2, app: "Ant")]
        var l = Layouts()
        l.set(ScreenArrangement(kind: .autoTile), setup: sortHere, desktop: 1, screen: "MBP")
        l.set(ScreenArrangement(kind: .autoTile), setup: sortHere, desktop: 2, screen: "MBP")
        l.setArrangeSettings(ArrangeSettings(sortByName: true), desktop: 1, screen: "MBP")
        let tiles = gridTile(2, in: laptop.visibleFrame)
        let d1 = planRestore(l, windows: two, screens: [laptop], desktops: ["MBP": 1])
        let d2 = planRestore(l, windows: two, screens: [laptop], desktops: ["MBP": 2])
        try expectEqual(d1?.moves.first { $0.windowID == 2 }?.to, tiles[0])
        try expectEqual(d2?.moves.first { $0.windowID == 1 }?.to, tiles[0])
        try expect(l.arrangeSettings(desktop: 2, screen: "MBP").sortsByName == false, "desktop 2 default")
    }),
    // SORT-MODE: "I arrange the order myself".
    ("the manual order survives new window IDs", {
        let before = [named(1, app: "Zed", bundle: "com.z"), named(2, app: "Ant", bundle: "com.a"), named(3, app: "Mid", bundle: "com.m")]
        let order = manualOrder(for: [before[1], before[2], before[0]])
        let after = [named(11, app: "Zed", bundle: "com.z"), named(12, app: "Mid", bundle: "com.m"), named(13, app: "Ant", bundle: "com.a")]
        try expectEqual(arrangeOrder(after, settings: ArrangeSettings(manualOrder: order)).map(\.windowID), [13, 12, 11])
    }),
    ("a window not in the order goes last, in today's order", {
        let known = [named(1, app: "Zed", bundle: "com.z"), named(2, app: "Ant", bundle: "com.a")]
        let order = manualOrder(for: [known[1], known[0]])
        let now = [named(5, app: "New", bundle: "com.n1"), known[0], named(6, app: "New", bundle: "com.n2"), known[1]]
        try expectEqual(arrangeOrder(now, settings: ArrangeSettings(manualOrder: order)).map(\.windowID), [2, 1, 5, 6])
    }),
    ("two windows with one title keep their stored order", {
        let a = named(1, app: "Terminal", bundle: "com.t", title: "zsh", order: 0), b = named(2, app: "Terminal", bundle: "com.t", title: "zsh", order: 1)
        let order = manualOrder(for: [b, a])
        let got = arrangeOrder([named(7, app: "Terminal", bundle: "com.t", title: "zsh", order: 0),
                                named(8, app: "Terminal", bundle: "com.t", title: "zsh", order: 1)], settings: ArrangeSettings(manualOrder: order))
        try expectEqual(got.map(\.windowID), [8, 7])
    }),
    ("a closed window's entry cannot take a later entry's window (B1)", {
        let a = named(1, app: "Safari", bundle: "com.s", title: "A", order: 0), x = named(2, app: "Chrome", bundle: "com.c", title: "X", order: 0)
        let b = named(3, app: "Safari", bundle: "com.s", title: "B", order: 1)
        let order = manualOrder(for: [a, x, b])
        // A closed: B is now Safari's first window. Entry A must not take B ahead of X.
        let got = arrangeOrder([named(12, app: "Chrome", bundle: "com.c", title: "X", order: 0),
                                named(13, app: "Safari", bundle: "com.s", title: "B", order: 0)], settings: ArrangeSettings(manualOrder: order))
        try expectEqual(got.map(\.windowID), [12, 13])
    }),
    ("by name ignores the stored order, and switching back restores it", {
        let ws = [named(1, app: "Zed", bundle: "com.z"), named(2, app: "Ant", bundle: "com.a")]
        var s = ArrangeSettings(manualOrder: manualOrder(for: ws))
        try expectEqual(arrangeOrder(ws, settings: s).map(\.windowID), [1, 2])
        s.sortByName = true
        try expectEqual(arrangeOrder(ws, settings: s).map(\.windowID), [2, 1])
        try expect(s.manualOrder != nil, "order kept")
        s.sortByName = nil
        try expectEqual(arrangeOrder(ws, settings: s).map(\.windowID), [1, 2])
        var l = Layouts()
        l.setArrangeSettings(s, desktop: 1, screen: "MBP")
        let back = try LayoutStore.decode(JSONEncoder().encode(l))
        try expectEqual(back.arrangeSettings(desktop: 1, screen: "MBP").manualOrder, s.manualOrder)
    }),
    ("no order = today's order", {
        try expectEqual(arrangeOrder(shuffled, settings: ArrangeSettings()).map(\.windowID), shuffled.map(\.windowID))
        try expectEqual(arrangeOrder(shuffled, settings: ArrangeSettings(manualOrder: [])).map(\.windowID), shuffled.map(\.windowID))
    }),
    ("snapshot, zone and rule windows keep their place in both modes", {
        let setup = sortHere
        let term = named(1, app: "Terminal", bundle: "com.t"), mail = named(2, app: "Mail", bundle: "com.m"), ant = named(3, app: "Ant", bundle: "com.a")
        let ws = [term, mail, ant]
        func layouts(_ s: ArrangeSettings?) -> Layouts {
            var l = Layouts()
            let place = Placement(matcher: Matcher(bundleID: "com.t"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1),
                                  pixel: Frame(x: 0, y: 25, width: 720, height: 875), screenUUID: "MBP", visibleFrame: laptop.visibleFrame)
            l.set(ScreenArrangement(kind: .snapshot([place])), setup: setup, desktop: 1, screen: "MBP")
            l.set(ScreenArrangement(kind: .zones([Zone(rect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), members: [ZoneMember(bundleID: "com.m")])])),
                  setup: setup, desktop: 2, screen: "MBP")
            l.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 3, screen: "MBP")
            for d in 1...3 { if let s { l.setArrangeSettings(s, desktop: d, screen: "MBP") } }
            return l
        }
        let order = manualOrder(for: [ant, mail, term])
        for d in 1...2 {
            let plain = planRestore(layouts(nil), windows: ws, screens: [laptop], desktops: ["MBP": d])
            for s in [ArrangeSettings(sortByName: true), ArrangeSettings(manualOrder: order)] {
                try expectEqual(planRestore(layouts(s), windows: ws, screens: [laptop], desktops: ["MBP": d])?.moves, plain?.moves)
            }
        }
    }),
    ("an S2 file reads unchanged", {
        var l = Layouts()
        l.setArrangeSettings(ArrangeSettings(gap: 8, sortByName: true), desktop: 1, screen: "MBP")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys  // dictionary key order differs between runs
        let data = try encoder.encode(l)
        try expect(!String(decoding: data, as: UTF8.self).contains("manualOrder"), "not written when nil")
        let back = try LayoutStore.decode(data)
        try expect(back.arrangeSettings(desktop: 1, screen: "MBP").sortsByName, "reads as by name")
        try expectEqual(try encoder.encode(back), data)
    }),
    ("invalid order refused", {
        let ok = (0..<64).map { Matcher(bundleID: "com.x\($0)") }
        var l = Layouts()
        l.setArrangeSettings(ArrangeSettings(manualOrder: ok), desktop: 1, screen: "MBP")
        try l.validate()
        for bad in [ok + [Matcher(bundleID: "com.over")], [Matcher(bundleID: "")]] {
            var b = Layouts()
            b.setArrangeSettings(ArrangeSettings(manualOrder: bad), desktop: 1, screen: "MBP")
            var refused = false
            do { try b.validate() } catch { refused = true }
            try expect(refused, "refused \(bad.count)")
        }
    }),
]
