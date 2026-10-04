import Foundation
import WindowOrganizerCore

// WO-S7 (plan §1 app rules, §8 S7): "Mail always on the Dell, Desktop 2", in every setup where the Dell is connected.

private let anyFrame = Frame(x: 900, y: 300, width: 400, height: 300)
private let dellArea = Frame(x: 1512, y: 25, width: 2560, height: 1415)
private let left = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
private func mailOnDell2(_ area: UnitRect = AppRule.full) -> Layouts {
    var l = Layouts()
    l.setRule(AppRule(bundleID: mail, desktop: 2, screen: "DELL", area: area))
    return l
}
private func plan(_ l: Layouts, _ ws: [WindowInfo], _ screens: [ScreenInfo] = [laptop, dell],
                  _ desktops: [String: Int] = ["MBP": 1, "DELL": 2]) -> Plan? {
    planRestore(l, windows: ws, screens: screens, desktops: desktops)
}

let ruleChecks: [(String, @Sendable () throws -> Void)] = [
    ("rules round-trip through JSON; no rules key when there are none; a file without it has none", {
        let l = mailOnDell2(left)
        let data = try JSONEncoder().encode(l)
        try expectEqual(try JSONDecoder().decode(Layouts.self, from: data), l)
        try expect(!String(decoding: try JSONEncoder().encode(Layouts()), as: UTF8.self).contains("rules"), "left out when empty")
        let old = #"{"schema":1,"setups":{}}"#
        try expectEqual(try JSONDecoder().decode(Layouts.self, from: Data(old.utf8)).rules, [])
    }),
    ("an active rule takes the app's windows from both screens and tiles them in its area", {
        let ws = [window(3, mail, "Inbox", 0, anyFrame), window(4, mail, "Draft", 1, anyFrame, on: dell),
                  window(1, term, "a", 0, anyFrame)]
        guard let p = plan(mailOnDell2(), ws) else { throw CheckFailure(description: "no plan with only a rule") }
        let t = tile(2, in: dellArea)
        try expectEqual(p.moves, [Move(windowID: 3, from: anyFrame, to: t[0]), Move(windowID: 4, from: anyFrame, to: t[1])])
        try expectEqual(p.tiles, [[3, 4]])
        try expectEqual(p.skipped, [])
    }),
    ("a rule whose screen shows another desktop does nothing", {
        let ws = [window(3, mail, "Inbox", 0, anyFrame)]
        try expect(plan(mailOnDell2(), ws, [laptop, dell], ["MBP": 1, "DELL": 1]) == nil, "inactive rule, nothing remembered")
        try expect(plan(mailOnDell2(), ws, [laptop, dell], ["MBP": 2]) == nil, "Dell desktop unknown")
    }),
    ("a rule for a screen that is not connected is ignored", {
        try expect(plan(mailOnDell2(), [window(3, mail, "Inbox", 0, anyFrame)], [laptop], ["MBP": 2]) == nil, "no Dell")
    }),
    ("the rule beats a snapshot place: moved by the rule, the place neither matched nor 'not open'", {
        let here = [window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500)),
                    window(3, mail, "Inbox", 0, Frame(x: 720, y: 50, width: 700, height: 500))]
        var l = mailOnDell2(left)
        l.set(remember(here, on: laptop), setup: ScreenSetup(screens: [laptop, dell]), desktop: 1, screen: "MBP")
        guard let p = plan(l, here) else { throw CheckFailure(description: "no plan") }
        try expectEqual(p.moves, [Move(windowID: 3, from: here[1].frame, to: left.frame(in: dellArea))])
        try expectEqual(p.unchanged, 1)
        try expectEqual(p.skipped, [])
        let gone = plan(l, [here[0]])
        try expectEqual(gone?.skipped, [])   // no Mail open: the ruled place is not "not open"
    }),
    ("the rule beats a zone member", {
        var l = mailOnDell2()
        l.set(ScreenArrangement(kind: .zones([Zone(rect: left, members: [ZoneMember(bundleID: mail), ZoneMember(bundleID: term)])])),
              setup: ScreenSetup(screens: [laptop, dell]), desktop: 1, screen: "MBP")
        let ws = [window(1, term, "a", 0, anyFrame), window(3, mail, "Inbox", 0, anyFrame)]
        guard let p = plan(l, ws) else { throw CheckFailure(description: "no plan") }
        try expectEqual(Set(p.tiles.map { $0 }), Set([[1], [3]]))
        try expectEqual(p.moves.first { $0.windowID == 1 }?.to, left.frame(in: laptop.visibleFrame))
        try expectEqual(p.moves.first { $0.windowID == 3 }?.to, dellArea)
    }),
    ("two windows tile inside a half area; one already there counts as unchanged", {
        let t = tile(2, in: left.frame(in: dellArea))
        let ws = [window(3, mail, "Inbox", 0, t[0], on: dell), window(4, mail, "Draft", 1, anyFrame)]
        guard let p = plan(mailOnDell2(left), ws) else { throw CheckFailure(description: "no plan") }
        try expectEqual(p.moves, [Move(windowID: 4, from: anyFrame, to: t[1])])
        try expectEqual(p.unchanged, 1)
    }),
    ("setRule replaces the app's rule, removeRule drops it", {
        var l = mailOnDell2()
        l.setRule(AppRule(bundleID: term, desktop: 1, screen: "MBP", area: AppRule.full))
        l.setRule(AppRule(bundleID: mail, desktop: 3, screen: "MBP", area: left))
        try expectEqual(l.rules, [AppRule(bundleID: mail, desktop: 3, screen: "MBP", area: left),
                                  AppRule(bundleID: term, desktop: 1, screen: "MBP", area: AppRule.full)])
        l.removeRule(mail)
        try expectEqual(l.rules.map(\.bundleID), [term])
        try expectEqual(l.rules(desktop: 1, screen: "MBP").map(\.bundleID), [term])
        try expectEqual(l.rules(desktop: 2, screen: "MBP"), [])
    }),
    ("a new window of a ruled app re-tiles the rule group only", {
        let ws = [window(3, mail, "Inbox", 0, dellArea, on: dell), window(5, mail, "New", 1, anyFrame),
                  window(1, term, "a", 0, anyFrame)]
        var l = mailOnDell2()
        l.set(ScreenArrangement(kind: .zones([Zone(rect: left, members: [ZoneMember(bundleID: term)])])),
              setup: ScreenSetup(screens: [laptop, dell]), desktop: 1, screen: "MBP")
        guard let p = plan(l, ws) else { throw CheckFailure(description: "no plan") }
        try expectEqual(Set(onlyWindow(p, 5).moves.map(\.windowID)), [3, 5])
    }),
]
