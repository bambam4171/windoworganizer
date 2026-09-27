import Foundation
import WindowOrganizerCore

// WO-S1 (plan §1, §2): the pure core. No Accessibility and no windows: every rule is checked on plain values.

let laptop = ScreenInfo(uuid: "MBP", name: "Built-in",
                        frame: Frame(x: 0, y: 0, width: 1512, height: 982),
                        visibleFrame: Frame(x: 0, y: 33, width: 1512, height: 949))
let dell = ScreenInfo(uuid: "DELL", name: "DELL U2723QE",
                      frame: Frame(x: 1512, y: 0, width: 2560, height: 1440),
                      visibleFrame: Frame(x: 1512, y: 25, width: 2560, height: 1415))

func window(_ id: Int, _ app: String, _ title: String, _ order: Int, _ frame: Frame, on screen: ScreenInfo = laptop) -> WindowInfo {
    WindowInfo(windowID: id, bundleID: app, title: title, frame: frame, screenUUID: screen.uuid, order: order)
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wochecks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let term = "com.apple.Terminal", safari = "com.apple.Safari", mail = "com.apple.mail"

let coreChecks: [(String, @Sendable () throws -> Void)] = [
    ("screen setup key is the sorted display UUIDs", {
        try expectEqual(ScreenSetup(screens: [dell, laptop]).key, "DELL+MBP")
        try expectEqual(ScreenSetup(screens: [laptop]).key, "MBP")
    }),
    ("title pattern: contains, wildcard, case-insensitive", {
        try expect(Matcher(bundleID: term, titlePattern: "build").matches(title: "~/src — Build log"), "contains")
        try expect(Matcher(bundleID: term, titlePattern: "*.swift — *").matches(title: "Frame.swift — WO"), "wildcard")
        try expect(!Matcher(bundleID: term, titlePattern: "*.swift").matches(title: "Frame.swift — WO"), "wildcard anchors the end")
        try expect(Matcher(bundleID: term).matches(title: "anything"), "no pattern matches all")
    }),
    ("match: pinned pattern first, then order; each window claimed once; unknown app untouched", {
        let windows = [
            window(1, term, "logs", 0, Frame(x: 0, y: 40, width: 400, height: 300)),
            window(2, term, "server", 1, Frame(x: 0, y: 40, width: 400, height: 300)),
            window(3, term, "build", 2, Frame(x: 0, y: 40, width: 400, height: 300)),
            window(4, mail, "Inbox", 0, Frame(x: 0, y: 40, width: 400, height: 300)),
        ]
        let matchers = [
            Matcher(bundleID: term, titlePattern: "build", order: 0),
            Matcher(bundleID: term, order: 0),
            Matcher(bundleID: term, order: 0),
            Matcher(bundleID: term, order: 0),
            Matcher(bundleID: safari, order: 0),
        ]
        let m = matchWindows(matchers, windows)
        try expectEqual(m.assigned.map { $0?.windowID }, [3, 1, 2, nil, nil])
    }),
    ("match by order: the place's order first, else the oldest left", {
        let windows = [window(1, term, "a", 0, Frame(x: 0, y: 40, width: 10, height: 10)),
                       window(2, term, "b", 1, Frame(x: 0, y: 40, width: 10, height: 10))]
        let m = matchWindows([Matcher(bundleID: term, order: 1), Matcher(bundleID: term, order: 1)], windows)
        try expectEqual(m.assigned.map { $0?.windowID }, [2, 1])
    }),
    ("remember then plan on the same screen moves nothing", {
        let windows = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500)),
                       window(2, safari, "b", 0, Frame(x: 720, y: 50, width: 780, height: 900))]
        let snap = remember(windows, on: laptop)
        let p = planSnapshot(snap, windows: windows, screen: laptop)
        try expectEqual(p.moves.count, 0)
        try expectEqual(p.unchanged, 2)
    }),
    ("plan on the same screen restores the exact pixel frame", {
        let saved = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500))]
        let snap = remember(saved, on: laptop)
        let moved = [window(1, term, "a", 0, Frame(x: 300, y: 300, width: 200, height: 200))]
        let p = planSnapshot(snap, windows: moved, screen: laptop)
        try expectEqual(p.moves, [Move(windowID: 1, from: moved[0].frame, to: Frame(x: 10, y: 50, width: 700, height: 500))])
    }),
    ("plan on a screen with another visible area scales the fraction", {
        let saved = [window(1, term, "a", 0, Frame(x: 0, y: 33, width: 756, height: 474.5))]   // left half, top half
        let snap = remember(saved, on: laptop)
        var bigger = laptop
        bigger.frame = Frame(x: 0, y: 0, width: 1728, height: 1117)
        bigger.visibleFrame = Frame(x: 0, y: 37, width: 1728, height: 1080)
        let p = planSnapshot(snap, windows: saved, screen: bigger)
        try expectEqual(p.moves.map(\.to), [Frame(x: 0, y: 37, width: 864, height: 540)])
    }),
    ("within 1 pt counts as unchanged; a place with no window is skipped", {
        let saved = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500)),
                     window(2, mail, "Inbox", 0, Frame(x: 720, y: 50, width: 700, height: 500))]
        let snap = remember(saved, on: laptop)
        let now = [window(1, term, "a", 0, Frame(x: 10.6, y: 50, width: 700, height: 499.4))]
        let p = planSnapshot(snap, windows: now, screen: laptop)
        try expectEqual(p.moves.count, 0)
        try expectEqual(p.unchanged, 1)
        try expectEqual(p.skipped.map(\.bundleID), [mail])
    }),
    ("layouts round-trip through JSON", {
        var layouts = Layouts()
        let setup = ScreenSetup(screens: [laptop, dell])
        layouts.set(remember([window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500))], on: laptop),
                    setup: setup, desktop: 2, screen: laptop.uuid)
        let data = try JSONEncoder().encode(layouts)
        let back = try JSONDecoder().decode(Layouts.self, from: data)
        try expectEqual(back, layouts)
        try expect(back.arrangement(setup: setup, desktop: 2, screen: laptop.uuid) != nil, "stored under setup × desktop × screen")
        try expect(back.arrangement(setup: ScreenSetup(screens: [laptop]), desktop: 2, screen: laptop.uuid) == nil,
                   "another setup starts empty")
    }),
    ("an unknown arrangement kind is refused with its name", {
        let json = #"{"schema":1,"setups":{"MBP":{"1":{"MBP":{"kind":"spiral"}}}}}"#
        do { _ = try JSONDecoder().decode(Layouts.self, from: Data(json.utf8)); throw CheckFailure(description: "decoded") }
        catch let e as DecodingError { try expect("\(e)".contains("spiral"), "names the kind: \(e)") }
    }),
    ("store: missing file is empty; save keeps the previous copy", {
        let dir = try tempDir()
        let store = LayoutStore(directory: dir)
        try expectEqual(try store.load(), Layouts())
        var a = Layouts()
        a.set(ScreenArrangement(kind: .snapshot([])), setup: ScreenSetup(screens: [laptop]), desktop: 1, screen: "MBP")
        try store.save(a)
        var b = a
        b.set(ScreenArrangement(kind: .snapshot([])), setup: ScreenSetup(screens: [laptop]), desktop: 3, screen: "MBP")
        try store.save(b)
        try expectEqual(try store.load(), b)
        let prev = try JSONDecoder().decode(Layouts.self, from: Data(contentsOf: dir.appendingPathComponent("layouts.prev.json")))
        try expectEqual(prev, a)
        let text = try String(contentsOf: dir.appendingPathComponent("layouts.json"), encoding: .utf8)
        try expect(text.contains("\n"), "human-readable (pretty printed)")
    }),
    ("store: a newer schema is refused and never overwritten", {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("layouts.json")
        let newer = #"{"schema":2,"setups":{}}"#
        try Data(newer.utf8).write(to: file)
        let store = LayoutStore(directory: dir)
        do { _ = try store.load(); throw CheckFailure(description: "loaded") }
        catch let e as LayoutStoreError { try expectEqual(e, .newerSchema(2)) }
        do { try store.save(Layouts()); throw CheckFailure(description: "saved") }
        catch let e as LayoutStoreError { try expectEqual(e, .newerSchema(2)) }
        try expectEqual(try String(contentsOf: file, encoding: .utf8), newer)
    }),
]
