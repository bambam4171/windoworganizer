import Foundation

// WO-LAUNCH-MISSING S1 (Zeus design Z-417): which apps a restore starts. Pure core.

/// The bundle IDs of the apps a layout needs that are not running, for the screens in scope whose setting allows it.
public func appsToStart(_ layouts: Layouts, screens: [ScreenInfo], desktops: [String: Int], scope: WorkspaceSelection? = nil,
                        running: Set<String>, automatic: Bool) -> [String] {
    []
}
