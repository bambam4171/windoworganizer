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

    public var isValid: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 }
    public var isWithinUnit: Bool { isValid && x >= 0 && y >= 0 && x + width <= 1.000001 && y + height <= 1.000001 }

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

/// A zone member: every window of an app, or only those whose title matches the pattern (as Matcher.titlePattern).
public struct ZoneMember: Codable, Equatable, Sendable {
    public var bundleID: String
    public var titlePattern: String?

    public init(bundleID: String, titlePattern: String? = nil) { self.bundleID = bundleID; self.titlePattern = titlePattern }

    public func matches(_ w: WindowInfo) -> Bool {
        w.bundleID == bundleID && Matcher(bundleID: bundleID, titlePattern: titlePattern).matches(title: w.title)
    }
}

/// A rectangle drawn on a screen (plan §1). Its members' windows are tiled inside it.
public struct Zone: Codable, Equatable, Sendable {
    public var rect: UnitRect
    public var members: [ZoneMember]

    public init(rect: UnitRect, members: [ZoneMember]) { self.rect = rect; self.members = members }
}

/// "Mail always on the Dell, Desktop 2" (plan §1): an app's windows go to one area of one screen while it shows that desktop.
public struct AppRule: Codable, Equatable, Sendable {
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var bundleID: String
    public var desktop: Int
    /// The display UUID.
    public var screen: String
    public var area: UnitRect

    public init(bundleID: String, desktop: Int, screen: String, area: UnitRect) {
        self.bundleID = bundleID; self.desktop = desktop; self.screen = screen; self.area = area
    }
}

/// What one screen of one desktop should look like. Auto tiling (S9) becomes a further kind.
public struct ScreenArrangement: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case snapshot([Placement])
        case zones([Zone])
        case autoTile
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey { case kind, placements, zones }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .kind)
        switch name {
        case "snapshot": kind = .snapshot(try c.decode([Placement].self, forKey: .placements))
        case "zones": kind = .zones(try c.decode([Zone].self, forKey: .zones))
        case "autoTile": kind = .autoTile
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
        case .autoTile:
            try c.encode("autoTile", forKey: .kind)
        case .zones(let zones):
            try c.encode("zones", forKey: .kind)
            try c.encode(zones, forKey: .zones)
        }
    }
}

/// Everything the user arranged: setup key → desktop number → screen UUID → arrangement.
/// Desktops are keyed by position ("1", "2", …), not by Space ID, which changes when desktops are recreated.
public struct Layouts: Codable, Equatable, Sendable {
    public static let currentSchema = 2

    public var schema: Int
    public var setups: [String: [String: [String: ScreenArrangement]]]
    /// App rules (S7), outside the setups: a rule applies in every setup where its screen is connected. One per app.
    public private(set) var rules: [AppRule]
    /// Gap and the other arrange settings (WINDOW-GAP S1): desktop number → screen UUID. Outside the setups like the
    /// rules, so a screen keeps them with or without the other displays, and removing a setup never drops them.
    public private(set) var arrange: [String: [String: ArrangeSettings]]

    public init() {
        schema = Layouts.currentSchema
        setups = [:]
        rules = []
        arrange = [:]
    }

    private enum CodingKeys: String, CodingKey { case schema, setups, rules, arrange }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let savedSchema = try c.decode(Int.self, forKey: .schema)
        guard savedSchema >= 1, savedSchema <= Self.currentSchema else {
            throw LayoutStoreError.unsupportedSchema(savedSchema)
        }
        schema = Self.currentSchema
        setups = try c.decode([String: [String: [String: ScreenArrangement]]].self, forKey: .setups)
        rules = try c.decodeIfPresent([AppRule].self, forKey: .rules) ?? []
        arrange = try c.decodeIfPresent([String: [String: ArrangeSettings]].self, forKey: .arrange) ?? [:]
    }

    /// Without rules the file is exactly as before S7.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(setups, forKey: .setups)
        if !rules.isEmpty { try c.encode(rules, forKey: .rules) }
        if !arrange.isEmpty { try c.encode(arrange, forKey: .arrange) }
    }

    /// Adds the rule, or replaces the one its app already has, in place.
    public mutating func setRule(_ rule: AppRule) {
        if let i = rules.firstIndex(where: { $0.bundleID == rule.bundleID }) { rules[i] = rule } else { rules.append(rule) }
    }

    public mutating func removeRule(_ bundleID: String) { rules.removeAll { $0.bundleID == bundleID } }

    /// The rules that send apps to one desktop of one screen, as the editor lists them.
    public func rules(desktop: Int, screen: String) -> [AppRule] {
        rules.filter { $0.desktop == desktop && $0.screen == screen }
    }

    public func arrangement(setup: ScreenSetup, desktop: Int, screen: String) -> ScreenArrangement? {
        setups[setup.key]?[String(desktop)]?[screen]
    }

    public mutating func set(_ arrangement: ScreenArrangement, setup: ScreenSetup, desktop: Int, screen: String) {
        setups[setup.key, default: [:]][String(desktop), default: [:]][screen] = arrangement
    }

    /// Drops one screen's arrangement, and the desktop and setup entries it leaves empty.
    public mutating func remove(setup: ScreenSetup, desktop: Int, screen: String) {
        let d = String(desktop)
        setups[setup.key]?[d]?[screen] = nil
        if setups[setup.key]?[d]?.isEmpty == true { setups[setup.key]?[d] = nil }
        if setups[setup.key]?.isEmpty == true { setups[setup.key] = nil }
    }
}

extension Layouts {
    /// The settings of one desktop of one screen; the defaults when there is no entry.
    public func arrangeSettings(desktop: Int, screen: String) -> ArrangeSettings {
        arrange[String(desktop)]?[screen] ?? ArrangeSettings()
    }

    /// Stores the settings; an all-default record drops its entry, and a desktop left empty drops too.
    public mutating func setArrangeSettings(_ settings: ArrangeSettings, desktop: Int, screen: String) {
        let d = String(desktop)
        arrange[d, default: [:]][screen] = settings.isDefault ? nil : settings
        if arrange[d]?.isEmpty == true { arrange[d] = nil }
    }
}
