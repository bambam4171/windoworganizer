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
]
