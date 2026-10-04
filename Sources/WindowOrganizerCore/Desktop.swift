import Foundation

// Reading the Mac (plan §3, §4), the pure half: the app feeds in what AX, NSScreen and SkyLight report.

public enum Geometry {
    /// NSScreen frames have their origin bottom-left of the primary screen; AX frames top-left. Same x, flipped y.
    public static func topLeft(_ frame: Frame, primaryHeight: Double) -> Frame {
        Frame(x: frame.x, y: primaryHeight - frame.y - frame.height, width: frame.width, height: frame.height)
    }
}

/// The screen a window is on: the one holding its centre, else the one it overlaps most, else nil (off-screen).
public func screenUUID(for window: Frame, in screens: [ScreenInfo]) -> String? {
    let r = window.rect
    let centre = CGPoint(x: r.midX, y: r.midY)
    if let s = screens.first(where: { $0.frame.rect.contains(centre) }) { return s.uuid }
    let overlaps = screens.map { s -> (String, CGFloat) in
        let i = s.frame.rect.intersection(r)
        return (s.uuid, i.isNull ? 0 : i.width * i.height)
    }
    guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
    return best.0
}

public enum WindowFilter {
    /// Dialogs, palettes, sheets, full-screen and minimised windows are never arranged.
    public static func counts(subrole: String, fullScreen: Bool, minimized: Bool) -> Bool {
        subrole == "AXStandardWindow" && !fullScreen && !minimized
    }
}

/// One display's desktops as SkyLight lists them, in Mission Control order.
public struct DisplaySpaces: Equatable, Sendable {
    public var display: String
    public var current: UInt64
    public var spaces: [UInt64]

    public init(display: String, current: UInt64, spaces: [UInt64]) {
        self.display = display; self.current = current; self.spaces = spaces
    }
}

public struct DesktopPosition: Codable, Equatable, Sendable {
    public var display: String
    /// 1-based, as Mission Control numbers desktops; the layout key (Space IDs change when desktops are recreated).
    public var number: Int

    public init(display: String, number: Int) { self.display = display; self.number = number }
}

public func desktopPosition(active: UInt64?, displays: [DisplaySpaces]) -> DesktopPosition? {
    guard let active else { return nil }
    for d in displays {
        if let i = d.spaces.firstIndex(of: active) { return DesktopPosition(display: d.display, number: i + 1) }
    }
    return nil
}

public enum StatusLine {
    public static func text(trusted: Bool, desktop: DesktopPosition?, windows: Int, screens: Int) -> String {
        if !trusted { return "Permission needed: Accessibility" }
        let where_ = desktop.map { "Desktop \($0.number)" } ?? "Desktop unknown"
        return "\(where_) · \(plural(windows, "window")) on \(plural(screens, "screen"))"
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

/// What `WindowOrganizer --list` prints: the live check's evidence, read-only.
public struct ListReport: Codable, Equatable, Sendable {
    public var trusted: Bool
    public var desktop: DesktopPosition?
    public var screens: [ScreenInfo]
    public var windows: [WindowInfo]

    public init(trusted: Bool, desktop: DesktopPosition?, screens: [ScreenInfo], windows: [WindowInfo]) {
        self.trusted = trusted; self.desktop = desktop; self.screens = screens; self.windows = windows
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
