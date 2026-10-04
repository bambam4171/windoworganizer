import Foundation
import WindowOrganizerCore

// WO-OFFSCREEN (Zeus design Z-436): a window bigger than its tile is moved back inside its screen, not left spilling over
// into the next one, and the result line names it.

/// An app with a minimum size that, like Xcode or Mail, may also move the origin after refusing the first size.
private final class MinMover: WindowMover, @unchecked Sendable {
    var frames: [Int: Frame]
    var minimum: [Int: (Double, Double)] = [:]
    /// Moves the origin by this much on every set that hits the minimum (an app or WindowServer shifting the window).
    var drift: [Int: Double] = [:]
    var sets: [(Int, Frame)] = []
    init(_ ws: [WindowInfo]) { frames = Dictionary(uniqueKeysWithValues: ws.map { ($0.windowID, $0.frame) }) }
    func frame(of id: Int) -> Frame? { frames[id] }
    func setFrame(_ f: Frame, of id: Int) {
        sets.append((id, f))
        var g = f
        if let (w, h) = minimum[id], g.width < w || g.height < h {
            g.width = max(g.width, w); g.height = max(g.height, h); g.x += drift[id] ?? 0
        }
        frames[id] = g
    }
}

private func inside(_ f: Frame?, _ area: Frame) -> Bool {
    guard let f else { return false }
    return f.x >= area.x - 1 && f.y >= area.y - 1 && f.x + f.width <= area.x + area.width + 1 && f.y + f.height <= area.y + area.height + 1
}

private let left = laptop.visibleFrame
private let a = Frame(x: 0, y: 40, width: 400, height: 300)
/// Two columns on the laptop: the right tile starts at x 756 and is 756 wide, so a window of 900 spills 144 pt onto the Dell.
private func twoColumns() -> (WindowInfo, WindowInfo, Plan) {
    let w1 = window(1, term, "a", 0, a), w2 = window(2, "com.apple.dt.Xcode", "b", 1, a)
    let t1 = Frame(x: 0, y: 33, width: 756, height: 949), t2 = Frame(x: 756, y: 33, width: 756, height: 949)
    return (w1, w2, Plan(moves: [Move(windowID: 1, from: a, to: t1, area: left), Move(windowID: 2, from: a, to: t2, area: left)], skipped: [], unchanged: 0))
}

