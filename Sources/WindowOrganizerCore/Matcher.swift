import Foundation

// Matching windows to places (plan §2): app + optional title pattern + order. Each window is claimed once.

public struct Matcher: Codable, Equatable, Sendable {
    public var bundleID: String
    /// Plain text = "title contains"; with `*` = wildcard over the whole title. Case-insensitive.
    public var titlePattern: String?
    /// The title seen when the place was remembered; with a pinned pattern, an exact match with it wins.
    public var seenTitle: String?
    public var order: Int

    public init(bundleID: String, titlePattern: String? = nil, seenTitle: String? = nil, order: Int = 0) {
        self.bundleID = bundleID; self.titlePattern = titlePattern; self.seenTitle = seenTitle; self.order = order
    }

    public func matches(title: String) -> Bool {
        guard let pattern = titlePattern, !pattern.isEmpty else { return true }
        let t = title.lowercased(), p = pattern.lowercased()
        if !p.contains("*") { return t.contains(p) }
        return wildcard(Array(p), Array(t))
    }
}

/// `*` matches any run of characters; everything else literally; anchored at both ends.
private func wildcard(_ p: [Character], _ t: [Character]) -> Bool {
    var pi = 0, ti = 0, star = -1, mark = 0
    while ti < t.count {
        if pi < p.count, p[pi] != "*", p[pi] == t[ti] { pi += 1; ti += 1 }
        else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
        else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
        else { return false }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}

public struct MatchResult: Equatable, Sendable {
    /// One entry per matcher, in the matchers' order; nil = no window for that place.
    public var assigned: [WindowInfo?]
}

/// Places with a pinned pattern claim first (an exact title before the pattern, then the oldest window);
/// the rest by order: the place's own order if still free, else the oldest window of that app left.
public func matchWindows(_ matchers: [Matcher], _ windows: [WindowInfo]) -> MatchResult {
    var assigned = [WindowInfo?](repeating: nil, count: matchers.count)
    var claimed = Set<Int>()
    func free(_ app: String) -> [WindowInfo] {
        windows.filter { $0.bundleID == app && !claimed.contains($0.windowID) }.sorted { ($0.order, $0.windowID) < ($1.order, $1.windowID) }
    }
    for (i, m) in matchers.enumerated() where m.titlePattern != nil {
        let candidates = free(m.bundleID).filter { m.matches(title: $0.title) }
        if let w = candidates.first(where: { $0.title == m.seenTitle }) ?? candidates.first {
            assigned[i] = w; claimed.insert(w.windowID)
        }
    }
    for (i, m) in matchers.enumerated() where m.titlePattern == nil {
        if let title = m.seenTitle, !title.isEmpty,
           let w = free(m.bundleID).first(where: { $0.title == title }) {
            assigned[i] = w; claimed.insert(w.windowID)
        }
    }
    for (i, m) in matchers.enumerated() where m.titlePattern == nil && assigned[i] == nil {
        let candidates = free(m.bundleID)
        if let w = candidates.first(where: { $0.order == m.order }) ?? candidates.first {
            assigned[i] = w; claimed.insert(w.windowID)
        }
    }
    return MatchResult(assigned: assigned)
}
