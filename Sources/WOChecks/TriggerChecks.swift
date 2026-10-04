import Foundation
import WindowOrganizerCore

// WO-S4 (plan §3, §4): when the app arranges by itself. Start, a screen plugged in or out (after it settles), arriving on
// a pending desktop, and Pause, which silences all of them.

private let mbp = DisplaySpaces(display: "MBP", current: 1, spaces: [1, 2, 3])
private let dellOn = DisplaySpaces(display: "DELL", current: 10, spaces: [10, 11])

let triggerChecks: [(String, @Sendable () throws -> Void)] = [
    ("start arranges the current desktops and marks every other one pending", {
        var t = TriggerState()
        try expectEqual(t.handle(.start(screens: ["MBP", "DELL"], displays: [mbp, dellOn])), .arrange)
        try expectEqual(t.pending, [2, 3, 11])
    }),
    ("arriving on a pending desktop arranges it once", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP"], displays: [mbp]))
        var on2 = mbp; on2.current = 2
        try expectEqual(t.handle(.spaceChanged(displays: [on2])), .arrange)
        try expectEqual(t.pending, [3])
        try expectEqual(t.handle(.spaceChanged(displays: [mbp])), .none)
        try expectEqual(t.handle(.spaceChanged(displays: [on2])), .none)
    }),
    ("a screen event with the same screens does nothing, in any order", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP", "DELL"], displays: [mbp, dellOn]))
        try expectEqual(t.handle(.screensChanged(screens: ["DELL", "MBP"])), .none)
    }),
    ("a plugged or unplugged screen waits to settle, then arranges and marks the rest pending", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP"], displays: [mbp]))
        var on2 = mbp; on2.current = 2
        _ = t.handle(.spaceChanged(displays: [on2]))
        try expectEqual(t.handle(.screensChanged(screens: ["MBP", "DELL"])), .settle)
        try expectEqual(t.handle(.screensSettled(displays: [on2, dellOn])), .arrange)
        try expectEqual(t.pending, [1, 3, 11])
        try expectEqual(t.handle(.screensChanged(screens: ["MBP"])), .settle)
    }),
    ("Pause silences every automatic trigger, and an unplug during Pause is not replayed", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP", "DELL"], displays: [mbp, dellOn]))
        t.paused = true
        var on2 = mbp; on2.current = 2
        try expectEqual(t.handle(.spaceChanged(displays: [on2])), .none)
        try expectEqual(t.handle(.screensChanged(screens: ["MBP"])), .none)
        try expectEqual(t.handle(.screensSettled(displays: [on2])), .none)
        t.paused = false
        try expectEqual(t.handle(.screensChanged(screens: ["MBP"])), .none)
        try expectEqual(t.pending, [2, 3, 11])
    }),
    ("start while paused arranges nothing but still marks desktops pending", {
        var t = TriggerState()
        t.paused = true
        try expectEqual(t.handle(.start(screens: ["MBP"], displays: [mbp])), .none)
        try expectEqual(t.pending, [1, 2, 3])
    }),
    ("without SkyLight the desktops are not visible and the status says so", {
        var t = TriggerState()
        _ = t.handle(.start(screens: ["MBP"], displays: []))
        try expect(!t.desktopsVisible, "desktops invisible")
        try expectEqual(TriggerState.fallbackLine, "Desktop switching not visible: arranging on Restore only")
        try expectEqual(t.handle(.spaceChanged(displays: [])), .none)
    }),
    ("the Pause line", {
        try expectEqual(TriggerState.pausedLine, "Paused: nothing is arranged by itself · Restore still works")
    }),
]
