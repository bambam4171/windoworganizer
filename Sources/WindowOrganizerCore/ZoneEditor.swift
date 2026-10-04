import CoreGraphics
import Foundation

// The zone editor (plan §4, slice S6b), pure: the window draws the screen scaled onto a canvas and reports the mouse here.
// Canvas points have their origin top-left, like AX frames. Everything snaps to a 1/24 grid of the screen.

public struct ZoneEditor: Sendable {
    public static let grid = 24.0
    /// How close to a zone's bottom-right corner a press grabs the resize handle, in canvas points.
    public static let handle = 8.0

    public var zones: [Zone]
    public var selected: Int?
    /// Shown above the drawing when saving would replace a remembered snapshot.
    public let warning: String?
    private let setup: ScreenSetup, desktop: Int, screen: String

    public init(_ layouts: Layouts, setup: ScreenSetup, desktop: Int, screen: String) {
        self.setup = setup; self.desktop = desktop; self.screen = screen
        switch layouts.arrangement(setup: setup, desktop: desktop, screen: screen)?.kind {
        case .zones(let zs)?: zones = zs; warning = nil
        case .snapshot?: zones = []; warning = "Saving zones replaces the remembered windows on this screen."
        case .autoTile?: zones = []; warning = "Saving zones replaces automatic tiling on this screen."
        case nil: zones = []; warning = nil
        }
    }

    /// Draws a zone over the dragged rectangle and selects it. False (nothing drawn) when it is under one grid step.
    public mutating func draw(from a: CGPoint, to b: CGPoint, canvas: CGSize) -> Bool {
        let x0 = snap(min(a.x, b.x) / canvas.width), x1 = snap(max(a.x, b.x) / canvas.width)
        let y0 = snap(min(a.y, b.y) / canvas.height), y1 = snap(max(a.y, b.y) / canvas.height)
        guard x1 > x0, y1 > y0 else { return false }
        zones.append(Zone(rect: UnitRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), members: []))
        selected = zones.count - 1
        return true
    }

    /// The topmost (last drawn) zone under the point, or nil.
    public mutating func select(at p: CGPoint, canvas: CGSize) {
        selected = zones.indices.last { canvasRect($0, canvas: canvas).contains(p) }
    }

    public func isHandle(_ p: CGPoint, canvas: CGSize) -> Bool {
        guard let i = selected else { return false }
        let r = canvasRect(i, canvas: canvas)
        return abs(p.x - r.maxX) <= Self.handle && abs(p.y - r.maxY) <= Self.handle
    }

    /// Moves zone i to where `start` lands after the whole drag so far, so rounding never builds up.
    public mutating func move(_ i: Int, from start: UnitRect, by delta: CGSize, canvas: CGSize) {
        var r = start
        r.x = min(max(snap(start.x + delta.width / canvas.width), 0), 1 - r.width)
        r.y = min(max(snap(start.y + delta.height / canvas.height), 0), 1 - r.height)
        zones[i].rect = r
    }

    /// Puts zone i's bottom-right corner at the point: at least one grid step, never past the screen.
    public mutating func resize(_ i: Int, to p: CGPoint, canvas: CGSize) {
        let step = 1 / Self.grid
        var r = zones[i].rect
        r.width = min(max(snap(p.x / canvas.width) - r.x, step), 1 - r.x)
        r.height = min(max(snap(p.y / canvas.height) - r.y, step), 1 - r.y)
        zones[i].rect = r
    }

    /// Adds the app to the selected zone, or takes it out.
    public mutating func toggle(_ bundleID: String) {
        guard let i = selected else { return }
        if let m = zones[i].members.firstIndex(where: { $0.bundleID == bundleID }) { zones[i].members.remove(at: m) }
        else { zones[i].members.append(ZoneMember(bundleID: bundleID)) }
    }

    public mutating func deleteSelected() {
        guard let i = selected else { return }
        zones.remove(at: i)
        selected = nil
    }

    /// Writes the zones; with none left the arrangement goes, so Remember this desktop works on that screen again.
    public func save(into layouts: inout Layouts) {
        if zones.isEmpty { layouts.remove(setup: setup, desktop: desktop, screen: screen) }
        else { layouts.set(ScreenArrangement(kind: .zones(zones)), setup: setup, desktop: desktop, screen: screen) }
    }

    public func canvasRect(_ i: Int, canvas: CGSize) -> CGRect {
        let r = zones[i].rect
        return CGRect(x: r.x * canvas.width, y: r.y * canvas.height, width: r.width * canvas.width, height: r.height * canvas.height)
    }

    private func snap(_ v: Double) -> Double { (min(max(v, 0), 1) * Self.grid).rounded() / Self.grid }
}