let offscreenChecks: [(String, @Sendable () throws -> Void)] = [
    ("a window that keeps a larger size than its right tile ends inside its screen and is named as shifted", {
        let (w1, w2, plan) = twoColumns()
        let mover = MinMover([w1, w2]); mover.minimum = [2: (900, 600)]
        let r = applyPlan(plan, mover: mover)
        try expect(inside(mover.frames[2], left), "window 2 inside the laptop's visible frame: \(String(describing: mover.frames[2]))")
        try expectEqual(r.shiftedIDs, [2])
        try expectEqual(r.keptMinimum, 1)
        try expectEqual(r.failed, 0)
        try expect(inside(mover.frames[1], left), "window 1 untouched inside")
    }),
    ("a window whose app moves the origin after refusing the size is also brought inside, not called failed", {
        let (w1, w2, plan) = twoColumns()
        let mover = MinMover([w1, w2]); mover.minimum = [2: (900, 600)]; mover.drift = [2: 40]
        let r = applyPlan(plan, mover: mover)
        try expect(inside(mover.frames[2], left), "inside: \(String(describing: mover.frames[2]))")
        try expectEqual(r.shiftedIDs, [2])
        try expectEqual(r.failed, 0)
    }),
    ("a minimum larger than the whole screen counts as failed and is not listed as shifted", {
        let (w1, w2, plan) = twoColumns()
        let mover = MinMover([w1, w2]); mover.minimum = [2: (1700, 600)]
        let r = applyPlan(plan, mover: mover)
        try expectEqual(r.shiftedIDs, [])
        try expectEqual(r.failed, 1)
    }),
    ("a window that fits its tile is set once and never shifted", {
        let (w1, w2, plan) = twoColumns()
        let mover = MinMover([w1, w2])
        let r = applyPlan(plan, mover: mover)
        try expectEqual(r.placed, 2)
        try expectEqual(r.shiftedIDs, [])
        try expectEqual(mover.sets.count, 2)
    }),
    ("isInside allows 1 pt of rounding and no more", {
        let area = Frame(x: 0, y: 25, width: 1200, height: 775)
        try expect(Frame(x: 1, y: 25, width: 1200, height: 775).isInside(area), "1 pt over the right edge is rounding")
        try expect(!Frame(x: 20, y: 25, width: 1200, height: 775).isInside(area), "20 pt over the right edge is outside")
        try expect(!Frame(x: -20, y: 25, width: 400, height: 300).isInside(area), "20 pt over the left edge is outside")
    }),
    ("a move without an area keeps the old behaviour: kept its minimum size, no shift", {
        let (w1, w2, p) = twoColumns()
        let plan = Plan(moves: p.moves.map { Move(windowID: $0.windowID, from: $0.from, to: $0.to) }, skipped: [], unchanged: 0)
        let mover = MinMover([w1, w2]); mover.minimum = [2: (900, 600)]
        let r = applyPlan(plan, mover: mover)
        try expectEqual(r.keptMinimum, 1)
        try expectEqual(r.shiftedIDs, [])
    }),
    ("the result line names the apps that were moved inside the screen", {
        let r = ApplyResult(placed: 3, keptMinimum: 2, failed: 0, unchanged: 0, notOpen: 0, shiftedIDs: [2, 5])
        let line = ResultLine.restored(r, shifted: ["Xcode", "Mail"], desktop: 1, at: "08:00")
        try expectEqual(line, "Desktop 1: 3 windows placed, 2 kept their minimum size and were moved inside the screen: Xcode, Mail · 08:00")
        let one = ResultLine.restored(ApplyResult(placed: 1, keptMinimum: 2, failed: 0, unchanged: 0, notOpen: 0, shiftedIDs: [2]), shifted: ["Xcode"], desktop: 1, at: "08:00")
        try expectEqual(one, "Desktop 1: 1 window placed, 1 kept its minimum size, 1 kept its minimum size and was moved inside the screen: Xcode · 08:00")
    }),
    ("planRestore, the grid and the exact snapshot give every move the visible frame of its own screen", {
        let setup = ScreenSetup(screens: [laptop, dell])
        var layouts = Layouts()
        let zone = Zone(rect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), members: [ZoneMember(bundleID: term)])
        layouts.set(ScreenArrangement(kind: .zones([zone])), setup: setup, desktop: 1, screen: laptop.uuid)
        let snap = Placement(matcher: Matcher(bundleID: safari, seenTitle: "", order: 0), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1),
                             pixel: Frame(x: 1512, y: 25, width: 1280, height: 1415), screenUUID: dell.uuid, visibleFrame: dell.visibleFrame)
        layouts.set(ScreenArrangement(kind: .snapshot([snap])), setup: setup, desktop: 1, screen: dell.uuid)
        let ws = [window(1, term, "t", 0, a), window(2, safari, "s", 0, Frame(x: 1600, y: 100, width: 300, height: 300), on: dell)]
        let plan = planRestore(layouts, windows: ws, screens: [laptop, dell], desktops: [laptop.uuid: 1, dell.uuid: 1])
        try expectEqual(plan?.moves.first { $0.windowID == 1 }?.area, left)
        try expectEqual(plan?.moves.first { $0.windowID == 2 }?.area, dell.visibleFrame)
        let direct = planSnapshot(ScreenArrangement(kind: .snapshot([snap])), windows: [ws[1]], screen: dell)
        try expectEqual(direct.moves.first?.area, dell.visibleFrame)
    }),
    ("a move whose target lies outside its screen's area is clamped inside it when applied (an exact snapshot place)", {
        let off = Frame(x: 1200, y: 25, width: 1000, height: 600)
        let w = window(2, safari, "s", 0, a)
        let mover = MinMover([w])
        let r = applyPlan(Plan(moves: [Move(windowID: 2, from: a, to: off, area: left)], skipped: [], unchanged: 0), mover: mover)
        try expect(inside(mover.frames[2], left), "inside: \(String(describing: mover.frames[2]))")
        try expectEqual(r.failed, 0)
        try expectEqual(r.placed, 1)
    }),
    ("the grid plan carries the screen's visible frame", {
        let ws = [window(1, term, "a", 0, a, on: dell), window(2, safari, "b", 0, a, on: dell)]
        let plan = try planAutomaticWorkspace(WorkspaceSelection(screenUUID: dell.uuid, desktop: 1), windows: ws, screens: [laptop, dell], desktops: [laptop.uuid: 1, dell.uuid: 1])
        try expect(!plan.moves.isEmpty && plan.moves.allSatisfy { $0.area == dell.visibleFrame }, "areas set")
    }),
]
