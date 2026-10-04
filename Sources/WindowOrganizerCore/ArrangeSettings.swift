import Foundation

// WINDOW-GAP S1 (PLAN v4 row 9): the settings of one screen on one desktop, and the gap between windows.
// Every field is optional and read through an accessor that carries the default, so a later default change reaches
// everyone who never touched the setting, and an untouched file stays byte-identical.

public struct ArrangeSettings: Codable, Equatable, Sendable {
    public var gap: Int?
    public var keepLive: Bool?
    public var pushBackOnTop: Bool?
    public var correctResize: Bool?
    public var sortByName: Bool?
    public var autoArrange: Bool?

    public init(gap: Int? = nil, keepLive: Bool? = nil, pushBackOnTop: Bool? = nil, correctResize: Bool? = nil, sortByName: Bool? = nil, autoArrange: Bool? = nil) {
        self.gap = gap; self.keepLive = keepLive; self.pushBackOnTop = pushBackOnTop
        self.correctResize = correctResize; self.sortByName = sortByName; self.autoArrange = autoArrange
    }

    public static let maxGap = 64

    /// Points between neighbouring windows; 0 = none.
    public var gapPoints: Int { gap ?? 0 }
    /// Live correction defaults to on once there is a gap to keep.
    public var isLive: Bool { keepLive ?? (gapPoints > 0) }
    /// "Leave alone": a window dropped on top stays on top.
    public var pushesBackOnTop: Bool { pushBackOnTop ?? false }
    public var correctsResize: Bool { correctResize ?? true }
    public var sortsByName: Bool { sortByName ?? false }
    /// AUTO-MODE: an open or close re-arranges this screen as Restore would.
    public var arrangesAutomatically: Bool { autoArrange ?? false }

    public var isDefault: Bool { self == ArrangeSettings() }
}

// MARK: gap maths

private let edgeTolerance = 1.0
private let minimumSide = 40.0

/// Moves only the edges two frames share: a min edge in by `gap / 2` (floor), a max edge in by the rest, so two
/// neighbours end up exactly `gap` apart, odd gaps included. Screen edges, the menu bar and free-standing edges stay.
/// If any result would be invalid or narrower than 40 pt, nothing moves and `skipped` says so.
public func applyGap(_ frames: [Frame], gap: Int) -> (frames: [Frame], skipped: Bool) {
    guard gap > 0, frames.count > 1 else { return (frames, false) }
    let low = Double(gap / 2), high = Double(gap - gap / 2)
    func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool { min(a1, b1) - max(a0, b0) > edgeTolerance }
    var out = frames
    for (i, f) in frames.enumerated() {
        var left = false, right = false, top = false, bottom = false
        for (j, g) in frames.enumerated() where j != i {
            if overlap(f.y, f.y + f.height, g.y, g.y + g.height) {
                if abs(f.x + f.width - g.x) <= edgeTolerance { right = true }
                if abs(g.x + g.width - f.x) <= edgeTolerance { left = true }
            }
            if overlap(f.x, f.x + f.width, g.x, g.x + g.width) {
                if abs(f.y + f.height - g.y) <= edgeTolerance { bottom = true }
                if abs(g.y + g.height - f.y) <= edgeTolerance { top = true }
            }
        }
        var r = f
        if left { r.x += low; r.width -= low }
        if right { r.width -= high }
        if top { r.y += low; r.height -= low }
        if bottom { r.height -= high }
        out[i] = r
    }
    guard out.allSatisfy({ $0.isValid && $0.width >= minimumSide && $0.height >= minimumSide }) else { return (frames, true) }
    return (out, false)
}

public enum Preset: Equatable, Sendable { case grid, columns, rows }

/// The editor's presets as pure frames: edges rounded once and shared, then the gap between windows.
public func presetFrames(_ preset: Preset, count: Int, in area: Frame, gap: Int = 0) -> [Frame] {
    let frames: [Frame]
    switch preset {
    case .grid: frames = gridTile(count, in: area)
    case .columns: frames = tile(count, in: area, across: true)
    case .rows: frames = tile(count, in: area, across: false)
    }
    return applyGap(frames, gap: gap).frames
}
