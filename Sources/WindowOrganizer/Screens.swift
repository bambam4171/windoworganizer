import AppKit
import WindowOrganizerCore

// Screens (plan §1): NSScreen in AX's top-left coordinates, keyed by the display UUID, which survives replugging.

@MainActor
func currentScreens() -> [ScreenInfo] {
    let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
    return NSScreen.screens.compactMap { s in
        guard let number = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        func flip(_ r: NSRect) -> Frame {
            Geometry.topLeft(Frame(x: r.minX, y: r.minY, width: r.width, height: r.height), primaryHeight: primaryHeight)
        }
        return ScreenInfo(uuid: text, name: s.localizedName, frame: flip(s.frame), visibleFrame: flip(s.visibleFrame))
    }
}
