import Foundation

/// A single screen on one desktop within the complete connected-display setup.
public struct WorkspaceSelection: Equatable, Sendable {
    public var screenUUID: String
    public var desktop: Int
    public init(screenUUID: String, desktop: Int) { self.screenUUID = screenUUID; self.desktop = desktop }
    public func isVisible(desktops: [String: Int]) -> Bool { desktops[screenUUID] == desktop }
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case screenDisconnected, desktopNotVisible, noWindows
    public var description: String {
        switch self {
        case .screenDisconnected: return "The selected screen is no longer connected."
        case .desktopNotVisible: return "Switch to the selected desktop on this screen first."
        case .noWindows: return "No eligible windows are visible on the selected screen and desktop."
        }
    }
}

/// Capture only this pair. All other screens, desktops and display setups remain untouched.
public func captureWorkspace(_ selection: WorkspaceSelection, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) throws -> ScreenArrangement {
    guard let screen = screens.first(where: { $0.uuid == selection.screenUUID }) else { throw WorkspaceError.screenDisconnected }
    guard selection.isVisible(desktops: desktops) else { throw WorkspaceError.desktopNotVisible }
    let mine = windows.filter { $0.screenUUID == selection.screenUUID }
    guard !mine.isEmpty else { throw WorkspaceError.noWindows }
    return remember(mine, on: screen)
}

/// An immediate grid is a draft: it moves only this screen's currently visible windows and writes no file.
public func planAutomaticWorkspace(_ selection: WorkspaceSelection, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) throws -> Plan {
    guard let screen = screens.first(where: { $0.uuid == selection.screenUUID }) else { throw WorkspaceError.screenDisconnected }
    guard selection.isVisible(desktops: desktops) else { throw WorkspaceError.desktopNotVisible }
    let mine = windows.filter { $0.screenUUID == selection.screenUUID }
        .sorted { ($0.bundleID, $0.order, $0.windowID) < ($1.bundleID, $1.order, $1.windowID) }
    guard !mine.isEmpty else { throw WorkspaceError.noWindows }
    var plan = Plan(moves: [], skipped: [], unchanged: 0, tiles: [mine.map(\.windowID)])
    for (w, frame) in zip(mine, gridTile(mine.count, in: screen.visibleFrame)) {
        if close(w.frame, frame) { plan.unchanged += 1 }
        else { plan.moves.append(Move(windowID: w.windowID, from: w.frame, to: frame)) }
    }
    return plan
}

/// Restore exactly one pair using the original setup key, with no matching across other screens.
public func planWorkspace(_ layouts: Layouts, selection: WorkspaceSelection, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int]) throws -> Plan? {
    guard screens.contains(where: { $0.uuid == selection.screenUUID }) else { throw WorkspaceError.screenDisconnected }
    guard selection.isVisible(desktops: desktops) else { throw WorkspaceError.desktopNotVisible }
    return planRestore(layouts, windows: windows, screens: screens, desktops: desktops, scope: selection)
}
