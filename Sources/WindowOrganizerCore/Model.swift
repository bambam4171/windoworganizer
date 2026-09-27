import Foundation

// The layout model (plan §1): one arrangement per screen setup × desktop × screen, stored as human-readable JSON.

/// A connected screen. `visibleFrame` is the area without the menu bar and the Dock, in the same top-left coordinates as `frame`.
public struct ScreenInfo: Codable, Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var frame: Frame
    public var visibleFrame: Frame

    public init(uuid: String, name: String, frame: Frame, visibleFrame: Frame) {
        self.uuid = uuid; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

/// The set of connected screens ("MacBook alone", "MacBook + Dell"), keyed by the sorted display UUIDs.
public struct ScreenSetup: Hashable, Sendable {
    public let key: String

    public init(screens: [ScreenInfo]) {
        key = screens.map(\.uuid).sorted().joined(separator: "+")
    }
}

/// A window as Accessibility reports it. `order` is the app's window order, 0 = oldest.
public struct WindowInfo: Codable, Equatable, Sendable {
    public var windowID: Int
    public var bundleID: String
    public var title: String
    public var frame: Frame
    public var screenUUID: String
    public var order: Int

    public init(windowID: Int, bundleID: String, title: String, frame: Frame, screenUUID: String, order: Int) {
        self.windowID = windowID; self.bundleID = bundleID; self.title = title
        self.frame = frame; self.screenUUID = screenUUID; self.order = order
    }
}

/// A rectangle as fractions of a screen's visible area, so it survives a resolution change.
public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ frame: Frame, in area: Frame) {
        self.init(x: (frame.x - area.x) / area.width, y: (frame.y - area.y) / area.height,
                  width: frame.width / area.width, height: frame.height / area.height)
    }

    /// The frame in `area`, rounded to whole points.
    public func frame(in area: Frame) -> Frame {
        Frame(x: (area.x + x * area.width).rounded(), y: (area.y + y * area.height).rounded(),
              width: (width * area.width).rounded(), height: (height * area.height).rounded())
    }
}

/// One remembered window place. The pixel frame is used as it is when the screen and its visible area are unchanged.
public struct Placement: Codable, Equatable, Sendable {
    public var matcher: Matcher
    public var fraction: UnitRect
    public var pixel: Frame
    public var screenUUID: String
    public var visibleFrame: Frame

    public init(matcher: Matcher, fraction: UnitRect, pixel: Frame, screenUUID: String, visibleFrame: Frame) {
        self.matcher = matcher; self.fraction = fraction; self.pixel = pixel
        self.screenUUID = screenUUID; self.visibleFrame = visibleFrame
    }
}

/// What one screen of one desktop should look like. Zones (S6) and auto tiling (S9) become further kinds.
public struct ScreenArrangement: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case snapshot([Placement])
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey { case kind, placements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .kind)
        switch name {
        case "snapshot": kind = .snapshot(try c.decode([Placement].self, forKey: .placements))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown arrangement kind \"\(name)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .snapshot(let placements):
            try c.encode("snapshot", forKey: .kind)
            try c.encode(placements, forKey: .placements)
        }
    }
}

/// Everything the user arranged: setup key → desktop number → screen UUID → arrangement.
/// Desktops are keyed by position ("1", "2", …), not by Space ID, which changes when desktops are recreated.
public struct Layouts: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var setups: [String: [String: [String: ScreenArrangement]]]

    public init() {
        schema = Layouts.currentSchema
        setups = [:]
    }

    public func arrangement(setup: ScreenSetup, desktop: Int, screen: String) -> ScreenArrangement? {
        setups[setup.key]?[String(desktop)]?[screen]
    }

    public mutating func set(_ arrangement: ScreenArrangement, setup: ScreenSetup, desktop: Int, screen: String) {
        setups[setup.key, default: [:]][String(desktop), default: [:]][screen] = arrangement
    }
}
