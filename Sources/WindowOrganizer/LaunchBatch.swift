import AppKit
import WindowOrganizerCore

// Start missing apps (WO-LAUNCH-MISSING S2): one batch at a time starts the apps, places their windows as they appear,
// and ends with one result line. A batch never quits or hides an app, and never moves a window after the desktop changed.

enum LaunchOutcome: Equatable {
    case started(String)
    case notInstalled
    case failed(String)
}

@MainActor
func liveRunning() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }

@MainActor
func liveAppName(_ id: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.deletingPathExtension().lastPathComponent }
    return id
}

@MainActor
func liveLaunch(_ id: String, _ done: @escaping @MainActor (LaunchOutcome) -> Void) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { done(.notInstalled); return }
    let name = url.deletingPathExtension().lastPathComponent
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        let outcome: LaunchOutcome = error == nil ? .started(name) : .failed(name)
        Task { @MainActor in done(outcome) }
    }
}

@MainActor
final class LaunchBatch {
    /// The batch that is live; a new one ends it quietly.
    static var current: LaunchBatch?
    static var deadline: Duration = .seconds(20)
    /// Where a batch's final line goes (the menu's result line); a check replaces it.
    static var deliver: (String) -> Void = { _ in }

    private let providers: WorkspaceProviders
    private let scope: WorkspaceSelection?
    private let context: WorkspaceContext
    private let report: (String) -> Void
    private var names: [String: String] = [:]
    private var failed: [String] = []
    private var failedIDs: Set<String> = []
    private var windowed: Set<String> = []
    private var pending: Set<String>
    private var placed = 0
    private var stopped = false
    private var timer: Task<Void, Never>?
    private(set) var finished = false

    /// Starts `ids` and returns the batch (nil when there is nothing to start). `report` gets the final line.
    @discardableResult
    static func begin(_ ids: [String], scope: WorkspaceSelection?, _ p: WorkspaceProviders = .live, report: @escaping (String) -> Void = { LaunchBatch.deliver($0) }) -> LaunchBatch? {
        current?.cancel()
        guard !ids.isEmpty else { return nil }
        let batch = LaunchBatch(ids, scope: scope, p, report: report)
        current = batch; batch.run(ids)
        return batch
    }

    private init(_ ids: [String], scope: WorkspaceSelection?, _ p: WorkspaceProviders, report: @escaping (String) -> Void) {
        providers = p; self.scope = scope; context = p.context(); self.report = report
        pending = Set(ids)
        for id in ids { names[id] = p.appName(id) }
    }

    var startingNames: [String] { names.values.sorted() }
    func expects(_ bundleID: String?) -> Bool { !finished && bundleID.map { pending.contains($0) || windowed.contains($0) } == true }

    private func run(_ ids: [String]) {
        for id in ids {
            providers.launch(id) { [weak self] outcome in
                guard let self, !self.finished else { return }
                switch outcome {
                case .started(let name): self.names[id] = name
                case .notInstalled, .failed: self.failed.append(self.names[id] ?? id); self.failedIDs.insert(id); self.pending.remove(id); self.checkDone()
                }
            }
        }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.deadline)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// A window of an expected app was created and placed by the caller.
    func windowPlaced(bundleID: String, result: ApplyResult) {
        guard !finished else { return }
        if result.cancelled > 0 { stopped = true; finish(); return }
        placed += result.placed + result.keptMinimum
        windowed.insert(bundleID); pending.remove(bundleID); checkDone()
    }

    /// The desktop or a screen changed (a notification) or a window arrived while it differed: end now, move nothing.
    func contextMayHaveChanged() {
        guard !finished, providers.context() != context else { return }
        stopped = true; finish()
    }

    private func checkDone() { if pending.isEmpty { finish() } }

    func cancel() { finished = true; timer?.cancel(); if Self.current === self { Self.current = nil } }

    /// One sweep for windows that existed before the observer saw them, then the final line.
    private func finish() {
        guard !finished else { return }
        finished = true; timer?.cancel(); if Self.current === self { Self.current = nil }
        let expected = Set(names.keys).subtracting(failedIDs)
        var covered = windowed
        if !stopped, providers.context() == context {
            if let (report, listing, ctx) = try? guardedSnapshot(providers), report.trusted, listing.warnings.isEmpty,
               let layouts = try? providers.store().load(),
               let plan = planRestore(layouts, windows: report.windows, screens: report.screens, desktops: ctx.desktops, scope: scope) {
                let mine = Set(report.windows.filter { expected.contains($0.bundleID) }.map(\.windowID))
                covered.formUnion(report.windows.filter { expected.contains($0.bundleID) }.map(\.bundleID))
                let moves = plan.moves.filter { mine.contains($0.windowID) }
                if !moves.isEmpty {
                    let r = RestoreSession.shared.apply(Plan(moves: moves, skipped: [], unchanged: 0), listing: listing, context: ctx,
                                                        mover: providers.mover(listing), stillValid: { [providers] in providers.context() == ctx }, recordUndo: false)
                    if r.cancelled > 0 { stopped = true }
                    placed += r.placed + r.keptMinimum
                }
            }
        } else { stopped = true }
        let late = expected.subtracting(covered).compactMap { names[$0] }.sorted()
        let ok = expected.compactMap { names[$0] }.sorted()
        report(ResultLine.started(names: ok, placed: placed, late: late, failed: failed.sorted(), stopped: stopped,
                                  desktop: context.screens.isEmpty ? nil : desktopNumber(), at: clock()))
    }

    private func desktopNumber() -> Int? { providers.snapshot().0.desktop?.number }
}

/// The apps to start for `trigger`, or [] when its switch is off or `trigger` is nil. Starts a batch and returns their names.
@MainActor
func startMissingApps(_ trigger: LaunchTrigger?, layouts: Layouts, report: ListReport, desktops: [String: Int],
                      scope: WorkspaceSelection? = nil, _ p: WorkspaceProviders = .live) -> [String] {
    guard let trigger, Preferences.startsMissing(trigger) else { return [] }
    let ids = appsToStart(layouts, screens: report.screens, desktops: desktops, scope: scope, running: p.running())
    return LaunchBatch.begin(ids, scope: scope, p)?.startingNames ?? []
}
