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

/// The order a screen's windows fill its tiles in: by name when the screen's setting says so; else the order the user
/// arranged (matched like a snapshot, new windows last in input order); else as given.
public func arrangeOrder(_ windows: [WindowInfo], settings: ArrangeSettings) -> [WindowInfo] {
    if settings.sortsByName { return sortedByName(windows) }
    guard let order = settings.manualOrder, !order.isEmpty else { return windows }
    // Like matchWindows: every entry claims in passes (title and order, title, order, oldest of the app), so a stored
    // entry whose window closed cannot take a window that a later entry matches by its exact title. The result keeps
    // the entries' order.
    var found = [Int: WindowInfo]()
    var claimed = Set<Int>()
    func free(for m: Matcher) -> [WindowInfo] {
        windows.filter { $0.bundleID == m.bundleID && !claimed.contains($0.windowID) }
            .sorted { ($0.order, $0.windowID) < ($1.order, $1.windowID) }
    }
    let passes: [(Matcher, [WindowInfo]) -> WindowInfo?] = [
        { m, free in free.first { m.seenTitle?.isEmpty == false && $0.title == m.seenTitle && $0.order == m.order } },
        { m, free in free.first { m.seenTitle?.isEmpty == false && $0.title == m.seenTitle } },
        { m, free in free.first { $0.order == m.order } },
        { _, free in free.first },
    ]
    for pass in passes {
        for (i, m) in order.enumerated() where found[i] == nil {
            guard let w = pass(m, free(for: m)) else { continue }
            found[i] = w; claimed.insert(w.windowID)
        }
    }
    let matched = order.indices.compactMap { found[$0] }
    let taken = Set(matched.map(\.windowID))
    return matched + windows.filter { !taken.contains($0.windowID) }
}

/// The matchers that remember `windows` in this order, for `ArrangeSettings.manualOrder`.
public func manualOrder(for windows: [WindowInfo]) -> [Matcher] {
    windows.prefix(ArrangeSettings.maxManualOrder).map { Matcher(bundleID: $0.bundleID, seenTitle: $0.title, order: $0.order) }
}
