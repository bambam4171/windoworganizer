import Foundation

// WO-LAUNCH-MISSING (Zeus design Z-417, addendum Z-424): which apps a restore starts, and which triggers may start them. Pure core.

/// The four moments that may start missing apps. Each is an app-wide switch in Settings.
public enum LaunchTrigger: String, CaseIterable, Sendable {
    /// The menu's and the editor's Restore.
    case restore
    /// "Apply & Save" in the editor.
    case applySave
    /// A display that was not there at the previous settle. Never a wake, a resolution change or an unplug.
    case screenPlug
    /// `.start`: every app start, not only a login.
    case login
    // STUB (red run): all off, gainedScreen never true
    public var defaultOn: Bool { false }
}

/// True only when a screen UUID appears that the previous settle did not have.
public func gainedScreen(previous: Set<String>, current: Set<String>) -> Bool { false }

/// The bundle IDs of the apps a layout needs that are not running, for the screens in scope.
public func appsToStart(_ layouts: Layouts, screens: [ScreenInfo], desktops: [String: Int], scope: WorkspaceSelection? = nil,
                        running: Set<String>) -> [String] {
    let setup = ScreenSetup(screens: screens)
    let eligible = scope.map { selected in screens.filter { $0.uuid == selected.screenUUID && desktops[$0.uuid] == selected.desktop } } ?? screens
    // An active rule decides where its app goes: the app is not a member of any layout (as in planRestore).
    let ruled = Set(layouts.rules.filter { rule in eligible.contains { $0.uuid == rule.screen && desktops[$0.uuid] == rule.desktop } }.map(\.bundleID))
    var wanted: [String] = []
    for screen in eligible {
        guard let desktop = desktops[screen.uuid],
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
