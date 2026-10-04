import Foundation

// SORT-BY-NAME: one comparator and one ordering step, so every arrange orders windows the same way.

/// The name a window sorts by: the app's shown name, else its bundle id (an app that has not reported a name yet).
private func appKey(_ w: WindowInfo) -> String { w.appName ?? w.bundleID }

/// App name, then title, each in Finder order (2 before 10, case and accents as the Finder treats them).
/// Equal windows keep their input order through an explicit index tie-break: `sort` is not documented as stable.
public func sortedByName(_ windows: [WindowInfo]) -> [WindowInfo] {
    windows.enumerated().sorted { a, b in
        let app = appKey(a.element).localizedStandardCompare(appKey(b.element))
        if app != .orderedSame { return app == .orderedAscending }
        let title = a.element.title.localizedStandardCompare(b.element.title)
        if title != .orderedSame { return title == .orderedAscending }
        return a.offset < b.offset
    }.map(\.element)
}

/// The order a screen's windows fill its tiles in: by name when the screen's setting says so, else as given.
public func arrangeOrder(_ windows: [WindowInfo], settings: ArrangeSettings) -> [WindowInfo] {
    settings.sortsByName ? sortedByName(windows) : windows
}
