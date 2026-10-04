import Foundation
import WindowOrganizerCore

let workspaceChecks: [(String, @Sendable () throws -> Void)] = [
    ("workspace capture includes only the selected screen", {
        let f = Frame(x: 10, y: 40, width: 400, height: 300)
        let ws = [window(1, term, "A", 0, f), window(2, term, "B", 0, f, on: dell)]
        let selected = WorkspaceSelection(screenUUID: laptop.uuid, desktop: 2)
        let captured = try captureWorkspace(selected, windows: ws, screens: [laptop, dell], desktops: [laptop.uuid: 2, dell.uuid: 1])
        try expectEqual(captured, remember([ws[0]], on: laptop))
    }),
    ("workspace capture rejects a desktop that is not visible", {
        do {
            _ = try captureWorkspace(WorkspaceSelection(screenUUID: laptop.uuid, desktop: 2), windows: [], screens: [laptop], desktops: [laptop.uuid: 1])
            throw CheckFailure(description: "accepted inactive desktop")
        } catch WorkspaceError.desktopNotVisible {}
    }),
    ("empty capture cannot erase a saved arrangement", {
        do {
            _ = try captureWorkspace(WorkspaceSelection(screenUUID: laptop.uuid, desktop: 1), windows: [], screens: [laptop], desktops: [laptop.uuid: 1])
            throw CheckFailure(description: "accepted empty capture")
        } catch WorkspaceError.noWindows {}
    }),
    ("workspace automatic grid moves only its screen", {
        let f = Frame(x: 10, y: 40, width: 400, height: 300)
        let ws = [window(1, term, "A", 0, f), window(2, term, "B", 1, f), window(3, term, "C", 0, f, on: dell)]
        let plan = try planAutomaticWorkspace(WorkspaceSelection(screenUUID: laptop.uuid, desktop: 1), windows: ws, screens: [laptop, dell], desktops: [laptop.uuid: 1, dell.uuid: 2])
        try expectEqual(Set(plan.moves.map(\.windowID)), [1, 2])
        try expectEqual(plan.tiles, [[1, 2]])
    }),
    ("scoped restore keeps complete setup key and never claims another screen's app", {
        let f = Frame(x: 10, y: 40, width: 400, height: 300)
        let ws = [window(1, term, "Same", 1, f), window(2, term, "Same", 0, f, on: dell)]
        let setup = ScreenSetup(screens: [laptop, dell]); var layouts = Layouts()
        layouts.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 2, screen: laptop.uuid)
        layouts.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: 1, screen: dell.uuid)
        let plan = try planWorkspace(layouts, selection: WorkspaceSelection(screenUUID: laptop.uuid, desktop: 2), windows: ws, screens: [laptop, dell], desktops: [laptop.uuid: 2, dell.uuid: 1])
        try expectEqual(plan?.moves.map(\.windowID), [1])
        try expectEqual(plan?.moves.first?.to, laptop.visibleFrame)
    }),
    ("scoped snapshot and app rules stay within the selected screen", {
        let f = Frame(x: 10, y: 40, width: 400, height: 300)
        let ws = [window(1, term, "Build", 1, f), window(2, term, "Build", 0, f, on: dell)]
        let setup = ScreenSetup(screens: [laptop, dell]); var layouts = Layouts()
        layouts.set(remember([window(1, term, "Build", 0, laptop.visibleFrame)], on: laptop), setup: setup, desktop: 1, screen: laptop.uuid)
        let select = WorkspaceSelection(screenUUID: laptop.uuid, desktop: 1)
        let desktops = [laptop.uuid: 1, dell.uuid: 1]
        var plan = try planWorkspace(layouts, selection: select, windows: ws, screens: [laptop, dell], desktops: desktops)
        try expectEqual(plan?.moves.map(\.windowID), [1])
        layouts.setRule(AppRule(bundleID: term, desktop: 1, screen: laptop.uuid, area: AppRule.full))
        plan = try planWorkspace(layouts, selection: select, windows: ws, screens: [laptop, dell], desktops: desktops)
        try expectEqual(plan?.moves.map(\.windowID), [1])
    })
]
