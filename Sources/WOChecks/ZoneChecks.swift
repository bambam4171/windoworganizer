import Foundation
import WindowOrganizerCore

// WO-S6a (plan §1 zones, §8 S6): zones drawn on a screen take the windows of their member apps and tile them inside.

private func zones(_ zs: [Zone]) -> ScreenArrangement { ScreenArrangement(kind: .zones(zs)) }
private let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
private let rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
private let anyFrame = Frame(x: 900, y: 300, width: 400, height: 300)

let zoneChecks: [(String, @Sendable () throws -> Void)] = [
    ("tiling: along the longer side, equal parts, rounded edges with no gap", {
        try expectEqual(tile(3, in: Frame(x: 0, y: 0, width: 900, height: 300)),
                        [Frame(x: 0, y: 0, width: 300, height: 300), Frame(x: 300, y: 0, width: 300, height: 300),
                         Frame(x: 600, y: 0, width: 300, height: 300)])
        try expectEqual(tile(2, in: Frame(x: 0, y: 33, width: 756, height: 949)),
                        [Frame(x: 0, y: 33, width: 756, height: 475), Frame(x: 0, y: 508, width: 756, height: 474)])
        try expectEqual(tile(1, in: anyFrame), [anyFrame])
        try expectEqual(tile(0, in: anyFrame), [])
    }),
    ("zones round-trip through JSON, and a snapshot file still loads", {
        var layouts = Layouts()
        let setup = ScreenSetup(screens: [laptop])
        let z = zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: term), ZoneMember(bundleID: safari, titlePattern: "docs")])])
        layouts.set(z, setup: setup, desktop: 1, screen: "MBP")
        let data = try JSONEncoder().encode(layouts)
        try expect(String(decoding: data, as: UTF8.self).contains("\"zones\""), "kind name zones")
        try expectEqual(try JSONDecoder().decode(Layouts.self, from: data), layouts)
    }),
    ("restore tiles a zone's member windows in member order, then window order, and leaves others alone", {
        var layouts = Layouts()
        layouts.set(zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: mail), ZoneMember(bundleID: term)])]),
                    setup: ScreenSetup(screens: [laptop]), desktop: 1, screen: "MBP")
        let ws = [window(1, term, "a", 0, anyFrame), window(2, safari, "x", 0, anyFrame), window(3, mail, "Inbox", 0, anyFrame)]
        guard let plan = planRestore(layouts, windows: ws, screens: [laptop], desktops: ["MBP": 1])
        else { throw CheckFailure(description: "no plan") }
        try expectEqual(plan.moves, [Move(windowID: 3, from: anyFrame, to: Frame(x: 0, y: 33, width: 756, height: 475)),
                                     Move(windowID: 1, from: anyFrame, to: Frame(x: 0, y: 508, width: 756, height: 474))])
        try expectEqual(plan.skipped, [])
        try expectEqual(plan.tiles, [[3, 1]])
    }),
    ("a title pattern member takes only matching windows, and each window goes to the first zone that wants it", {
        var layouts = Layouts()
        layouts.set(zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: safari, titlePattern: "docs")]),
                           Zone(rect: rightHalf, members: [ZoneMember(bundleID: safari)])]),
                    setup: ScreenSetup(screens: [laptop]), desktop: 1, screen: "MBP")
        let ws = [window(1, safari, "News", 0, anyFrame), window(2, safari, "Swift Docs", 1, anyFrame)]
        guard let plan = planRestore(layouts, windows: ws, screens: [laptop], desktops: ["MBP": 1])
        else { throw CheckFailure(description: "no plan") }
        try expectEqual(plan.moves.map(\.windowID), [2, 1])
        try expectEqual(plan.moves.map(\.to.x), [0, 756])
    }),
    ("snapshot places claim first, zones take the rest", {
        var layouts = Layouts()
        let setup = ScreenSetup(screens: [laptop, dell])
        let dellFrame = Frame(x: 1600, y: 40, width: 900, height: 700)
        layouts.set(remember([window(9, term, "a", 0, dellFrame, on: dell)], on: dell), setup: setup, desktop: 1, screen: "DELL")
        layouts.set(zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: term)])]), setup: setup, desktop: 1, screen: "MBP")
        let ws = [window(1, term, "a", 0, anyFrame), window(2, term, "b", 1, anyFrame), window(3, term, "c", 2, anyFrame)]
        guard let plan = planRestore(layouts, windows: ws, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1])
        else { throw CheckFailure(description: "no plan") }
        try expectEqual(plan.moves.first, Move(windowID: 1, from: anyFrame, to: dellFrame))
        try expectEqual(plan.tiles, [[2, 3]])
    }),
    ("Remember this desktop keeps a screen that has zones and says so", {
        var layouts = Layouts()
        let setup = ScreenSetup(screens: [laptop, dell])
        let z = zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: term)])])
        layouts.set(z, setup: setup, desktop: 2, screen: "MBP")
        let ws = [window(1, term, "a", 0, anyFrame), window(2, mail, "Inbox", 0, Frame(x: 1600, y: 40, width: 900, height: 700), on: dell)]
        let r = rememberDesktop(&layouts, windows: ws, screens: [laptop, dell], desktops: ["MBP": 2, "DELL": 2])
        try expectEqual(r, 1)
        try expectEqual(layouts.arrangement(setup: setup, desktop: 2, screen: "MBP"), z)
        try expectEqual(zoneScreens(layouts, screens: [laptop, dell], desktops: ["MBP": 2, "DELL": 2]), 1)
        try expectEqual(ResultLine.remembered(windows: 1, screens: 1, keptZones: 1, desktop: 2, at: "23:58"),
                        "Desktop 2: remembered 1 window on 1 screen, 1 screen keeps its zones · 23:58")
    }),
    ("a new window in a zone re-tiles that zone, nothing else moves", {
        let a = Frame(x: 0, y: 0, width: 10, height: 10)
        let plan = Plan(moves: [Move(windowID: 1, from: a, to: a), Move(windowID: 2, from: a, to: a), Move(windowID: 5, from: a, to: a)],
                        skipped: [], unchanged: 0, tiles: [[1, 2], [5]])
        try expectEqual(onlyWindow(plan, 2).moves.map(\.windowID), [1, 2])
        try expectEqual(onlyWindow(plan, 5).moves.map(\.windowID), [5])
    }),
]
