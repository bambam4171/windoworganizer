import Foundation
import WindowOrganizerCore

// GPT-WO-S4: copy the review app's layouts and a few preferences into our own identity. Copy only, never move; temp folders only.

final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    var values: [String: Any]
    var writes: [String] = []
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value; writes.append(key) }
}

private let sampleV2 = """
{
  "schema" : 2,
  "setups" : {
    "37D8832A-2D66-02CA-B9F7-8F30A301B230+CED44E9C-EB1C-4609-AD92-10FE6867CB9A" : {
      "2" : {
        "CED44E9C-EB1C-4609-AD92-10FE6867CB9A" : {
          "kind" : "autoTile"
        }
      }
    }
  }
}
"""
private let sampleV1 = sampleV2.replacingOccurrences(of: "\"schema\" : 2", with: "\"schema\" : 1")

private func folders(_ source: String?) throws -> (from: URL, to: URL, done: () -> Void) {
    let root = try tempDir()
    let from = root.appendingPathComponent("review"), to = root.appendingPathComponent("ours")
    if let source {
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: from.appendingPathComponent("layouts.json"))
    }
    return (from, to, { try? FileManager.default.removeItem(at: root) })
}

private func bytes(_ dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("layouts.json")) }

let migrationChecks: [(String, @Sendable () throws -> Void)] = [
    ("migration copies a valid schema 2 file byte for byte and leaves the source alone", {
        let f = try folders(sampleV2); defer { f.done() }
        let before = bytes(f.from)
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: true), .copied(setups: 1))
        try expectEqual(bytes(f.to), Data(sampleV2.utf8))
        try expectEqual(bytes(f.from), before)
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: f.to.path), ["layouts.json"])
    }),
    ("migration reads schema 1 and the copy loads in the new store", {
        let f = try folders(sampleV1); defer { f.done() }
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: true), .copied(setups: 1))
        try expectEqual(try LayoutStore(directory: f.to).load().setups.count, 1)
    }),
    ("migration dry run reports the copy and writes nothing", {
        let f = try folders(sampleV2); defer { f.done() }
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: false), .copied(setups: 1))
        try expect(!FileManager.default.fileExists(atPath: f.to.path), "dry run created the target folder")
    }),
    ("migration refuses a corrupt source and writes nothing", {
        let f = try folders("{ not json"); defer { f.done() }
        guard case .refused = migrateLayouts(from: f.from, to: f.to, apply: true) else { throw CheckFailure(description: "not refused") }
        try expect(!FileManager.default.fileExists(atPath: f.to.path), "target created")
    }),
    ("migration refuses a newer schema and writes nothing", {
        let f = try folders(sampleV2.replacingOccurrences(of: "\"schema\" : 2", with: "\"schema\" : 9")); defer { f.done() }
        guard case .refused = migrateLayouts(from: f.from, to: f.to, apply: true) else { throw CheckFailure(description: "not refused") }
        try expect(!FileManager.default.fileExists(atPath: f.to.path), "target created")
    }),
    ("migration never overwrites different layouts: conflict, target untouched", {
        let f = try folders(sampleV2); defer { f.done() }
        try FileManager.default.createDirectory(at: f.to, withIntermediateDirectories: true)
        let mine = Data("{\"schema\":2,\"setups\":{}}".utf8)
        try mine.write(to: f.to.appendingPathComponent("layouts.json"))
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: true), .conflict)
        try expectEqual(bytes(f.to), mine)
    }),
    ("migration run twice is already done and changes nothing", {
        let f = try folders(sampleV2); defer { f.done() }
        _ = migrateLayouts(from: f.from, to: f.to, apply: true)
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: true), .alreadyDone)
        try expectEqual(bytes(f.to), Data(sampleV2.utf8))
    }),
    ("migration with no source file has nothing to do", {
        let f = try folders(nil); defer { f.done() }
        try expectEqual(migrateLayouts(from: f.from, to: f.to, apply: true), .nothingToMigrate)
        try expect(!FileManager.default.fileExists(atPath: f.to.path), "target created")
    }),
    ("preference migration copies only the known keys and never over an existing value", {
        let old = MemoryPreferences(["paused": true, "restoreAtLaunch": true, "restoreKey": "r", "launchAtLogin": true, "other": 1])
        let new = MemoryPreferences(["restoreAtLaunch": false])
        let copied = migratePreferences(from: old, to: new, apply: true)
        try expectEqual(copied.sorted(), ["paused", "restoreKey"])
        try expectEqual(new.values["paused"] as? Bool, true)
        try expectEqual(new.values["restoreAtLaunch"] as? Bool, false)
        try expect(new.values["launchAtLogin"] == nil && new.values["other"] == nil, "unknown key copied")
    }),
    ("preference migration dry run writes nothing", {
        let old = MemoryPreferences(["paused": true]), new = MemoryPreferences()
        try expectEqual(migratePreferences(from: old, to: new, apply: false), ["paused"])
        try expect(new.writes.isEmpty, "dry run wrote")
    }),
]

