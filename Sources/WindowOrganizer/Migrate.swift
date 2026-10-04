import Foundation
import WindowOrganizerCore

/// A read-only view of the review app's preference domain.
private final class ReviewPreferences: PreferenceStore {
    let values: [String: Any]
    init() { values = UserDefaults.standard.persistentDomain(forName: "local.windoworganizer.review") ?? [:] }
    func value(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) {}
}

private final class OurPreferences: PreferenceStore {
    func value(forKey key: String) -> Any? { UserDefaults.standard.object(forKey: key) }
    func set(_ value: Any, forKey key: String) { UserDefaults.standard.set(value, forKey: key) }
}

/// `--migrate` is a dry run; `--migrate --apply` copies. WO_STATE_DIR (the target) and WO_REVIEW_STATE_DIR (the source) redirect it.
func runMigrate(arguments: [String], environment: [String: String]) -> Int32 {
    let apply = arguments.contains("--apply")
    let home = FileManager.default.homeDirectoryForCurrentUser
    let source = environment["WO_REVIEW_STATE_DIR"].map { URL(fileURLWithPath: $0) } ?? reviewStateDirectory(home: home)
    let target = stateDirectory(environment: environment, home: home)
    var keep: MigrationKeep?
    if let i = arguments.firstIndex(of: "--keep") {
        guard i + 1 < arguments.count, let side = MigrationKeep(rawValue: arguments[i + 1]) else { print("--keep needs review or current."); return 1 }
        keep = side
    }
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd-HHmmss"
    let layouts = migrateLayouts(from: source, to: target, apply: apply, keep: keep, date: stamp.string(from: Date()))
    if layouts == .conflict, let a = layoutSummary(at: source), let b = layoutSummary(at: target) {
        print("Review layouts: \(a).\nCurrent layouts: \(b).")
    }
    let preferences = migratePreferences(from: ReviewPreferences(), to: OurPreferences(), apply: apply)
    for line in migrationLines(layouts: layouts, preferences: preferences, apply: apply) { print(line) }
    if case .refused = layouts { return 1 }
    return layouts == .conflict ? 2 : 0
}
