import Foundation

// WO-GROUPS G3: apply a group. "Last applied" lives in memory only, per screen and desktop, in apply order. An applied group
// beats rules and layouts for the windows it claims; with an empty session everything behaves as before.

public struct GroupKey: Hashable, Sendable {
    public var screen: String
    public var desktop: Int
    public init(screen: String, desktop: Int) { self.screen = screen; self.desktop = desktop }
}

public struct GroupSession: Sendable {
    /// Group ids in apply order. Applying a group again moves its id to the end. The last id decides a shared window.
    public private(set) var applied: [GroupKey: [String]] = [:]
    /// Assigned desktops of an applied group that were not visible at apply time: they apply on the next visit.
    public private(set) var pending: Set<GroupKey> = []

    public init() {}

    public var isEmpty: Bool { applied.isEmpty }

    /// Adds the group under every assigned (screen, desktop). `desktops` is the visible desktop of each screen.
    /// `now` is the visible key, `later` the others, which become pending.
    @discardableResult
    public mutating func apply(_ g: WindowGroup, desktops: [String: Int]) -> (now: GroupKey?, later: [GroupKey]) {
        guard g.isAssigned, let screen = g.screen else { return (nil, []) }
        var now: GroupKey?, later: [GroupKey] = []
        for d in g.desktops {
            let key = GroupKey(screen: screen, desktop: d)
            applied[key, default: []].removeAll { $0 == g.id }
            applied[key, default: []].append(g.id)
            if desktops[screen] == d { now = key; pending.remove(key) } else { later.append(key); pending.insert(key) }
        }
        return (now, later)
    }

    public mutating func clear(_ keys: [GroupKey]) {
        for key in keys { applied[key] = nil; pending.remove(key) }
    }

    /// True, and no longer pending, when the key was waiting for a visit.
    public mutating func visited(_ key: GroupKey) -> Bool { pending.remove(key) != nil }

    /// The stored ids that the layouts still assign to this key, in apply order. A group deleted, unassigned or moved in
    /// the editor is ignored: it is never applied from a stale copy.
    public func order(_ key: GroupKey, layouts: Layouts) -> [WindowGroup] {
        let current = layouts.groups(desktop: key.desktop, screen: key.screen)
        return (applied[key] ?? []).compactMap { id in current.first { $0.id == id } }
    }

    /// The group applied last on this key, if it is still there.
    public func last(_ key: GroupKey, layouts: Layouts) -> WindowGroup? { order(key, layouts: layouts).last }
}

/// What each group takes, in the groups' order: the walk goes from last to first, so a shared window belongs to the last one.
func groupClaims(_ groups: [WindowGroup], windows: [WindowInfo], screen: ScreenInfo) -> [(group: WindowGroup, windows: [WindowInfo])] {
    let mine = windows.filter { $0.screenUUID == screen.uuid }.sorted { ($0.bundleID, $0.order, $0.windowID) < ($1.bundleID, $1.order, $1.windowID) }
    var taken = Set<Int>()
    var out: [(WindowGroup, [WindowInfo])] = []
    for g in groups.reversed() {
        let got = mine.filter { w in !taken.contains(w.windowID) && g.members.contains { $0.matches(w) } }
        taken.formUnion(got.map(\.windowID))
        out.append((g, got))
    }
    return out.reversed()
}

/// The moves of the applied groups on one screen. `groups` arrive in apply order.
public func planGroups(_ groups: [WindowGroup], windows: [WindowInfo], screen: ScreenInfo, settings: ArrangeSettings) -> Plan {
    var plan = Plan(moves: [], skipped: [], unchanged: 0)
    func place(_ w: WindowInfo, _ target: Frame) {
        if close(w.frame, target) { plan.unchanged += 1 }
        else { plan.moves.append(Move(windowID: w.windowID, from: w.frame, to: target, area: screen.visibleFrame)) }
    }
    for (g, claimed) in groupClaims(groups, windows: windows, screen: screen) {
        switch g.mode {
        case .tiled:
            let ordered = arrangeOrder(claimed, settings: settings)
            guard !ordered.isEmpty else { continue }
            let framed = applyGap(gridTile(ordered.count, in: screen.visibleFrame), gap: settings.gapPoints)
            if framed.skipped { plan.gapSkipped = true }
            plan.tiles.append(ordered.map(\.windowID))
            for (w, f) in zip(ordered, framed.frames) { place(w, f) }
        case .saved(let positions):
            let match = matchWindows(positions.map(\.matcher), claimed)
            var pairs: [(WindowInfo, Frame)] = []
            for (p, w) in zip(positions, match.assigned) {
                guard let w else { plan.skipped.append(p.matcher); continue }
                pairs.append((w, p.fraction.frame(in: screen.visibleFrame).contained(in: screen.visibleFrame)))
            }
            let framed = applyGap(pairs.map(\.1), gap: settings.gapPoints)
            if framed.skipped { plan.gapSkipped = true }
            for ((w, _), f) in zip(pairs, framed.frames) { place(w, f) }
        }
    }
    return plan
}

/// Restore with applied groups: the windows a group claims leave `planRestore` (rules and layouts never see them), and the
/// groups' moves are appended. With an empty session this is `planRestore`.
public func planArrange(_ layouts: Layouts, session: GroupSession, windows: [WindowInfo], screens: [ScreenInfo], desktops: [String: Int],
                        scope: WorkspaceSelection? = nil) -> Plan? {
    guard !session.isEmpty else { return planRestore(layouts, windows: windows, screens: screens, desktops: desktops, scope: scope) }
    let eligible = scope.map { s in screens.filter { $0.uuid == s.screenUUID && desktops[$0.uuid] == s.desktop } } ?? screens
    let scoped = scope.map { s in windows.filter { $0.screenUUID == s.screenUUID } } ?? windows
    var claimedIDs = Set<Int>()
    var groupPlans: [Plan] = []
    for screen in eligible {
        guard let desktop = desktops[screen.uuid] else { continue }
        let groups = session.order(GroupKey(screen: screen.uuid, desktop: desktop), layouts: layouts)
        guard !groups.isEmpty else { continue }
        for (_, ws) in groupClaims(groups, windows: scoped, screen: screen) { claimedIDs.formUnion(ws.map(\.windowID)) }
        groupPlans.append(planGroups(groups, windows: scoped, screen: screen, settings: layouts.arrangeSettings(desktop: desktop, screen: screen.uuid)))
    }
    var plan = planRestore(layouts, windows: windows.filter { !claimedIDs.contains($0.windowID) }, screens: screens, desktops: desktops, scope: scope)
    for g in groupPlans {
        guard !(g.moves.isEmpty && g.skipped.isEmpty && g.unchanged == 0 && g.tiles.isEmpty) else { continue }
        var p = plan ?? Plan(moves: [], skipped: [], unchanged: 0)
        p.moves += g.moves; p.skipped += g.skipped; p.unchanged += g.unchanged; p.tiles += g.tiles
        p.gapSkipped = p.gapSkipped || g.gapSkipped
        plan = p
    }
    return plan
}