let migrationTextChecks: [(String, @Sendable () throws -> Void)] = [
    ("migration text says dry run, original kept and conflict plainly", {
        let dry = migrationLines(layouts: .copied(setups: 1), preferences: ["paused"], apply: false)
        try expect(dry[0].hasPrefix("Layouts: would copy 1 screen setup") && dry[0].contains("original stays"), dry[0])
        try expect(dry.last == "This was a dry run. Run again with --migrate --apply to copy.", "no dry-run line")
        let done = migrationLines(layouts: .copied(setups: 2), preferences: [], apply: true)
        try expect(done[0].hasPrefix("Layouts: copied 2 screen setups") && done[1] == "Preferences: nothing to bring over." && done.count == 2, "\(done)")
        try expect(migrationLines(layouts: .conflict, preferences: [], apply: true)[0].contains("Nothing was written"), "conflict line")
    }),
]

private func conflictFolders() throws -> (from: URL, to: URL, done: () -> Void) {
    let f = try folders(sampleV2)
    try FileManager.default.createDirectory(at: f.to, withIntermediateDirectories: true)
    try Data(sampleV1.utf8).write(to: f.to.appendingPathComponent("layouts.json"))
    return f
}

let migrationKeepChecks: [(String, @Sendable () throws -> Void)] = [
    ("keep review saves the current layouts first, then takes the review ones", {
        let f = try conflictFolders(); defer { f.done() }
        let r = migrateLayouts(from: f.from, to: f.to, apply: true, keep: .review, date: "D")
        try expect(r == .resolved(keep: .review, backup: "layouts.before-migrate-D.json"), "\(r)")
        try expect(bytes(f.to) == Data(sampleV2.utf8), "target is not the review file")
        try expect(try Data(contentsOf: f.to.appendingPathComponent("layouts.before-migrate-D.json")) == Data(sampleV1.utf8), "backup is not the old current")
    }),
    ("keep current saves the review layouts and leaves the current ones", {
        let f = try conflictFolders(); defer { f.done() }
        let r = migrateLayouts(from: f.from, to: f.to, apply: true, keep: .current, date: "D")
        try expect(r == .resolved(keep: .current, backup: "layouts.before-migrate-D.json"), "\(r)")
        try expect(bytes(f.to) == Data(sampleV1.utf8), "current changed")
        try expect(try Data(contentsOf: f.to.appendingPathComponent("layouts.before-migrate-D.json")) == Data(sampleV2.utf8), "backup is not the review file")
    }),
    ("keep without apply writes nothing", {
        let f = try conflictFolders(); defer { f.done() }
        _ = migrateLayouts(from: f.from, to: f.to, apply: false, keep: .review, date: "D")
        try expect(bytes(f.to) == Data(sampleV1.utf8), "target changed")
        try expect(!FileManager.default.fileExists(atPath: f.to.appendingPathComponent("layouts.before-migrate-D.json").path), "backup written")
    }),
    ("an existing backup name is never overwritten", {
        let f = try conflictFolders(); defer { f.done() }
        let old = f.to.appendingPathComponent("layouts.before-migrate-D.json")
        try Data("precious".utf8).write(to: old)
        let r = migrateLayouts(from: f.from, to: f.to, apply: true, keep: .review, date: "D")
        guard case .refused = r else { throw CheckFailure(description: "expected refused, got \(r)") }
        try expect(try Data(contentsOf: old) == Data("precious".utf8) && bytes(f.to) == Data(sampleV1.utf8), "something changed")
    }),
    ("a copy that does not read back is refused and leaves nothing behind", {
        let f = try folders(sampleV2); defer { f.done() }
        migrationWrite = { data, url in try data.dropLast().write(to: url) }
        defer { migrationWrite = { try $0.write(to: $1) } }
        let r = migrateLayouts(from: f.from, to: f.to, apply: true)
        guard case .refused = r else { throw CheckFailure(description: "expected refused, got \(r)") }
        try expect(bytes(f.to) == nil, "a damaged layouts.json was kept")
    }),
    ("a backup that does not read back stops a keep and changes nothing", {
        let f = try conflictFolders(); defer { f.done() }
        migrationWrite = { data, url in try data.dropLast().write(to: url) }
        defer { migrationWrite = { try $0.write(to: $1) } }
        let r = migrateLayouts(from: f.from, to: f.to, apply: true, keep: .review, date: "D")
        guard case .refused = r else { throw CheckFailure(description: "expected refused, got \(r)") }
        try expect(bytes(f.to) == Data(sampleV1.utf8), "current changed")
        try expect(!FileManager.default.fileExists(atPath: f.to.appendingPathComponent("layouts.before-migrate-D.json").path), "bad backup left")
    }),
    ("layout summary counts setups and desktops", {
        let f = try folders(sampleV2); defer { f.done() }
        try expect(layoutSummary(at: f.from) == "1 screen setup, 1 desktop", "\(String(describing: layoutSummary(at: f.from)))")
        try expect(layoutSummary(at: f.to) == nil, "missing file should be nil")
    }),
    ("migration code never touches the login item or automation", {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["WindowOrganizerCore/Migration.swift", "WindowOrganizer/Migrate.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for word in ["SMAppService", "LaunchAgent", "osascript", "Process("] {
                try expect(!text.contains(word), "\(path) mentions \(word)")
            }
        }
        try expect(!migratedPreferenceKeys.contains { $0.lowercased().contains("login") }, "login key in the migrated list")
    }),
]
