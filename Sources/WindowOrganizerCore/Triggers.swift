import Foundation

// When the app arranges by itself (plan §3 triggers, §4 Pause). Pure: the app reports events and does what this answers.
// Pending desktops are kept by Space ID, in memory: IDs hold for a session, and a restart arranges from scratch anyway.

public enum TriggerEvent: Equatable, Sendable {
    /// The app started (at login or by hand).
    case start(screens: [String], displays: [DisplaySpaces])
    /// macOS reported a screen change; the list may be the same as before (the spike saw such events).
    case screensChanged(screens: [String])
    /// The screens held still for the settle time after a real change.
    case screensSettled(displays: [DisplaySpaces])
    /// The active desktop changed on some display.
    case spaceChanged(displays: [DisplaySpaces])
    /// An app created a window on the current desktop.
    case windowCreated
    /// AUTO-MODE: the set of windows changed (open, close or an app quit); the app asks AutoState per screen.
    case windowsChanged
}

public enum TriggerAction: Equatable, Sendable {
    case none
    /// Wait for the screens to settle (a new change restarts the wait), then report screensSettled.
    case settle
    /// Restore the current desktops.
    case arrange
    /// Move only the new window to its remembered place.
    case placeWindow
    /// Ask AutoState for each screen with Auto mode, then arrange that screen.
    case autoCheck
}

public struct TriggerState: Sendable {
    /// Pause in the menu: nothing is arranged by itself. Restore and Remember still work.
    public var paused = false
    /// Desktops not arranged since the start or the last screen change.
    public private(set) var pending: Set<UInt64> = []
    /// False when SkyLight lists no desktops: then only Restore arranges (plan §3 fallback).
    public private(set) var desktopsVisible = true
    private var screens: [String] = []

    public static let fallbackLine = "Desktop switching not visible: arranging on Restore only"
    public static let pausedLine = "Paused: nothing is arranged by itself · Restore still works"

    public init() {}

    public mutating func handle(_ event: TriggerEvent) -> TriggerAction {
        switch event {
        case .start(let screens, let displays):
            self.screens = screens.sorted()
            markOthersPending(displays)
            // Paused at start: the current desktops are not arranged either, so they wait like the rest.
            if paused { pending.formUnion(displays.map(\.current)); return .none }
            return desktopsVisible ? .arrange : .none
        case .screensChanged(let screens):
            let now = screens.sorted()
            guard now != self.screens else { return .none }
            self.screens = now
            return paused ? .none : .settle
        case .screensSettled(let displays):
            guard !paused else { return .none }
            markOthersPending(displays)
            return desktopsVisible ? .arrange : .none
        case .spaceChanged(let displays):
            guard !paused else { return .none }
            let here = Set(displays.map(\.current))
            guard !pending.isDisjoint(with: here) else { return .none }
            pending.subtract(here)
            return .arrange
        case .windowCreated:
            return paused || !desktopsVisible ? .none : .placeWindow
        case .windowsChanged:
            return paused || !desktopsVisible ? .none : .autoCheck
        }
    }

    private mutating func markOthersPending(_ displays: [DisplaySpaces]) {
        desktopsVisible = !displays.isEmpty
        pending = Set(displays.flatMap(\.spaces)).subtracting(displays.map(\.current))
    }
}
