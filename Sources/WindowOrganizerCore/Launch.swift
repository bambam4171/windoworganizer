import Foundation

// WO-LAUNCH-MISSING S1 (Zeus design Z-417): which apps a restore starts. Pure core.

/// The bundle IDs of the apps a layout needs that are not running, for the screens in scope whose setting allows it.
public func appsToStart(_ layouts: Layouts, screens: [ScreenInfo], desktops: [String: Int], scope: WorkspaceSelection? = nil,
                        running: Set<String>, automatic: Bool) -> [String] {
    let setup = ScreenSetup(screens: screens)
    let eligible = scope.map { selected in screens.filter { $0.uuid == selected.screenUUID && desktops[$0.uuid] == selected.desktop } } ?? screens
    // An active rule decides where its app goes: the app is not a member of any layout (as in planRestore).
    let ruled = Set(layouts.rules.filter { rule in eligible.contains { $0.uuid == rule.screen && desktops[$0.uuid] == rule.desktop } }.map(\.bundleID))
    var wanted: [String] = []
    for screen in eligible {
        guard let desktop = desktops[screen.uuid],
              layouts.arrangeSettings(desktop: desktop, screen: screen.uuid).allowsStart(automatic: automatic),
              let arrangement = layouts.arrangement(setup: setup, desktop: desktop, screen: screen.uuid) else { continue }
        switch arrangement.kind {
        case .snapshot(let places): wanted += places.map(\.matcher.bundleID)
        case .zones(let zones): wanted += zones.flatMap { $0.members.map(\.bundleID) }
        case .autoTile: break
        }
    }
    var seen = Set<String>()
    return wanted.filter { !ruled.contains($0) && !running.contains($0) && seen.insert($0).inserted }
}

extension ArrangeSettings {
    fileprivate func allowsStart(automatic: Bool) -> Bool { automatic ? startsMissingOnTrigger : startsMissingOnRestore }
}
