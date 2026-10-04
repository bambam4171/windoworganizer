import Foundation

// AUTO-MODE S1 (Zeus design D-1943): an open or close re-arranges one screen exactly as Restore would. Pure core:
// planAuto is planRestore for one screen, AutoState is the loop guard.

/// planRestore for the windows of one screen only. Nil when that screen has no arrangement (or rule) on its desktop.
/// Moves whose target centre lies off the screen are dropped, so nothing is pulled off it or onto another screen.
public func planAuto(_ layouts: Layouts, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int], screen: String) -> Plan? {
    guard let info = screens.first(where: { $0.uuid == screen }), let desktop = desktops[screen],
          var plan = planRestore(layouts, windows: windows, screens: screens, desktops: desktops,
                                 scope: WorkspaceSelection(screenUUID: screen, desktop: desktop)) else { return nil }
    let area = info.visibleFrame
    plan.moves.removeAll { move in
        let cx = move.to.x + move.to.width / 2, cy = move.to.y + move.to.height / 2
        return cx < area.x || cx > area.x + area.width || cy < area.y || cy > area.y + area.height
    }
    return plan
}

/// Remembers the window IDs last arranged per desktop and screen. Our own moves never change the set of listed
/// windows, so "arrange only when the set changed" is the loop guard.
public struct AutoState: Sendable {
    private var arranged: [String: Set<Int>] = [:]

    public init() {}

    public static func key(desktop: Int, screen: String) -> String { "\(desktop)|\(screen)" }

    /// True when `ids` differs from the last arranged set for `key`, or there is none yet; records the set.
    public mutating func shouldArrange(key: String, ids: Set<Int>) -> Bool {
        guard arranged[key] != ids else { return false }
        arranged[key] = ids
        return true
    }

    /// The switch went off: the next switch-on arranges again.
    public mutating func forget(key: String) { arranged[key] = nil }
}
