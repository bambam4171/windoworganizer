import Foundation

// GPT-WO-S4: bring the review app's layouts and a few preferences into our own identity. Copy only, never move.

public enum MigrationOutcome: Equatable, Sendable {
    case nothingToMigrate
    case alreadyDone
    case copied(setups: Int)
    case conflict
    case resolved(keep: MigrationKeep, backup: String)
    case refused(String)
}

/// Which side wins when both folders hold different layouts. The other side is copied to a dated backup first.
public enum MigrationKeep: String, Equatable, Sendable { case review, current }

/// The review app kept its layouts here (bundle local.windoworganizer.review).
public func reviewStateDirectory(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/WindowOrganizerGPTReview")
}

/// Copies layouts.json from `from` to `to`. The source must be a valid layout file (schema 1 or 2); a newer or damaged
/// one is refused. Different layouts already in `to` are a conflict: nothing is written and no side is chosen. With
/// apply false nothing is written at all. The copy is written to a temporary file, read back and compared, then renamed.
public func migrateLayouts(from: URL, to: URL, apply: Bool, keep: MigrationKeep? = nil, date: String = "") -> MigrationOutcome {
    let source = from.appendingPathComponent("layouts.json"), target = to.appendingPathComponent("layouts.json")
    guard FileManager.default.fileExists(atPath: source.path) else { return .nothingToMigrate }
    let data: Data, layouts: Layouts
    do { data = try Data(contentsOf: source); layouts = try LayoutStore.decode(data) }
    catch { return .refused("The review layouts cannot be used: \(error)") }
    if FileManager.default.fileExists(atPath: target.path) {
        let current = try? Data(contentsOf: target)
        if current == data { return .alreadyDone }
        guard let keep else { return .conflict }
        guard apply else { return .resolved(keep: keep, backup: "") }
        let loser = keep == .review ? current : data
        guard let loser else { return .refused("The current layouts cannot be read; nothing was changed.") }
        let backup = to.appendingPathComponent("layouts.before-migrate-\(date).json")
        do {
            guard !FileManager.default.fileExists(atPath: backup.path) else { return .refused("\(backup.lastPathComponent) exists already; nothing was changed.") }
            try migrationWrite(loser, backup)
            guard try Data(contentsOf: backup) == loser else {
                try? FileManager.default.removeItem(at: backup)
                return .refused("The backup did not read back identically; nothing was changed.")
            }
            if keep == .review { try replaceVerified(data, at: target, in: to) }
        } catch { return .refused("Copy failed: \(error)") }
        return .resolved(keep: keep, backup: backup.lastPathComponent)
    }
    guard apply else { return .copied(setups: layouts.setups.count) }
    do {
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let temp = to.appendingPathComponent("layouts.json.migrating")
        try migrationWrite(data, temp)
        guard try Data(contentsOf: temp) == data else {
            try? FileManager.default.removeItem(at: temp)
            return .refused("The copy did not read back identically; nothing was kept.")
        }
        try FileManager.default.moveItem(at: temp, to: target)
    } catch { return .refused("Copy failed: \(error)") }
    return .copied(setups: layouts.setups.count)
}

/// The one place migration writes bytes; the checks swap it for a writer that damages the file, to prove the read-back.
nonisolated(unsafe) public var migrationWrite: (Data, URL) throws -> Void = { try $0.write(to: $1) }

private func replaceVerified(_ data: Data, at target: URL, in folder: URL) throws {
    let temp = folder.appendingPathComponent("layouts.json.migrating")
    try migrationWrite(data, temp)
    guard try Data(contentsOf: temp) == data else {
        try? FileManager.default.removeItem(at: temp)
        throw CocoaError(.fileWriteUnknown)
    }
    _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
}

/// "3 screen setups, 5 desktops" for the dry run, so Tom can choose a side; nil if the file is missing or unusable.
public func layoutSummary(at folder: URL) -> String? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("layouts.json")),
          let layouts = try? LayoutStore.decode(data) else { return nil }
    let desktops = layouts.setups.values.reduce(0) { $0 + $1.count }
    let n = layouts.setups.count
    return "\(n) screen setup\(n == 1 ? "" : "s"), \(desktops) desktop\(desktops == 1 ? "" : "s")"
}

public protocol PreferenceStore: AnyObject {
    func value(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String)
}

/// Login registration is separate OS state and is not a preference, so it is not on this list.
public let migratedPreferenceKeys = ["paused", "restoreAtLaunch", "restoreOnScreens", "arrangeNewWindows", "restoreKey"]

/// Copies the known keys that `to` does not have yet; returns the keys copied (or, with apply false, that would be).
@discardableResult
public func migratePreferences(from: PreferenceStore, to: PreferenceStore, apply: Bool) -> [String] {
    var copied: [String] = []
    for key in migratedPreferenceKeys {
        guard let value = from.value(forKey: key), to.value(forKey: key) == nil else { continue }
        if apply { to.set(value, forKey: key) }
        copied.append(key)
    }
    return copied
}

/// What `--migrate` prints: one line for the layouts, one for the preferences, and what to do next.
public func migrationLines(layouts: MigrationOutcome, preferences: [String], apply: Bool) -> [String] {
    let verb = apply ? "Copied" : "Would copy"
    var lines: [String]
    switch layouts {
    case .nothingToMigrate: lines = ["Layouts: the review app has none to bring over."]
    case .alreadyDone: lines = ["Layouts: already identical here; nothing to do."]
    case .copied(let n): lines = ["Layouts: \(verb.lowercased()) \(n) screen setup\(n == 1 ? "" : "s") from the review app; the original stays where it is."]
    case .conflict: lines = ["Layouts: both sides hold different layouts. Nothing was written. Add --keep review or --keep current to choose; the other side is saved first."]
    case .resolved(let keep, let backup):
        let kept = keep == .review ? "the review layouts" : "the current layouts"
        lines = [apply ? "Layouts: kept \(kept); the other side is saved as \(backup) and never deleted."
                       : "Layouts: would keep \(kept) and save the other side as layouts.before-migrate-<date>.json first."]
    case .refused(let why): lines = ["Layouts: not copied. \(why)"]
    }
    lines.append(preferences.isEmpty ? "Preferences: nothing to bring over." : "Preferences: \(verb.lowercased()) \(preferences.joined(separator: ", ")).")
    if !apply { lines.append("This was a dry run. Run again with --migrate --apply to copy.") }
    return lines
}
