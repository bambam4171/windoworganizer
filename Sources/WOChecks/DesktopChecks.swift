import Foundation
import WindowOrganizerCore

// WO-S2 (plan §3, §4): the pure parts of reading the Mac - geometry, window → screen, which windows count,
// which desktop this is, and the status line. The AX, NSScreen and SkyLight calls themselves live in the app.

let desktopChecks: [(String, @Sendable () throws -> Void)] = [
    ("NSScreen frame (bottom-left) flips to top-left", {
        // Dell above the laptop's right half: NSScreen y = 982, AX y = -1440.
        try expectEqual(Geometry.topLeft(Frame(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982),
                        Frame(x: 0, y: 0, width: 1512, height: 982))
        try expectEqual(Geometry.topLeft(Frame(x: 756, y: 982, width: 2560, height: 1440), primaryHeight: 982),
                        Frame(x: 756, y: -1440, width: 2560, height: 1440))
        try expectEqual(Geometry.topLeft(Frame(x: 0, y: 70, width: 1512, height: 879), primaryHeight: 982),
                        Frame(x: 0, y: 33, width: 1512, height: 879))
    }),
    ("window → screen: centre first, else largest overlap, else none", {
        try expectEqual(screenUUID(for: Frame(x: 100, y: 100, width: 400, height: 300), in: [laptop, dell]), "MBP")
        try expectEqual(screenUUID(for: Frame(x: 1400, y: 100, width: 600, height: 300), in: [laptop, dell]), "DELL")
        // centre in the gap below the laptop (y 982…1440 is empty on the left), mostly overlapping the laptop
        try expectEqual(screenUUID(for: Frame(x: 100, y: 700, width: 400, height: 600), in: [laptop, dell]), "MBP")
        try expectEqual(screenUUID(for: Frame(x: -5000, y: 0, width: 100, height: 100), in: [laptop, dell]), nil)
    }),
    ("only standard, windowed, visible windows count", {
        try expect(WindowFilter.counts(subrole: "AXStandardWindow", fullScreen: false, minimized: false), "standard")
        try expect(!WindowFilter.counts(subrole: "AXDialog", fullScreen: false, minimized: false), "dialog")
        try expect(!WindowFilter.counts(subrole: "AXFloatingWindow", fullScreen: false, minimized: false), "palette")
        try expect(!WindowFilter.counts(subrole: "AXStandardWindow", fullScreen: true, minimized: false), "full screen")
        try expect(!WindowFilter.counts(subrole: "AXStandardWindow", fullScreen: false, minimized: true), "minimised")
    }),
    ("desktop position: the active Space's place on its display, 1-based", {
        let displays = [DisplaySpaces(display: "MBP", current: 5, spaces: [1, 5, 29, 208]),
                        DisplaySpaces(display: "DELL", current: 40, spaces: [40, 41])]
        try expectEqual(desktopPosition(active: 29, displays: displays), DesktopPosition(display: "MBP", number: 3))
        try expectEqual(desktopPosition(active: 41, displays: displays), DesktopPosition(display: "DELL", number: 2))
        try expectEqual(desktopPosition(active: 999, displays: displays), nil)
        try expectEqual(desktopPosition(active: nil, displays: displays), nil)
    }),
    ("status line says what the app sees, or what it misses", {
        try expectEqual(StatusLine.text(trusted: true, desktop: DesktopPosition(display: "MBP", number: 2), windows: 14, screens: 2),
                        "Desktop 2 · 14 windows on 2 screens")
        try expectEqual(StatusLine.text(trusted: true, desktop: DesktopPosition(display: "MBP", number: 1), windows: 1, screens: 1),
                        "Desktop 1 · 1 window on 1 screen")
        try expectEqual(StatusLine.text(trusted: true, desktop: nil, windows: 3, screens: 1),
                        "Desktop unknown · 3 windows on 1 screen")
        try expectEqual(StatusLine.text(trusted: false, desktop: DesktopPosition(display: "MBP", number: 2), windows: 0, screens: 2),
                        "Permission missing: Device Control and Data Access")
    }),
    ("--list report is sorted JSON with the permission, desktop, screens and windows", {
        let report = ListReport(trusted: false, desktop: DesktopPosition(display: "MBP", number: 4), screens: [laptop],
                                windows: [window(7, term, "a", 0, Frame(x: 0, y: 40, width: 10, height: 10))])
        let text = String(decoding: try report.json(), as: UTF8.self)
        try expect(text.contains("\"trusted\" : false"), text)
        try expect(text.contains("\"number\" : 4"), text)
        try expectEqual(try JSONDecoder().decode(ListReport.self, from: Data(text.utf8)), report)
    }),
]
