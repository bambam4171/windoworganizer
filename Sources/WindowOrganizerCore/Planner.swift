import Foundation

// The snapshot planner (plan §2): a pure function from an arrangement, the windows and the screen to a list of moves.

public struct Move: Equatable, Sendable {
    public var windowID: Int
    public var from: Frame
    public var to: Frame

    public init(windowID: Int, from: Frame, to: Frame) {
        self.windowID = windowID; self.from = from; self.to = to
    }
}

public struct Plan: Equatable, Sendable {
    public var moves: [Move]
    /// Places no window claimed: nothing moves for them.
    public var skipped: [Matcher]
    /// Windows already within 1 pt of their place.
    public var unchanged: Int
    /// The window IDs tiled together in each zone, in tile order (S6): a new window re-tiles its own zone only.
    public var tiles: [[Int]]
    /// A gap was set, but a screen had no room for it, so that screen was left without one.
    public var gapSkipped: Bool

    public init(moves: [Move], skipped: [Matcher], unchanged: Int, tiles: [[Int]] = [], gapSkipped: Bool = false) {
        self.moves = moves; self.skipped = skipped; self.unchanged = unchanged; self.tiles = tiles; self.gapSkipped = gapSkipped
    }
}

/// "Remember this desktop" for one screen: every window on it becomes a place, matched by app + order.
public func remember(_ windows: [WindowInfo], on screen: ScreenInfo) -> ScreenArrangement {
    let mine = windows.filter { $0.screenUUID == screen.uuid }
        .sorted { ($0.bundleID, $0.order) < ($1.bundleID, $1.order) }
    return ScreenArrangement(kind: .snapshot(mine.map { w in
        Placement(matcher: Matcher(bundleID: w.bundleID, seenTitle: w.title, order: w.order),
                  fraction: UnitRect(w.frame, in: screen.visibleFrame), pixel: w.frame,
                  screenUUID: screen.uuid, visibleFrame: screen.visibleFrame)
    }))
}

public func planSnapshot(_ arrangement: ScreenArrangement, windows: [WindowInfo], screen: ScreenInfo) -> Plan {
    guard case .snapshot(let placements) = arrangement.kind else { return Plan(moves: [], skipped: [], unchanged: 0) }
    let match = matchWindows(placements.map(\.matcher), windows)
    var plan = Plan(moves: [], skipped: [], unchanged: 0)
    for (place, window) in zip(placements, match.assigned) {
        guard let w = window else { plan.skipped.append(place.matcher); continue }
        let exact = place.screenUUID == screen.uuid && place.visibleFrame == screen.visibleFrame
        let target = exact ? place.pixel : place.fraction.frame(in: screen.visibleFrame).contained(in: screen.visibleFrame)
        if close(w.frame, target) { plan.unchanged += 1 }
        else { plan.moves.append(Move(windowID: w.windowID, from: w.frame, to: target)) }
    }
    return plan
}

func close(_ a: Frame, _ b: Frame) -> Bool {
    abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}
