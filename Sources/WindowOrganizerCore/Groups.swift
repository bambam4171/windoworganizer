import Foundation

/// A named set of windows the user arranges together (WO-GROUPS 8a). Kept outside the setups like rules and arrange settings,
/// so it survives a change of display setup and applies wherever its screen is connected.
public struct WindowGroup: Codable, Equatable, Sendable {
    public var id: String              // UUID string, made by the caller; stable across renames
    public var name: String
    public var members: [ZoneMember]   // a whole app (titlePattern nil) or a window (app + title pattern)
    public var screen: String?         // the display UUID; nil = not assigned yet
    public var desktops: [Int]         // one or several desktops of that screen; empty = not assigned yet
    public var mode: GroupMode

    public init(id: String, name: String, members: [ZoneMember], screen: String? = nil, desktops: [Int] = [], mode: GroupMode = .tiled) {
        self.id = id; self.name = name; self.members = members; self.screen = screen; self.desktops = desktops; self.mode = mode
    }

    /// An unassigned group is valid and inert.
    public var isAssigned: Bool { screen != nil && !desktops.isEmpty }
}

/// `tiled` has no parameters: tiling uses that screen and desktop's ArrangeSettings. `saved` positions are fractions of the
/// screen's visible frame only, so a group survives a resolution change.
public enum GroupMode: Equatable, Sendable {
    case tiled
    case saved([GroupPosition])
}

public struct GroupPosition: Codable, Equatable, Sendable {
    public var matcher: Matcher
    public var fraction: UnitRect
    public init(matcher: Matcher, fraction: UnitRect) { self.matcher = matcher; self.fraction = fraction }
}

extension GroupMode: Codable {
    private enum CodingKeys: String, CodingKey { case mode, positions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .mode)
        switch name {
        case "tiled": self = .tiled
        case "saved": self = .saved(try c.decode([GroupPosition].self, forKey: .positions))
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "unknown group mode \"\(name)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tiled: try c.encode("tiled", forKey: .mode)
        case .saved(let positions):
            try c.encode("saved", forKey: .mode)
            try c.encode(positions, forKey: .positions)
        }
    }
}

extension Layouts {
    public static let maxGroups = 200

    /// Adds the group, or replaces the one with the same id in place (it keeps its list position).
    public mutating func setGroup(_ group: WindowGroup) {
        if let i = groups.firstIndex(where: { $0.id == group.id }) { groups[i] = group } else { groups.append(group) }
    }

    public mutating func removeGroup(id: String) { groups.removeAll { $0.id == id } }

    /// Moves the group to list position `index`, clamped to the list.
    public mutating func moveGroup(id: String, to index: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: min(max(index, 0), groups.count))
    }

    public func group(id: String) -> WindowGroup? { groups.first { $0.id == id } }

    /// The assigned groups of one desktop of one screen, in list order.
    public func groups(desktop: Int, screen: String) -> [WindowGroup] {
        groups.filter { $0.isAssigned && $0.screen == screen && $0.desktops.contains(desktop) }
    }

    func validateGroups() throws {
        func require(_ good: Bool) throws { if !good { throw LayoutStoreError.invalidLayout } }
        try require(groups.count <= Self.maxGroups)
        try require(Set(groups.map(\.id)).count == groups.count)
        try require(Set(groups.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == groups.count)
        for g in groups {
            try require(!g.id.isEmpty)
            let name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try require(!name.isEmpty && name == g.name && g.name.count <= 100)
            try require((1...100).contains(g.members.count) && g.members.allSatisfy { !$0.bundleID.isEmpty })
            try require(Set(g.members.map { "\($0.bundleID)\u{0}\($0.titlePattern ?? "")" }).count == g.members.count)
            try require(g.screen.map { !$0.isEmpty } ?? true)
            try require(g.desktops.allSatisfy { (0...1000).contains($0) } && Set(g.desktops).count == g.desktops.count)
            try require(g.screen != nil || g.desktops.isEmpty)
            if case .saved(let positions) = g.mode {
                try require(positions.allSatisfy { $0.fraction.isWithinUnit && $0.matcher.order >= 0 })
                try require(Set(positions.map { "\($0.matcher.bundleID)\u{0}\($0.matcher.titlePattern ?? "")\u{0}\($0.matcher.order)" }).count == positions.count)
                try require(positions.allSatisfy { p in g.members.contains { $0.bundleID == p.matcher.bundleID && $0.titlePattern == p.matcher.titlePattern } })
            }
        }
    }
}
