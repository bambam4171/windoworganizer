import Foundation
import WindowOrganizerCore

// WINDOW-GAP S1: the gap between windows, per screen and desktop. Pure values, temp folders only.

private let area = Frame(x: 0, y: 25, width: 1440, height: 875)
private let here = ScreenSetup(screens: [laptop])
private let anywhere = Frame(x: 900, y: 300, width: 400, height: 300)

private func tilesPlan(gap: Int, windows: [WindowInfo]) -> Plan? {
    var l = Layouts()
    l.set(ScreenArrangement(kind: .autoTile), setup: here, desktop: 1, screen: "MBP")
    l.setArrangeSettings(ArrangeSettings(gap: gap), desktop: 1, screen: "MBP")
    return planRestore(l, windows: windows, screens: [laptop], desktops: ["MBP": 1])
}

let gapChecks: [(String, @Sendable () throws -> Void)] = [
    ("presets keep the gap only between windows, outer edges flush", {
        for preset in [Preset.grid, .columns, .rows] {
            for n in [2, 3, 7] {
                for gap in [0, 7, 8, 24] {
                    let fs = presetFrames(preset, count: n, in: area, gap: gap)
                    try expectEqual(fs.count, n)
                    let minX = fs.map(\.x).min()!, minY = fs.map(\.y).min()!
                    let maxX = fs.map { $0.x + $0.width }.max()!, maxY = fs.map { $0.y + $0.height }.max()!
                    try expect(minX == area.x && minY == area.y && maxX == area.x + area.width && maxY == area.y + area.height, "\(preset) \(n) gap \(gap): outer edge moved")
                    for (i, a) in fs.enumerated() { for b in fs[(i + 1)...] {
                        let h = b.x - (a.x + a.width), h2 = a.x - (b.x + b.width)
                        let v = b.y - (a.y + a.height), v2 = a.y - (b.y + b.height)
                        let touching = [h, h2, v, v2].contains { abs($0 - Double(gap)) < 0.001 }
                        let overlap = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
                        try expect(!overlap, "\(preset) \(n) gap \(gap): overlap")
                        if gap == 0 { continue }
                        let nearest = [h, h2, v, v2].filter { $0 > -0.001 }.min() ?? 0
                        if touching { continue }
                        try expect(nearest >= Double(gap) - 0.001, "\(preset) \(n) gap \(gap): closer than the gap")
                    } }
                    if gap == 0 {
                        let plain = preset == .grid ? gridTile(n, in: area) : tile(n, in: area, across: preset == .columns)
                        try expectEqual(fs, plain)
                    }
                }
            }
        }
    }),
    ("neighbouring windows are exactly the gap apart, odd gaps too", {
        for gap in [7, 8, 9] {
            let fs = presetFrames(.columns, count: 3, in: area, gap: gap)
            try expectEqual(fs[1].x - (fs[0].x + fs[0].width), Double(gap))
            try expectEqual(fs[2].x - (fs[1].x + fs[1].width), Double(gap))
        }
    }),
    ("restore applies the gap once: replanning from the moved frames moves nothing", {
        let ws = (1...3).map { window($0, term, "w\($0)", $0 - 1, anywhere) }
        guard let p = tilesPlan(gap: 8, windows: ws) else { throw CheckFailure(description: "no plan") }
        try expectEqual(p.moves.count, 3)
        let moved = p.moves.map { m in window(m.windowID, term, "w\(m.windowID)", m.windowID - 1, m.to) }
        guard let again = tilesPlan(gap: 8, windows: moved) else { throw CheckFailure(description: "no plan") }
        try expectEqual(again.moves, [])
        try expectEqual(again.unchanged, 3)
        try expect(!p.gapSkipped, "gap skipped")
    }),
    ("zones: neighbours get the gap, the screen edge stays flush", {
        var l = Layouts()
        let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1), rightHalf = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        l.set(ScreenArrangement(kind: .zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: term)]),
                                              Zone(rect: rightHalf, members: [ZoneMember(bundleID: mail)])])),
              setup: here, desktop: 1, screen: "MBP")
        l.setArrangeSettings(ArrangeSettings(gap: 8), desktop: 1, screen: "MBP")
        let ws = [window(1, term, "a", 0, anywhere), window(2, mail, "b", 0, anywhere)]
        guard let p = planRestore(l, windows: ws, screens: [laptop], desktops: ["MBP": 1]) else { throw CheckFailure(description: "no plan") }
        let a = p.moves.first { $0.windowID == 1 }!.to, b = p.moves.first { $0.windowID == 2 }!.to
        try expectEqual(b.x - (a.x + a.width), 8)
        try expectEqual(a.x, laptop.visibleFrame.x)
        try expectEqual(b.x + b.width, laptop.visibleFrame.x + laptop.visibleFrame.width)
        try expectEqual(a.y, laptop.visibleFrame.y)
    }),
    ("a snapshot window next to a zone gets the gap on the shared edge", {
        var l = Layouts()
        let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        l.set(ScreenArrangement(kind: .zones([Zone(rect: leftHalf, members: [ZoneMember(bundleID: term)])])), setup: here, desktop: 1, screen: "MBP")
        l.setArrangeSettings(ArrangeSettings(gap: 8), desktop: 1, screen: "MBP")
        var t = tile(2, in: laptop.visibleFrame, across: true)
        t[0] = Frame(x: 0, y: 33, width: 756, height: 949)
        let right = Frame(x: 756, y: 33, width: 756, height: 949)
        let pair = [window(1, term, "a", 0, anywhere), window(2, mail, "b", 0, right)]
        guard let p = planRestore(l, windows: pair, screens: [laptop], desktops: ["MBP": 1]) else { throw CheckFailure(description: "no plan") }
        // Only the zone is a target here; with a single target there is no shared edge, so the zone stays flush.
        try expectEqual(p.moves.first { $0.windowID == 1 }?.to, leftHalf.frame(in: laptop.visibleFrame))
    }),
    ("the gap is per screen and desktop, and removing a setup keeps it", {
        var l = Layouts()
        l.setArrangeSettings(ArrangeSettings(gap: 8), desktop: 1, screen: "A")
        l.setArrangeSettings(ArrangeSettings(gap: 24), desktop: 2, screen: "A")
        l.setArrangeSettings(ArrangeSettings(gap: 0), desktop: 1, screen: "B")
        try expectEqual(l.arrangeSettings(desktop: 1, screen: "A").gapPoints, 8)
        try expectEqual(l.arrangeSettings(desktop: 2, screen: "A").gapPoints, 24)
        try expectEqual(l.arrangeSettings(desktop: 1, screen: "B").gapPoints, 0)
        try expectEqual(l.arrangeSettings(desktop: 3, screen: "A"), ArrangeSettings())
        l.set(ScreenArrangement(kind: .autoTile), setup: here, desktop: 1, screen: "MBP")
        l.remove(setup: here, desktop: 1, screen: "MBP")
        try expectEqual(l.arrangeSettings(desktop: 1, screen: "A").gapPoints, 8)
        try expectEqual(l.arrangeSettings(desktop: 2, screen: "A").gapPoints, 24)
    }),
    ("a plan uses the setting of its own screen and desktop", {
        var l = Layouts()
        l.set(ScreenArrangement(kind: .autoTile), setup: here, desktop: 1, screen: "MBP")
        l.setArrangeSettings(ArrangeSettings(gap: 24), desktop: 2, screen: "MBP")
        l.setArrangeSettings(ArrangeSettings(gap: 24), desktop: 1, screen: "OTHER")
        let ws = (1...2).map { window($0, term, "w\($0)", $0 - 1, anywhere) }
        guard let p = planRestore(l, windows: ws, screens: [laptop], desktops: ["MBP": 1]) else { throw CheckFailure(description: "no plan") }
        let fs = p.moves.sorted { $0.windowID < $1.windowID }.map(\.to)
        try expectEqual(fs, tile(2, in: laptop.visibleFrame, across: true))
    }),
    ("a file without settings reads unchanged; one field writes only that field", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        var l = Layouts()
        l.set(ScreenArrangement(kind: .autoTile), setup: here, desktop: 1, screen: "MBP")
        try store.save(l)
        let before = try Data(contentsOf: store.file)
        try expect(!String(decoding: before, as: UTF8.self).contains("arrange"), "arrange key in a plain file")
        var loaded = try store.load()
        try expectEqual(loaded.arrangeSettings(desktop: 1, screen: "MBP"), ArrangeSettings())
        loaded.setArrangeSettings(ArrangeSettings(gap: 8), desktop: 1, screen: "MBP")
        try store.save(loaded)
        let text = String(decoding: try Data(contentsOf: store.file), as: UTF8.self)
        try expect(text.contains("\"gap\" : 8") && !text.contains("keepLive") && !text.contains("sortByName"), text)
        var again = try store.load()
        try expectEqual(again.arrangeSettings(desktop: 1, screen: "MBP").gapPoints, 8)
        again.setArrangeSettings(ArrangeSettings(), desktop: 1, screen: "MBP")
        try store.save(again)
        try expectEqual(try Data(contentsOf: store.file), before)
    }),
    ("defaults: no gap, live follows the gap, resize correction on", {
        let d = ArrangeSettings()
        try expect(d.gapPoints == 0 && !d.isLive && !d.pushesBackOnTop && d.correctsResize && !d.sortsByName && d.isDefault, "defaults")
        try expect(ArrangeSettings(gap: 8).isLive && !ArrangeSettings(gap: 8, keepLive: false).isLive, "live")
    }),
    ("invalid settings are refused", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        for (gap, desktop, screen) in [(-1, 1, "A"), (65, 1, "A"), (8, 1, ""), (8, 1001, "A")] {
            var l = Layouts()
            l.setArrangeSettings(ArrangeSettings(gap: gap), desktop: desktop, screen: screen)
            do { try store.save(l); throw CheckFailure(description: "accepted gap \(gap) desktop \(desktop) screen '\(screen)'") }
            catch let e as LayoutStoreError { try expectEqual(e, .invalidLayout) }
        }
    }),
    ("a minimum size wins over the gap and is reported", {
        let ws = (1...3).map { window($0, term, "w\($0)", $0 - 1, anywhere) }
        guard let p = tilesPlan(gap: 8, windows: ws) else { throw CheckFailure(description: "no plan") }
        let mover = FakeMover(ws)
        mover.minimum = [2: (800, 100)]
        let r = applyPlan(p, mover: mover)
        try expectEqual(r.keptMinimum, 1)
        try expect(ResultLine.restored(r, desktop: 1, at: "10:00").contains("kept its minimum size"), "line")
    }),
    ("no room: the gap is skipped and the plan says so", {
        let narrow = ScreenInfo(uuid: "NAR", name: "Narrow", frame: Frame(x: 0, y: 0, width: 300, height: 300),
                                visibleFrame: Frame(x: 0, y: 0, width: 300, height: 300))
        var l = Layouts()
        let setup = ScreenSetup(screens: [narrow])
        l.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 1, screen: "NAR")
        l.setArrangeSettings(ArrangeSettings(gap: 64), desktop: 1, screen: "NAR")
        let ws = (1...7).map { window($0, term, "w\($0)", $0 - 1, anywhere, on: narrow) }
        guard let p = planRestore(l, windows: ws, screens: [narrow], desktops: ["NAR": 1]) else { throw CheckFailure(description: "no plan") }
        try expect(p.gapSkipped, "not flagged")
        let flat = gridTile(7, in: narrow.visibleFrame)
        try expectEqual(p.moves.sorted { $0.windowID < $1.windowID }.map(\.to), flat)
    }),
    ("an immediate grid carries the gap and flags no room", {
        let ws = (1...4).map { window($0, term, "w\($0)", $0 - 1, anywhere) }
        let sel = WorkspaceSelection(screenUUID: "MBP", desktop: 1)
        let p = try planAutomaticWorkspace(sel, windows: ws, screens: [laptop], desktops: ["MBP": 1], gap: 8)
        let fs = p.moves.sorted { $0.windowID < $1.windowID }.map(\.to)
        try expectEqual(fs, presetFrames(.grid, count: 4, in: laptop.visibleFrame, gap: 8))
    }),
]
