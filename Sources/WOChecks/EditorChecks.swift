import CoreGraphics
import Foundation
import WindowOrganizerCore

// WO-S6b (plan §4 editor): drawing zones on a scaled screen. The canvas is 480 × 240 points, so one 1/24 grid step is
// 20 points across and 10 down. Canvas points have their origin top-left, like AX frames.

private let canvas = CGSize(width: 480, height: 240)
private let setup = ScreenSetup(screens: [laptop])

private func editor(_ layouts: Layouts = Layouts()) -> ZoneEditor {
    ZoneEditor(layouts, setup: setup, desktop: 2, screen: "MBP")
}

let editorChecks: [(String, @Sendable () throws -> Void)] = [
    ("a drag draws a zone snapped to the grid, clamped to the screen, and selects it", {
        var e = editor()
        try expect(e.draw(from: CGPoint(x: 241, y: 3), to: CGPoint(x: 999, y: 118), canvas: canvas), "drawn")
        try expectEqual(e.zones, [Zone(rect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5), members: [])])
        try expectEqual(e.selected, 0)
        // drawn backwards (bottom-right to top-left) gives the same kind of rectangle
        try expect(e.draw(from: CGPoint(x: 240, y: 240), to: CGPoint(x: 0, y: 120), canvas: canvas), "drawn")
        try expectEqual(e.zones[1].rect, UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }),
    ("a drag smaller than one grid step draws nothing", {
        var e = editor()
        try expect(!e.draw(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 104, y: 102), canvas: canvas), "not drawn")
        try expectEqual(e.zones, [])
    }),
    ("a click selects the topmost zone, or none", {
        var e = editor()
        _ = e.draw(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 480, y: 240), canvas: canvas)
        _ = e.draw(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 240, y: 120), canvas: canvas)
        e.select(at: CGPoint(x: 100, y: 50), canvas: canvas)
        try expectEqual(e.selected, 1)
        e.select(at: CGPoint(x: 400, y: 200), canvas: canvas)
        try expectEqual(e.selected, 0)
        e.select(at: CGPoint(x: 500, y: 500), canvas: canvas)
        try expectEqual(e.selected, nil)
    }),
    ("moving keeps the size, snaps, and stays inside the screen", {
        var e = editor()
        _ = e.draw(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 240, y: 120), canvas: canvas)
        let start = e.zones[0].rect
        e.move(0, from: start, by: CGSize(width: 61, height: 9), canvas: canvas)
        try expectEqual(e.zones[0].rect, UnitRect(x: 3.0 / 24, y: 1.0 / 24, width: 0.5, height: 0.5))
        e.move(0, from: start, by: CGSize(width: 900, height: 900), canvas: canvas)
        try expectEqual(e.zones[0].rect, UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }),
    ("the bottom-right handle resizes, at least one step, inside the screen", {
        var e = editor()
        _ = e.draw(from: CGPoint(x: 240, y: 120), to: CGPoint(x: 480, y: 240), canvas: canvas)
        try expect(e.isHandle(CGPoint(x: 476, y: 236), canvas: canvas), "handle")
        try expect(!e.isHandle(CGPoint(x: 300, y: 150), canvas: canvas), "not handle")
        e.resize(0, to: CGPoint(x: 100, y: 50), canvas: canvas)
        try expectEqual(e.zones[0].rect, UnitRect(x: 0.5, y: 0.5, width: 1.0 / 24, height: 1.0 / 24))
        e.resize(0, to: CGPoint(x: 999, y: 999), canvas: canvas)
        try expectEqual(e.zones[0].rect, UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }),
    ("members toggle on the selected zone, delete removes it", {
        var e = editor()
        _ = e.draw(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 240, y: 240), canvas: canvas)
        e.toggle(term); e.toggle(mail); e.toggle(term)
        try expectEqual(e.zones[0].members, [ZoneMember(bundleID: mail)])
        e.deleteSelected()
        try expectEqual(e.zones, [])
        try expectEqual(e.selected, nil)
    }),
    ("save writes zones, and no zones removes the arrangement", {
        var layouts = Layouts()
        var e = editor(layouts)
        _ = e.draw(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 240, y: 240), canvas: canvas)
        e.toggle(term)
        e.save(into: &layouts)
        try expectEqual(layouts.arrangement(setup: setup, desktop: 2, screen: "MBP"),
                        ScreenArrangement(kind: .zones(e.zones)))
        var again = editor(layouts)
        try expectEqual(again.zones, e.zones)
        again.selected = 0
        again.deleteSelected()
        again.save(into: &layouts)
        try expectEqual(layouts.arrangement(setup: setup, desktop: 2, screen: "MBP"), nil)
    }),
    ("a screen with remembered windows starts empty and warns that saving replaces them", {
        var layouts = Layouts()
        layouts.set(remember([window(1, term, "a", 0, Frame(x: 10, y: 50, width: 700, height: 500))], on: laptop),
                    setup: setup, desktop: 2, screen: "MBP")
        let e = editor(layouts)
        try expectEqual(e.zones, [])
        try expectEqual(e.warning, "Saving zones replaces the remembered windows on this screen.")
        try expectEqual(editor().warning, nil)
    }),
    ("canvas rectangles for drawing", {
        var e = editor()
        _ = e.draw(from: CGPoint(x: 240, y: 0), to: CGPoint(x: 480, y: 120), canvas: canvas)
        try expectEqual(e.canvasRect(0, canvas: canvas), CGRect(x: 240, y: 0, width: 240, height: 120))
    }),
]
