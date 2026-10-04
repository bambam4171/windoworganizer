import Foundation
import WindowOrganizerCore

// WO-LAUNCH-MISSING (Zeus design Z-417, addendum Z-424): which apps a restore starts, the trigger defaults, the result lines.

private let launchSetup = ScreenSetup(screens: [laptop, dell])
private let lMail = "com.apple.mail", lNotes = "com.apple.Notes", lSafari = "com.apple.Safari"

private func place(_ bundle: String, on screen: ScreenInfo) -> Placement {
    Placement(matcher: Matcher(bundleID: bundle, seenTitle: "", order: 0), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1),
              pixel: Frame(x: 0, y: 0, width: 100, height: 100), screenUUID: screen.uuid, visibleFrame: screen.visibleFrame)
}

private func layouts(_ kind: ScreenArrangement.Kind, settings: ArrangeSettings? = nil, rules: [AppRule] = [], screen: ScreenInfo = laptop) -> Layouts {
    var l = Layouts()
    l.set(ScreenArrangement(kind: kind), setup: launchSetup, desktop: 1, screen: screen.uuid)
    if let settings { l.setArrangeSettings(settings, desktop: 1, screen: screen.uuid) }
    for r in rules { l.setRule(r) }
    return l
}

private func start(_ l: Layouts, running: Set<String> = [], scope: WorkspaceSelection? = nil) -> [String] {
    appsToStart(l, screens: [laptop, dell], desktops: ["MBP": 1, "DELL": 1], scope: scope, running: running)
}

let launchChecks: [(String, @Sendable () throws -> Void)] = [
    ("a snapshot's app that is not running is started (launch)", {
        try expectEqual(start(layouts(.snapshot([place(lMail, on: laptop)]))), [lMail])
    }),
    ("a running app is never started, with or without a window (launch)", {
        try expectEqual(start(layouts(.snapshot([place(lMail, on: laptop)])), running: [lMail]), [])
    }),
    ("a zone member that is not running is started (launch)", {
        let zone = Zone(rect: UnitRect(x: 0, y: 0, width: 1, height: 1), members: [ZoneMember(bundleID: lNotes), ZoneMember(bundleID: lMail)])
        try expectEqual(start(layouts(.zones([zone])), running: [lMail]), [lNotes])
    }),
    ("an app with an active rule is not started (launch)", {
        let rule = AppRule(bundleID: lMail, desktop: 1, screen: "MBP", area: AppRule.full)
        try expectEqual(start(layouts(.snapshot([place(lMail, on: laptop), place(lNotes, on: laptop)]), rules: [rule])), [lNotes])
    }),
    ("an app on two screens is listed once, in order of first appearance (launch)", {
        var l = layouts(.snapshot([place(lNotes, on: laptop), place(lMail, on: laptop)]))
        l.set(ScreenArrangement(kind: .snapshot([place(lMail, on: dell), place(lSafari, on: dell)])), setup: launchSetup, desktop: 1, screen: "DELL")
        try expectEqual(start(l), [lNotes, lMail, lSafari])
    }),
    ("an autoTile screen has nothing to start (launch)", {
        try expectEqual(start(layouts(.autoTile)), [])
    }),
    ("the four triggers default to on, on, on and off (launch)", {
        try expectEqual(LaunchTrigger.allCases.map(\.rawValue), ["restore", "applySave", "screenPlug", "login"])
        try expectEqual(LaunchTrigger.allCases.map(\.defaultOn), [true, true, true, false])
    }),
    ("a screen that was not there before is a plug, a wake or an unplug is not (launch)", {
        try expect(gainedScreen(previous: ["MBP"], current: ["MBP", "DELL"]), "a new screen")
        try expect(!gainedScreen(previous: ["MBP", "DELL"], current: ["MBP", "DELL"]), "a wake or a resolution change")
        try expect(!gainedScreen(previous: ["MBP", "DELL"], current: ["MBP"]), "an unplug")
        try expect(gainedScreen(previous: ["MBP", "DELL"], current: ["MBP", "TV"]), "one out, one in")
        try expect(gainedScreen(previous: [], current: ["MBP"]), "from nothing")
    }),
    ("the scope keeps the other screen's apps out (launch)", {
        var l = layouts(.snapshot([place(lMail, on: laptop)]))
        l.set(ScreenArrangement(kind: .snapshot([place(lNotes, on: dell)])), setup: launchSetup, desktop: 1, screen: "DELL")
        try expectEqual(start(l, scope: WorkspaceSelection(screenUUID: "DELL", desktop: 1)), [lNotes])
        try expectEqual(start(l, scope: WorkspaceSelection(screenUUID: "MBP", desktop: 2)), [])
    }),
    ("a file with the S1 keys loads, and an untouched file stays byte-identical (launch)", {
        try expectEqual(String(decoding: try JSONEncoder().encode(ArrangeSettings()), as: UTF8.self), "{}")
        let old = try JSONDecoder().decode(ArrangeSettings.self, from: Data(#"{"gap":4,"launchOnRestore":false,"launchOnTrigger":true}"#.utf8))
        try expectEqual(old, ArrangeSettings(gap: 4))
    }),
    ("the restore line names the apps it starts (launch)", {
        let r = ApplyResult(placed: 2, keptMinimum: 0, failed: 0, unchanged: 0, notOpen: 2)
        try expectEqual(ResultLine.restored(r, starting: ["Mail", "Notes"], desktop: 2, at: "17:41"), "Desktop 2: 2 windows placed, 2 not open, starting Mail, Notes · 17:41")
        try expectEqual(ResultLine.restored(r, desktop: 2, at: "17:41"), "Desktop 2: 2 windows placed, 2 not open · 17:41")
    }),
    ("the started line, every case (launch)", {
        try expectEqual(ResultLine.started(names: ["Mail", "Notes"], placed: 3, late: ["Notes"], desktop: 2, at: "17:41"),
                        "Desktop 2: started Mail and Notes, 3 windows placed; Notes did not open a window within 20 s · 17:41")
        try expectEqual(ResultLine.started(names: ["Mail"], placed: 1, desktop: 1, at: "09:05"), "Desktop 1: started Mail, 1 window placed · 09:05")
        try expectEqual(ResultLine.started(names: ["Mail", "Notes", "Safari"], placed: 0, desktop: 1, at: "09:05"),
                        "Desktop 1: started Mail, Notes and Safari, 0 windows placed · 09:05")
        try expectEqual(ResultLine.started(names: ["Mail"], placed: 1, failed: ["Foo"], desktop: 1, at: "09:05"),
                        "Desktop 1: started Mail, 1 window placed; Foo could not be started · 09:05")
        try expectEqual(ResultLine.started(names: ["Mail"], placed: 0, stopped: true, desktop: nil, at: "09:05"),
                        "Desktop unknown: started Mail, 0 windows placed; stopped placing: the desktop changed · 09:05")
        try expectEqual(ResultLine.started(names: [], placed: 0, failed: ["Foo"], desktop: 1, at: "09:05"), "Desktop 1: Foo could not be started · 09:05")
        try expectEqual(ResultLine.started(names: [], placed: 0, desktop: 1, at: "09:05"), "Desktop 1: nothing started · 09:05")
    }),
]
