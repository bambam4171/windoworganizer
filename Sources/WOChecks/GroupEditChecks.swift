import Foundation
import WindowOrganizerCore

private func group(_ id: String, _ name: String, members: [ZoneMember] = [ZoneMember(bundleID: "com.a")], mode: GroupMode = .tiled) -> WindowGroup {
    WindowGroup(id: id, name: name, members: members, screen: "S1", desktops: [1], mode: mode)
}

private let screen = ScreenInfo(uuid: "S1", name: "Main", frame: Frame(x: 0, y: 0, width: 1000, height: 800),
                                visibleFrame: Frame(x: 0, y: 25, width: 1000, height: 775))

private func window(_ id: Int, _ bundle: String, _ title: String, _ frame: Frame, order: Int, screen: String = "S1") -> WindowInfo {
    WindowInfo(windowID: id, bundleID: bundle, title: title, frame: frame, screenUUID: screen, order: order)
}

let groupEditChecks: [(String, @Sendable () throws -> Void)] = [
    ("group edit: capture takes the matching windows of that screen, fractions of the visible frame, order per member", {
        let g = group("g", "Work", members: [ZoneMember(bundleID: "com.a"), ZoneMember(bundleID: "com.b", titlePattern: "Docs*")])
        let windows = [
            window(1, "com.a", "one", Frame(x: 0, y: 25, width: 500, height: 775), order: 0),
            window(2, "com.a", "two", Frame(x: 500, y: 25, width: 500, height: 775), order: 1),
            window(3, "com.b", "Docs main", Frame(x: 250, y: 412.5, width: 500, height: 387.5), order: 0),
            window(4, "com.b", "Mail", Frame(x: 0, y: 25, width: 100, height: 100), order: 1),
            window(5, "com.a", "elsewhere", Frame(x: 0, y: 25, width: 500, height: 775), order: 2, screen: "S2"),
            window(6, "com.c", "other app", Frame(x: 0, y: 25, width: 100, height: 100), order: 0)]
        let got = capturePositions(g, windows: windows, screen: screen)
        try expectEqual(got.count, 3)
        try expectEqual(got[0].matcher, Matcher(bundleID: "com.a", titlePattern: nil, seenTitle: "one", order: 0))
        try expectEqual(got[1].matcher, Matcher(bundleID: "com.a", titlePattern: nil, seenTitle: "two", order: 1))
        try expectEqual(got[2].matcher, Matcher(bundleID: "com.b", titlePattern: "Docs*", seenTitle: "Docs main", order: 0))
        try expectEqual(got[1].fraction, UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        try expectEqual(got[2].fraction, UnitRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        var l = Layouts(); var saved = g; saved.mode = .saved(got); l.setGroup(saved)
        try l.validate()
    }),
    ("group edit: a window matching two members goes to the first, and an overhanging frame is clamped", {
        let g = group("g", "Work", members: [ZoneMember(bundleID: "com.a", titlePattern: "Doc*"), ZoneMember(bundleID: "com.a")])
        let windows = [window(1, "com.a", "Doc one", Frame(x: -200, y: -50, width: 1500, height: 700), order: 0),
                       window(2, "com.a", "Notes", Frame(x: 0, y: 25, width: 400, height: 400), order: 1)]
        let got = capturePositions(g, windows: windows, screen: screen)
        try expectEqual(got.count, 2)
        try expectEqual(got[0].matcher.titlePattern, "Doc*")
        try expectEqual(got[1].matcher.titlePattern, nil)
        try expectEqual(got[1].matcher.order, 0)
        try expect(got[0].fraction.isWithinUnit, "\(got[0].fraction)")
        try expectEqual(got[0].fraction.width, 1)
        var l = Layouts(); var saved = g; saved.mode = .saved(got); l.setGroup(saved)
        try l.validate()
    }),
    ("group edit: capture with no matching window returns nothing", {
        let g = group("g", "Work")
        try expectEqual(capturePositions(g, windows: [window(1, "com.z", "x", Frame(x: 0, y: 25, width: 10, height: 10), order: 0)], screen: screen).count, 0)
    }),
    ("group edit: name problems are empty, too long and duplicate (trimmed, any case), not against itself", {
        let all = [group("a", "Work"), group("b", "Chat")]
        try expect(WindowGroup.nameProblem("  ", id: "a", in: all) != nil, "empty")
        try expect(WindowGroup.nameProblem(String(repeating: "x", count: 101), id: "a", in: all) != nil, "long")
        try expect(WindowGroup.nameProblem(String(repeating: "x", count: 100), id: "a", in: all) == nil, "100 is fine")
        try expect(WindowGroup.nameProblem("work ", id: "b", in: all) != nil, "duplicate")
        try expect(WindowGroup.nameProblem("WORK", id: "a", in: all) == nil, "its own name")
        try expect(WindowGroup.nameProblem("Fresh", id: "new", in: all) == nil, "free name")
    }),
    ("group edit: removing a member drops only its positions; the last position gone makes the group tiled", {
        let pa = GroupPosition(matcher: Matcher(bundleID: "com.a"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let pb = GroupPosition(matcher: Matcher(bundleID: "com.b", titlePattern: "X*"), fraction: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let g = group("g", "Work", members: [ZoneMember(bundleID: "com.a"), ZoneMember(bundleID: "com.b", titlePattern: "X*")], mode: .saved([pa, pb]))
        let one = g.removingMember(at: 0)
        try expectEqual(one.members, [ZoneMember(bundleID: "com.b", titlePattern: "X*")])
        try expectEqual(one.mode, .saved([pb]))
        let none = one.removingMember(at: 0)
        try expectEqual(none.members.count, 0)
        try expectEqual(none.mode, .tiled)
        try expectEqual(g.removingMember(at: 9), g)
    }),
    ("group edit: replaceGroups drops groups without apps and counts them, keeps the rest in order", {
        var l = Layouts()
        let dropped = l.replaceGroups([group("a", "One"), group("b", "Two", members: []), group("c", "Three")])
        try expectEqual(dropped, 1)
        try expectEqual(l.groups.map(\.id), ["a", "c"])
        try l.validate()
    }),
    ("group edit: deleting every group writes schema 2 with no groups key, other data kept", {
        var l = Layouts(); l.replaceGroups([group("a", "One")])
        l.replaceGroups([])
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let text = String(decoding: try enc.encode(l), as: UTF8.self)
        try expect(text.contains("\"schema\":2") && !text.contains("groups"), text)
    }),
]
