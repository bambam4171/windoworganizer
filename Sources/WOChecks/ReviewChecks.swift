import Foundation
import WindowOrganizerCore

let reviewChecks: [(String, @Sendable () throws -> Void)] = [
    ("saved titles survive reversed focus order", {
        let f = Frame(x: 0, y: 40, width: 500, height: 300)
        let ws = [window(2, term, "Server", 0, f), window(1, term, "Build", 1, f)]
        let m = matchWindows([Matcher(bundleID: term, seenTitle: "Build", order: 0),
                              Matcher(bundleID: term, seenTitle: "Server", order: 1)], ws)
        try expectEqual(m.assigned.map { $0?.windowID }, [1, 2])
    }),
    ("all exact titles are reserved before fallback claims", {
        let f = Frame(x: 0, y: 40, width: 500, height: 300)
        let ws = [window(1, term, "Server", 0, f), window(2, term, "New", 1, f)]
        let m = matchWindows([Matcher(bundleID: term, seenTitle: "Closed", order: 0),
                              Matcher(bundleID: term, seenTitle: "Server", order: 1)], ws)
        try expectEqual(m.assigned.map { $0?.windowID }, [2, 1])
    }),
    ("duplicate orders have a deterministic window ID tie-break", {
        let f = Frame(x: 0, y: 40, width: 500, height: 300)
        let m = matchWindows([Matcher(bundleID: term)], [window(9, term, "B", 0, f), window(1, term, "A", 0, f)])
        try expectEqual(m.assigned[0]?.windowID, 1)
    }),
    ("resolution scaling contains previously offscreen windows", {
        let old = [window(1, term, "A", 0, Frame(x: -500, y: -100, width: 2300, height: 1400))]
        var small = laptop; small.visibleFrame = Frame(x: 0, y: 40, width: 800, height: 500)
        let plan = planSnapshot(remember(old, on: laptop), windows: old, screen: small)
        try expectEqual(plan.moves.first?.to, small.visibleFrame)
    }),
    ("grid fills the area for 1 through 20 windows without overlap", {
        let area = Frame(x: 1512, y: 25, width: 1200, height: 800)
        for n in 1...20 {
            let frames = gridTile(n, in: area)
            try expectEqual(frames.count, n)
            try expect(frames.allSatisfy { $0.isValid && area.rect.contains($0.rect) }, "within display")
            try expectEqual(frames.reduce(0) { $0 + $1.width * $1.height }, area.width * area.height)
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let r = frames[i].rect.intersection(frames[j].rect)
                    try expect(r.isNull || r.width == 0 || r.height == 0, "tiles overlap")
                }
            }
        }
    }),
    ("auto grid only claims its screen; rules win; Remember preserves grid", {
        var layouts = Layouts(); let setup = ScreenSetup(screens: [laptop, dell])
        layouts.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 1, screen: laptop.uuid)
        layouts.setRule(AppRule(bundleID: mail, desktop: 1, screen: dell.uuid, area: AppRule.full))
        let f = Frame(x: 100, y: 100, width: 400, height: 300)
        let ws = [window(1, term, "A", 0, f), window(2, mail, "Inbox", 0, f), window(3, safari, "Docs", 0, f, on: dell)]
        let desktops = [laptop.uuid: 1, dell.uuid: 1]
        let plan = planRestore(layouts, windows: ws, screens: [laptop, dell], desktops: desktops)
        try expectEqual(Set(plan?.moves.map(\.windowID) ?? []), [1, 2])
        try expectEqual(plan?.moves.first { $0.windowID == 1 }?.to, laptop.visibleFrame)
        try expectEqual(plan?.moves.first { $0.windowID == 2 }?.to, dell.visibleFrame)
        _ = rememberDesktop(&layouts, windows: ws, screens: [laptop, dell], desktops: desktops)
        try expectEqual(layouts.arrangement(setup: setup, desktop: 1, screen: laptop.uuid)?.kind, .autoTile)
        try expectEqual(try LayoutStore.decode(JSONEncoder().encode(layouts)), layouts)
    }),
    ("a new auto-grid window retile is limited to its screen", {
        var l = Layouts(); let setup = ScreenSetup(screens: [laptop, dell])
        for s in [laptop, dell] { l.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 1, screen: s.uuid) }
        let f = Frame(x: 100, y: 100, width: 400, height: 300)
        let ws = [window(1, term, "A", 0, f), window(2, term, "B", 1, f), window(3, safari, "C", 0, f, on: dell)]
        guard let p = planRestore(l, windows: ws, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1]) else { throw CheckFailure(description: "no plan") }
        try expectEqual(Set(onlyWindow(p, 2).moves.map(\.windowID)), [1, 2])
    }),
    ("schema 1 migrates to schema 2 and retains its data", {
        let old = Data(#"{"schema":1,"setups":{"MBP":{"1":{"MBP":{"kind":"snapshot","placements":[]}}}}}"#.utf8)
        let l = try LayoutStore.decode(old)
        try expectEqual(l.schema, Layouts.currentSchema)
        try expectEqual(l.arrangement(setup: ScreenSetup(screens: [laptop]), desktop: 1, screen: laptop.uuid)?.kind, .snapshot([]))
    }),
    ("invalid geometry and duplicate rules are rejected before persistence", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var l = Layouts()
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: laptop.uuid, area: UnitRect(x: 0.8, y: 0, width: 0.5, height: 1)))
        do { try LayoutStore(directory: dir).save(l); throw CheckFailure(description: "saved invalid rule") }
        catch let e as LayoutStoreError { try expectEqual(e, .invalidLayout) }
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("layouts.json").path), "no write")
        let duplicate = Data(#"{"schema":2,"setups":{},"rules":[{"bundleID":"a","desktop":1,"screen":"MBP","area":{"x":0,"y":0,"width":1,"height":1}},{"bundleID":"a","desktop":2,"screen":"MBP","area":{"x":0,"y":0,"width":1,"height":1}}]}"#.utf8)
        do { _ = try LayoutStore.decode(duplicate); throw CheckFailure(description: "accepted duplicates") }
        catch let e as LayoutStoreError { try expectEqual(e, .invalidLayout) }
    }),
    ("corrupt current layout never overwrites the good previous copy", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir); try store.save(Layouts()); try store.save(Layouts())
        let previous = try Data(contentsOf: store.previous)
        let corrupt = Data(#"{"schema":2,"setups":"broken"}"#.utf8); try corrupt.write(to: store.file)
        do { try store.save(Layouts()); throw CheckFailure(description: "overwrote corruption") }
        catch is DecodingError {}
        try expectEqual(try Data(contentsOf: store.previous), previous)
        try expectEqual(try Data(contentsOf: store.file), corrupt)
    }),
    ("explicit recovery validates backup and preserves the corrupt current file", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir); try store.save(Layouts()); try store.save(Layouts())
        let corrupt = Data("broken".utf8); try corrupt.write(to: store.file)
        try store.restorePrevious(); try expectEqual(try store.load(), Layouts())
        let archives = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("layouts.before-recovery") }
        try expectEqual(archives.count, 1); try expectEqual(try Data(contentsOf: archives[0]), corrupt)
        let newer = Data("{\"schema\":999,\"setups\":{}}".utf8); try newer.write(to: store.file)
        do { try store.restorePrevious(); throw CheckFailure(description: "overwrote newer schema") }
        catch let e as LayoutStoreError { try expectEqual(e, .newerSchema(999)) }
        try expectEqual(try Data(contentsOf: store.file), newer)
    }),
    ("save creates nested state folder", {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir.appendingPathComponent("nested/state")); try store.save(Layouts())
        try expectEqual(try store.load(), Layouts())
    }),
    ("manual unknown-desktop layout is separate from Desktop 1", {
        var l = Layouts(); let setup = ScreenSetup(screens: [laptop])
        l.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 0, screen: laptop.uuid)
        try expect(l.arrangement(setup: setup, desktop: 1, screen: laptop.uuid) == nil, "isolated fallback")
        try expectEqual(try LayoutStore.decode(JSONEncoder().encode(l)), l)
    }),
    ("no desktop adapter means no automatic start or new-window action", {
        var t = TriggerState()
        try expectEqual(t.handle(.start(screens: ["MBP"], displays: [])), .none)
        try expectEqual(t.handle(.windowCreated), .none)
        try expectEqual(t.handle(.screensSettled(displays: [])), .none)
    }),
    ("invalid movement frames never reach the Accessibility mover", {
        let f = Frame(x: 100, y: 100, width: 400, height: 300)
        let mover = FakeMover([window(1, term, "A", 0, f)])
        let p = Plan(moves: [Move(windowID: 1, from: f, to: Frame(x: .infinity, y: 0, width: -1, height: 0))], skipped: [], unchanged: 0)
        try expectEqual(applyPlan(p, mover: mover).failed, 1)
        try expectEqual(mover.sets, [])
    })
]
