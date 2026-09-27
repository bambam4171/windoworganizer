import AppKit
import WindowOrganizerCore

// Which desktop is active (plan §3). The public API has no Space ID; SkyLight's private read calls do.
// Loaded through dlsym, so a missing symbol on a future macOS degrades to "Desktop unknown" instead of crashing.
// Read-only: the app never moves any window between desktops.
enum SkyLight {
    typealias MainConn = @convention(c) () -> Int32
    typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    typealias ManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static var connection: Int32? { sym("SLSMainConnectionID", MainConn.self)?() }

    static func activeSpace() -> UInt64? {
        guard let c = connection, let f = sym("SLSGetActiveSpace", ActiveSpace.self) else { return nil }
        return f(c)
    }

    /// One entry per display, its Spaces in Mission Control order. "Main" stands for the main display's UUID.
    static func displaySpaces(mainUUID: String?) -> [DisplaySpaces] {
        guard let c = connection, let f = sym("SLSCopyManagedDisplaySpaces", ManagedSpaces.self),
              let arr = f(c)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr.map { d in
            let cur = ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            let all = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            var id = d["Display Identifier"] as? String ?? "?"
            if id == "Main", let mainUUID { id = mainUUID }
            return DisplaySpaces(display: id, current: cur, spaces: all)
        }
    }

    @MainActor
    static func desktop(screens: [ScreenInfo]) -> DesktopPosition? {
        desktopPosition(active: activeSpace(), displays: displaySpaces(mainUUID: screens.first?.uuid))
    }
}
