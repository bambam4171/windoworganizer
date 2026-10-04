import AppKit
import Foundation
import WindowOrganizerCore

/// Integration checks use the real editor with explicitly isolated state.
@MainActor
func runUISmoke() -> Int32 {
    guard let state = ProcessInfo.processInfo.environment["WO_STATE_DIR"], state.hasPrefix("/private/tmp/") || state.hasPrefix("/tmp/") else {
        print("UI checks require WO_STATE_DIR in a temporary folder."); return 1
    }
    _ = NSApplication.shared
    let screen = ScreenInfo(uuid: "UI-TEST", name: "Test display", frame: Frame(x: 0, y: 0, width: 1200, height: 800), visibleFrame: Frame(x: 0, y: 25, width: 1200, height: 775))
    let setup = ScreenSetup(screens: [screen])
    let w = WindowInfo(windowID: 1, bundleID: "com.apple.Terminal", title: "Build", frame: Frame(x: 10, y: 35, width: 500, height: 600), screenUUID: screen.uuid, order: 0)
    var failed = 0, passed = 0
    func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() { print("ok    UI: " + name); passed += 1 }
            else { print("FAIL  UI: " + name); failed += 1 }
        } catch { print("FAIL  UI: \(name): \(error)"); failed += 1 }
    }
    do {
        var l = Layouts(); let snapshot = remember([w], on: screen)
        l.set(snapshot, setup: setup, desktop: 1, screen: screen.uuid); try layoutStore().save(l)
        let editor = LayoutsWindow()
        var visibleDesktop = 1
        editor.contextProvider = { WorkspaceContext(screens: [screen], counts: [screen.uuid: 2], desktops: [screen.uuid: visibleDesktop]) }
        editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
        var moved: [Int] = []
        editor.applyProvider = { plan, _, _ in
            moved = plan.moves.map(\.windowID)
            return ApplyResult(placed: plan.moves.count, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: plan.skipped.count)
        }
        editor.screens = [screen]; editor.spaces = [screen.uuid: 2]
        editor.screenPopUp.addItem(withTitle: screen.name); editor.desktopPopUp.addItems(withTitles: ["Desktop 1", "Desktop 2"])
        editor.pick()
        check("rule-only Save retains the existing snapshot", {
            editor.ruleEdits[w.bundleID] = AppRule(bundleID: w.bundleID, desktop: 1, screen: screen.uuid, area: AppRule.full)
            editor.save()
            let saved = try layoutStore().load()
            return saved.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == snapshot && saved.rules.count == 1
        })
        check("title filter persists through the real editor", {
            editor.pick(); editor.placements[0].matcher.titlePattern = "*Build*"; editor.save()
            guard case .snapshot(let ps)? = try layoutStore().load().arrangement(setup: setup, desktop: 1, screen: screen.uuid)?.kind else { return false }
            return ps.first?.matcher.titlePattern == "*Build*"
        })
        check("automatic grid choice persists", {
            editor.pick(); editor.mode.selectItem(at: 2); editor.save()
            return try layoutStore().load().arrangement(setup: setup, desktop: 1, screen: screen.uuid)?.kind == .autoTile
        })
        check("preset creates a selected zone without overlapping access", {
            editor.pick(); editor.mode.selectItem(at: 1); editor.preset.selectItem(at: 2); editor.addPreset()
            return editor.canvas.editor?.selected == 0 && editor.canvas.editor?.zones.first?.rect == UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        })
        check("zones and app membership persist", {
            editor.pick(); editor.mode.selectItem(at: 1)
            editor.canvas.editor?.zones = [Zone(rect: AppRule.full, members: [ZoneMember(bundleID: w.bundleID, titlePattern: "Build")])]
            editor.save()
            return try layoutStore().load().arrangement(setup: setup, desktop: 1, screen: screen.uuid)?.kind == .zones(editor.canvas.editor!.zones)
        })
        check("clearing zones allows Remember to work again", {
            editor.pick(); editor.canvas.editor?.zones = []; editor.save()
            return try layoutStore().load().arrangement(setup: setup, desktop: 1, screen: screen.uuid) == nil
        })
        check("editing another desktop preserves the first desktop", {
            var saved = try layoutStore().load(); saved.set(snapshot, setup: setup, desktop: 1, screen: screen.uuid); try layoutStore().save(saved)
            editor.desktopPopUp.selectItem(at: 1); editor.pick(); editor.mode.selectItem(at: 2); editor.save()
            let loaded = try layoutStore().load()
            return loaded.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == snapshot && loaded.arrangement(setup: setup, desktop: 2, screen: screen.uuid)?.kind == .autoTile
        })
        check("capture stages current positions without writing until Save", {
            visibleDesktop = 2; editor.pick()
            let before = try Data(contentsOf: layoutStore().file)
            editor.captureCurrent()
            guard editor.capturedDraft, editor.placements.count == 1, try Data(contentsOf: layoutStore().file) == before else { return false }
            editor.save()
            let saved = try layoutStore().load()
            return saved.arrangement(setup: setup, desktop: 2, screen: screen.uuid) == snapshot && saved.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == snapshot
        })
        check("automatic action previews moves and persists only after Save", {
            let before = try Data(contentsOf: layoutStore().file)
            editor.arrangeCurrent()
            guard moved == [1], editor.capturedDraft, try Data(contentsOf: layoutStore().file) == before else { return false }
            editor.save()
            return try layoutStore().load().arrangement(setup: setup, desktop: 2, screen: screen.uuid)?.kind == .autoTile
        })
        check("Restore uses the saved selected desktop arrangement", {
            moved = []; editor.restoreCurrent()
            return moved == [1] && !editor.capturedDraft
        })
        check("inactive desktop capture is blocked without altering the draft", {
            visibleDesktop = 1; editor.captureCurrent()
            return !editor.capturedDraft && editor.result.stringValue.contains("Switch to the selected desktop")
        })
        check("clean editor follows visible desktop; unsaved draft stays selected", {
            editor.window.orderFront(nil); editor.workspaceDidChange()
            guard editor.desktopNumber == 1 else { return false }
            editor.captureCurrent(); visibleDesktop = 2; editor.workspaceDidChange()
            let kept = editor.desktopNumber == 1 && editor.capturedDraft
            editor.save(); editor.workspaceDidChange()
            editor.window.orderOut(nil)
            return kept && editor.desktopNumber == 2 && !editor.dirty
        })
        check("screen preview preserves aspect ratio and global display coordinates", {
            let view = ScreenPreview(frame: NSRect(x: 0, y: 0, width: 750, height: 250))
            var external = screen
            external.frame = Frame(x: 1600, y: -200, width: 1600, height: 900)
            external.visibleFrame = Frame(x: 1600, y: -175, width: 1600, height: 875)
            view.screen = external
            let display = view.displayRect()
            view.windows = [
                PreviewWindow(frame: Frame(x: 1630, y: -160, width: 700, height: 700), title: "Editor · Project", bundleID: "editor"),
                PreviewWindow(frame: Frame(x: 2360, y: -160, width: 780, height: 410), title: "Browser · Reference", bundleID: "browser"),
                PreviewWindow(frame: Frame(x: 2360, y: 275, width: 780, height: 265), title: "Terminal · Build", bundleID: "terminal")]
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            try png.write(to: URL(fileURLWithPath: state).appendingPathComponent("screen-preview.png"))
            let corner = view.previewRect(Frame(x: 1600, y: -200, width: 800, height: 450))
            return abs(display.width / display.height - 1600.0 / 900) < 0.001 && corner.minX == display.minX && corner.minY == display.minY && abs(corner.width - display.width / 2) < 0.001 && abs(corner.height - display.height / 2) < 0.001
        })
        check("live preview excludes the other display's windows", {
            let visual = LayoutsWindow(); visual.accessProvider = { true }
            var other = screen; other.uuid = "OTHER"; other.name = "Other display"; other.frame.x = 1200; other.visibleFrame.x = 1200
            let otherWindow = WindowInfo(windowID: 99, bundleID: w.bundleID, title: "Other", frame: other.visibleFrame, screenUUID: other.uuid, order: 1)
            visual.screens = [screen, other]; visual.spaces = [screen.uuid: 2, other.uuid: 2]
            visual.screenPopUp.addItems(withTitles: [screen.name, other.name]); visual.desktopPopUp.addItems(withTitles: ["Desktop 1", "Desktop 2"])
            visual.contextProvider = { WorkspaceContext(screens: [screen, other], counts: [screen.uuid: 2, other.uuid: 2], desktops: [screen.uuid: 1, other.uuid: 1]) }
            visual.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen, other], windows: [w, otherWindow]), Listing()) }
            visual.pick(); visual.refreshLivePreview()
            return visual.preview.windows.map(\.frame) == [w.frame] && visual.preview.windows[0].title.contains("Build")
        })
        check("one-click save records manual positions without moving windows or changing other desktops", {
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            moved = []; editor.saveCurrentArrangement()
            let saved = try layoutStore().load()
            return moved.isEmpty && !editor.dirty && saved.arrangement(setup: setup, desktop: 2, screen: screen.uuid) == snapshot && saved.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == snapshot && editor.previewMode.indexOfSelectedItem == 1
        })
        check("saved positions remain visible without Accessibility access", {
            editor.accessProvider = { false }; editor.previewMode.selectItem(at: 1); editor.updatePreview()
            return editor.preview.windows.first?.frame == w.frame && editor.preview.windows.first?.title.contains("Build") == true
        })
        check("a reopened editor restores manually saved positions and sizes", {
            let reopened = LayoutsWindow()
            reopened.screens = [screen]; reopened.spaces = [screen.uuid: 2]
            reopened.screenPopUp.addItem(withTitle: screen.name); reopened.desktopPopUp.addItems(withTitles: ["Desktop 1", "Desktop 2"]); reopened.desktopPopUp.selectItem(at: 1)
            reopened.contextProvider = { WorkspaceContext(screens: [screen], counts: [screen.uuid: 2], desktops: [screen.uuid: 2]) }
            var changed = w; changed.frame = Frame(x: 700, y: 200, width: 300, height: 250)
            reopened.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [changed]), Listing()) }
            var targets: [Frame] = []
            reopened.applyProvider = { plan, _, _ in
                targets = plan.moves.map(\.to)
                return ApplyResult(placed: plan.moves.count, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: plan.skipped.count)
            }
            reopened.pick(); reopened.restoreCurrent()
            return targets == [w.frame]
        })
        check("one-click save refuses an empty screen without replacing its saved positions", {
            let before = try Data(contentsOf: layoutStore().file)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: []), Listing()) }
            editor.saveCurrentArrangement()
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
            return try Data(contentsOf: layoutStore().file) == before && editor.result.stringValue.contains("No eligible windows")
        })
        check("visible-window scope filters other displays and nonstandard WindowServer layers", {
            var other = screen; other.uuid = "OTHER"; other.frame.x = 1200; other.visibleFrame.x = 1200
            func entry(_ id: Int, _ pid: Int, _ frame: Frame, _ layer: Int = 0) -> [String: Any] {
                [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowBounds as String: frame.rect.dictionaryRepresentation]
            }
            let data = [entry(1, 10, w.frame), entry(2, 20, other.visibleFrame), entry(3, 30, w.frame, 2)]
            let selected = visibleWindows(data, on: screen.uuid, screens: [screen, other])
            return selected.count == 1 && (selected.first?[kCGWindowOwnerPID as String] as? Int) == 10 && visibleWindows(data, on: nil, screens: [screen, other]).count == 2
        })
        check("partial preview keeps available windows while Save refuses incomplete capture", {
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick(); editor.accessProvider = { true }
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing(warnings: ["Test app did not respond."])) }
            let before = try Data(contentsOf: layoutStore().file)
            editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            let visible = editor.preview.windows.first?.frame == w.frame && editor.previewCaption.stringValue.contains("Test app did not respond")
            editor.saveCurrentArrangement()
            let unchanged = try Data(contentsOf: layoutStore().file) == before
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
            editor.accessProvider = { false }
            return visible && unchanged && editor.result.stringValue.contains("Not saved")
        })
        check("background refresh preserves a manually selected inactive desktop", {
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            editor.window.orderFront(nil); editor.workspaceDidChange()
            let kept = editor.desktopNumber == 2 && !editor.dirty
            editor.window.orderOut(nil)
            return kept
        })
        check("Use visible desktop selects the current pair and current-window preview", {
            editor.previewMode.selectItem(at: 1); editor.useVisibleDesktop()
            let used = editor.desktopNumber == 1 && editor.previewMode.indexOfSelectedItem == 0 && editor.result.stringValue.contains("Using Test display · Desktop 1")
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            return used
        })
        check("drag preview transforms geometry and clamps to usable screen", {
            let view = ScreenPreview(frame: NSRect(x: 0, y: 0, width: 900, height: 400)); view.screen = screen
            let moved = view.transformed(w.frame, delta: CGPoint(x: 10000, y: -10000), resize: false)
            let resized = view.transformed(w.frame, delta: CGPoint(x: -10000, y: -10000), resize: true)
            return moved.x + moved.width <= screen.visibleFrame.x + screen.visibleFrame.width && moved.y == screen.visibleFrame.y && resized.width == 180 && resized.height == 120
        })
        check("dragging stages a draft without moving or saving real windows", {
            visibleDesktop = 2; editor.accessProvider = { true }; editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            let before = try Data(contentsOf: layoutStore().file); moved = []
            editor.stageWindow(w.windowID, frame: Frame(x: 200, y: 80, width: 600, height: 500))
            let after = try Data(contentsOf: layoutStore().file)
            return editor.manualDraft?.first?.frame.x == 200 && editor.dirty && moved.isEmpty && after == before && editor.primaryButton.title == "Apply & Save"
        })
        check("presets are adjustable drafts and Reset restores live positions", {
            editor.resetDraft(); moved = []
            let button = NSButton(title: "Columns", target: nil, action: nil); button.tag = 1
            editor.stagePreset(button)
            let staged = editor.manualDraft?.first?.frame == screen.visibleFrame && moved.isEmpty
            editor.resetDraft()
            return staged && !editor.dirty && editor.preview.windows.first?.frame == w.frame
        })
        check("Apply & Save records accepted frames and removes only conflicting local rules", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            var current = w
            let target = Frame(x: 100, y: 90, width: 700, height: 600)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [current]), Listing()) }
            editor.applyProvider = { plan, _, _ in
                moved = plan.moves.map(\.windowID)
                if let frame = plan.moves.first?.to { current.frame = frame }
                return ApplyResult(placed: plan.moves.count, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: 0)
            }
            var saved = try layoutStore().load()
            saved.setRule(AppRule(bundleID: w.bundleID, desktop: 2, screen: screen.uuid, area: AppRule.full))
            saved.setRule(AppRule(bundleID: "other", desktop: 1, screen: screen.uuid, area: AppRule.full))
            try layoutStore().save(saved)
            editor.stageWindow(w.windowID, frame: target); editor.applyAndSave()
            let stored = try layoutStore().load()
            guard case .snapshot(let positions)? = stored.arrangement(setup: setup, desktop: 2, screen: screen.uuid)?.kind else { return false }
            return moved == [1] && !editor.dirty && positions.first?.pixel == target && stored.rules.map(\.bundleID) == ["other"] && stored.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == snapshot
        })
        check("a canvas draft blocks an Advanced Save and writes nothing", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            let before = try Data(contentsOf: layoutStore().file)
            editor.stageWindow(w.windowID, frame: Frame(x: 210, y: 90, width: 500, height: 400))
            editor.mode.selectItem(at: 2); editor.save()
            let after = try Data(contentsOf: layoutStore().file)
            return after == before && editor.manualDraft != nil && editor.unsaved.contains("canvas preview")
                && editor.result.stringValue == "Not saved: the canvas preview is not applied yet. Apply & Save it or Reset it first."
        })
        check("Apply & Save keeps pending rule edits", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            var current = w
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [current]), Listing()) }
            editor.applyProvider = { plan, _, _ in
                if let frame = plan.moves.first?.to { current.frame = frame }
                return ApplyResult(placed: plan.moves.count, keptMinimum: 0, failed: 0, unchanged: plan.unchanged, notOpen: 0)
            }
            editor.ruleEdits["kept.rule"] = AppRule(bundleID: "kept.rule", desktop: 2, screen: screen.uuid, area: AppRule.full)
            editor.stageWindow(w.windowID, frame: Frame(x: 120, y: 95, width: 640, height: 520)); editor.applyAndSave()
            let stored = try layoutStore().load()
            return stored.rules.map(\.bundleID).contains("kept.rule") && editor.ruleEdits.isEmpty && !editor.dirty
        })
        check("Apply & Save refuses while Advanced edits are pending", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview(); moved = []
            let before = try Data(contentsOf: layoutStore().file)
            editor.mode.selectItem(at: 2)
            editor.stageWindow(w.windowID, frame: Frame(x: 140, y: 100, width: 600, height: 480)); editor.applyAndSave()
            let after = try Data(contentsOf: layoutStore().file)
            return moved.isEmpty && after == before && editor.manualDraft != nil
                && editor.result.stringValue == "Not applied: Advanced has unsaved changes for this desktop. Save or discard them first."
        })
        check("dirty and the result line agree", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            var agree = editor.dirty == !editor.unsaved.isEmpty && !editor.dirty
            editor.ruleEdits["agree.rule"] = AppRule(bundleID: "agree.rule", desktop: 2, screen: screen.uuid, area: AppRule.full)
            agree = agree && editor.dirty && editor.unsaved == ["app rules"]
            editor.save()
            return agree && !editor.dirty && editor.unsaved.isEmpty && !editor.result.stringValue.hasPrefix("Not")
        })
        check("a changed set of open windows blocks stale preview application", {
            editor.pick(); editor.previewMode.selectItem(at: 0); editor.refreshLivePreview()
            editor.stageWindow(w.windowID, frame: screen.visibleFrame)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: []), Listing()) }; moved = []
            let before = try Data(contentsOf: layoutStore().file); editor.applyAndSave()
            let after = try Data(contentsOf: layoutStore().file)
            let blocked = moved.isEmpty && editor.manualDraft != nil && editor.result.stringValue.contains("open windows changed") && after == before
            editor.resetDraft(); editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }; editor.pick()
            return blocked
        })
        check("main workflow renders without advanced controls crowding the canvas", {
            editor.window.contentView?.layoutSubtreeIfNeeded()
            guard let content = editor.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent("workflow.png"))
            return editor.preview.bounds.height >= 330 && editor.preview.bounds.width >= 800 && editor.mode.window === editor.advancedWindow && editor.primaryButton.window === editor.window
        })
        check("each preset includes new same-app windows instead of retaining a one-window draft", {
            visibleDesktop = 2; editor.accessProvider = { true }; editor.pick(); editor.previewMode.selectItem(at: 0)
            editor.stageWindow(w.windowID, frame: screen.visibleFrame)
            let second = WindowInfo(windowID: 2, bundleID: w.bundleID, title: w.title, frame: w.frame, screenUUID: screen.uuid, order: 1)
            let third = WindowInfo(windowID: 3, bundleID: w.bundleID, title: w.title, frame: w.frame, screenUUID: screen.uuid, order: 2)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w, second, third]), Listing()) }
            // Context invalidation may clear the cached live list while the earlier draft remains.
            editor.previewContext = nil; editor.refreshWorkspaceStatus()
            guard editor.liveWindows.isEmpty, editor.presetButtons.allSatisfy(\.isEnabled) else { return false }
            moved = []
            let before = try Data(contentsOf: layoutStore().file)
            for tag in 0...2 {
                let button = NSButton(title: ["Grid", "Columns", "Rows"][tag], target: nil, action: nil); button.tag = tag
                editor.stagePreset(button)
                guard editor.preview.windows.count == 3, Set(editor.preview.windows.compactMap(\.windowID)) == [1, 2, 3] else { return false }
                let rects = editor.preview.windows.map { editor.preview.previewRect($0.frame) }
                guard rects.indices.allSatisfy({ i in rects.indices.allSatisfy { j in i == j || rects[i].intersection(rects[j]).isEmpty } }) else { return false }
            }
            let after = try Data(contentsOf: layoutStore().file)
            return moved.isEmpty && before == after && editor.previewCaption.stringValue.contains("3 windows in preview")
        })
        check("Refresh clears the preset draft and reloads changed positions and window count", {
            var shifted = w; shifted.frame = Frame(x: 300, y: 100, width: 450, height: 350)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [shifted]), Listing()) }
            editor.refreshCurrentWindows()
            return editor.manualDraft == nil && editor.preview.windows.map(\.frame) == [shifted.frame] && editor.preview.windows.count == 1 && editor.primaryButton.title == "Save layout" && editor.presetButtons.allSatisfy(\.isEnabled) && editor.result.stringValue.contains("Refreshed")
        })
        check("Refresh from Saved returns to the live canvas and updates controls immediately", {
            editor.previewMode.selectItem(at: 1); editor.updatePreview(); editor.refreshCurrentWindows()
            return editor.previewMode.indexOfSelectedItem == 0 && editor.preview.editable && editor.primaryButton.isEnabled && editor.previewCaption.stringValue.contains("1 windows")
        })
        check("failed Refresh preserves the unsaved draft and explains the failure", {
            editor.stageWindow(w.windowID, frame: screen.visibleFrame)
            let before = editor.manualDraft
            editor.snapshotProvider = { (ListReport(trusted: false, desktop: nil, screens: [screen], windows: []), Listing()) }
            editor.refreshCurrentWindows()
            let kept = editor.manualDraft == before && editor.result.stringValue.contains("Refresh unavailable")
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }; editor.resetDraft(); editor.pick()
            return kept
        })
        check("transition during enumeration cancels the action", {
            editor.snapshotProvider = {
                visibleDesktop = 1
                return (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing())
            }
            editor.captureCurrent()
            return !editor.capturedDraft && editor.result.stringValue.contains("changed")
        })
        // The global paths (menu, trigger, new window) run on injected providers only: no real window is ever moved.
        let backup = try Data(contentsOf: layoutStore().file)
        var guardLayouts = Layouts(); guardLayouts.set(remember([w], on: screen), setup: setup, desktop: 1, screen: screen.uuid)
        try layoutStore().save(guardLayouts)
        let guardBase = try Data(contentsOf: layoutStore().file)
        let wMoved = WindowInfo(windowID: 1, bundleID: w.bundleID, title: w.title, frame: Frame(x: 300, y: 200, width: 400, height: 300), screenUUID: screen.uuid, order: 0)
        let atDesktop1 = WorkspaceContext(screens: [screen], counts: [screen.uuid: 2], desktops: [screen.uuid: 1], identities: [DisplaySpaces(display: "d", current: 1, spaces: [1, 2])])
        var atDesktop2 = atDesktop1; atDesktop2.desktops = [screen.uuid: 2]
        let fakeElement = AXUIElementCreateApplication(1)
        final class CountingMover: WindowMover {
            var frames: [Int: Frame] = [:]; var sets: [Int] = []
            var onSet: () -> Void = {}
            func frame(of id: Int) -> Frame? { frames[id] }
            func setFrame(_ f: Frame, of id: Int) { sets.append(id); frames[id] = f; onSet() }
        }
        /// A provider set whose context reads are numbered; `flipAt` is the first read (1-based) that already shows desktop 2.
        func fake(_ mover: CountingMover, flipAt: Int?, windows: [WindowInfo] = [wMoved]) -> WorkspaceProviders {
            var reads = 0
            var p = WorkspaceProviders.live
            p.context = { reads += 1; return flipAt.map { reads >= $0 } == true ? atDesktop2 : atDesktop1 }
            p.snapshot = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: windows), Listing(windows: windows, elements: [1: fakeElement], warnings: [])) }
            p.mover = { _ in mover }
            return p
        }
        check("switch during enumeration: Remember and Restore do nothing", {
            let mover = CountingMover()
            let remembered = rememberNow(fake(mover, flipAt: 2))
            let restored = restoreNow(automatic: false, fake(mover, flipAt: 2)) ?? ""
            return try Data(contentsOf: layoutStore().file) == guardBase && mover.sets.isEmpty
                && remembered.contains("changed") && restored.contains("changed")
        })
        check("switch between moves: Restore stops", {
            var two = guardLayouts
            let w2 = WindowInfo(windowID: 2, bundleID: "com.apple.Notes", title: "n", frame: Frame(x: 20, y: 40, width: 300, height: 300), screenUUID: screen.uuid, order: 1)
            two.set(remember([w, w2], on: screen), setup: setup, desktop: 1, screen: screen.uuid); try layoutStore().save(two)
            let mover = CountingMover(); var reads = 0
            var p = fake(mover, flipAt: nil, windows: [wMoved, WindowInfo(windowID: 2, bundleID: w2.bundleID, title: "n", frame: Frame(x: 600, y: 500, width: 200, height: 200), screenUUID: screen.uuid, order: 1)])
            mover.onSet = { reads = 1 }
            p.context = { reads == 0 ? atDesktop1 : atDesktop2 }
            let line = restoreNow(automatic: false, p) ?? ""
            try layoutStore().save(guardLayouts)
            return mover.sets.count == 1 && line.hasPrefix("Stopped")
        })
        check("Restore plans from the context's desktop, not a fresh read", {
            var two = Layouts(); two.set(remember([w], on: screen), setup: setup, desktop: 2, screen: screen.uuid); try layoutStore().save(two)
            defer { try? layoutStore().save(guardLayouts) }
            let mover = CountingMover(); var p = fake(mover, flipAt: nil)
            p.context = { atDesktop2 }
            let line = restoreNow(automatic: false, p) ?? ""
            return mover.sets == [1] && line.contains("placed")
        })
        check("switch before saving: Remember writes nothing", {
            let mover = CountingMover()
            let line = rememberNow(fake(mover, flipAt: 3))
            return try Data(contentsOf: layoutStore().file) == guardBase && line.contains("the desktop changed")
        })
        check("Remember on the right desktop still saves (control)", {
            try layoutStore().save(Layouts())
            let line = rememberNow(fake(CountingMover(), flipAt: nil))
            let saved = try layoutStore().load()
            try layoutStore().save(guardLayouts)
            return line.contains("remembered") && saved.arrangement(setup: setup, desktop: 1, screen: screen.uuid) != nil
        })
        check("new-window placement on the wrong desktop does nothing", {
            let mover = CountingMover()
            let wrong = placeNewWindow(fakeElement, app: "Terminal", fake(mover, flipAt: 2))
            let right = CountingMover()
            let placed = placeNewWindow(fakeElement, app: "Terminal", fake(right, flipAt: nil))
            return wrong == nil && mover.sets.isEmpty && placed?.contains("placed") == true && right.sets == [1]
        })
        // WO-LAUNCH-MISSING S2: the start switches, the batch and the editor's Apply & Save, all on injected providers.
        let notes = "com.apple.Notes"
        let w2 = WindowInfo(windowID: 2, bundleID: notes, title: "n", frame: Frame(x: 20, y: 40, width: 300, height: 300), screenUUID: screen.uuid, order: 1)
        let wNotes = WindowInfo(windowID: 2, bundleID: notes, title: "n", frame: Frame(x: 600, y: 500, width: 200, height: 200), screenUUID: screen.uuid, order: 1)
        var withNotes = Layouts(); withNotes.set(remember([w, w2], on: screen), setup: setup, desktop: 1, screen: screen.uuid)
        let realDefaults = Preferences.defaults, suiteName = "wo.smoke.\(getpid())"
        Preferences.defaults = UserDefaults(suiteName: suiteName)!
        defer { Preferences.defaults.removePersistentDomain(forName: suiteName); Preferences.defaults = realDefaults; LaunchBatch.deliver = { _ in } }
        final class Calls { var ids: [String] = [] }
        func launching(_ mover: CountingMover, _ calls: Calls, windows: [WindowInfo] = [wMoved], outcome: LaunchOutcome? = .started("Notes")) -> WorkspaceProviders {
            var p = fake(mover, flipAt: nil, windows: windows)
            p.running = { [w.bundleID] }
            p.launch = { id, done in calls.ids.append(id); if let outcome { done(outcome) } }
            p.appName = { $0 == notes ? "Notes" : $0 }
            return p
        }
        var lines: [String] = []
        LaunchBatch.deliver = { lines.append($0) }
        LaunchBatch.deadline = .milliseconds(100)
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        check("start switches: unset keys read their defaults, a stored value wins, the checkbox agrees", {
            let before = Preferences.startsMissing(.restore) && Preferences.startsMissing(.applySave) && Preferences.startsMissing(.screenPlug) && !Preferences.startsMissing(.login)
            let settings = SettingsWindow(); settings.refresh()
            @MainActor func box(_ t: LaunchTrigger) -> NSButton { settings.startToggles.first { $0.identifier?.rawValue == "startMissing." + t.rawValue }! }
            let shown = box(.restore).state == .on && box(.login).state == .off
            Preferences.defaults.set(true, forKey: "startMissing.login"); Preferences.defaults.set(false, forKey: "startMissing.restore")
            settings.refresh()
            let stored = Preferences.startsMissing(.login) && !Preferences.startsMissing(.restore) && box(.login).state == .on && box(.restore).state == .off
            Preferences.defaults.removeObject(forKey: "startMissing.login"); Preferences.defaults.removeObject(forKey: "startMissing.restore")
            return before && shown && stored
        })
        check("start switches: a child is greyed while its parent is off, and keeps its value", {
            let settings = SettingsWindow()
            Preferences.defaults.set(false, forKey: "restoreOnScreens"); Preferences.defaults.set(false, forKey: "restoreAtLaunch"); settings.refresh()
            @MainActor func box(_ t: LaunchTrigger) -> NSButton { settings.startToggles.first { $0.identifier?.rawValue == "startMissing." + t.rawValue }! }
            let off = !box(.screenPlug).isEnabled && !box(.login).isEnabled && box(.restore).isEnabled && box(.screenPlug).state == .on && box(.screenPlug).toolTip?.contains("Restore after displays change") == true
            Preferences.defaults.set(true, forKey: "restoreOnScreens"); Preferences.defaults.set(true, forKey: "restoreAtLaunch"); settings.refresh()
            let on = box(.screenPlug).isEnabled && box(.login).isEnabled
            Preferences.defaults.removeObject(forKey: "restoreOnScreens"); Preferences.defaults.removeObject(forKey: "restoreAtLaunch")
            return off && on
        })
        check("Restore, a plug and a start each start the missing app only when their switch is on; nil starts nothing", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts) }
            var ok = true
            for t in [LaunchTrigger.restore, .screenPlug, .login] {
                for on in [true, false] {
                    Preferences.defaults.set(on, forKey: "startMissing." + t.rawValue)
                    let calls = Calls(); let line = restoreNow(automatic: t != .restore, launch: t, launching(CountingMover(), calls)) ?? ""
                    LaunchBatch.current?.cancel()
                    ok = ok && calls.ids == (on ? [notes] : []) && line.contains("starting Notes") == on
                    Preferences.defaults.removeObject(forKey: "startMissing." + t.rawValue)
                }
            }
            for t in LaunchTrigger.allCases { Preferences.defaults.set(true, forKey: "startMissing." + t.rawValue) }
            let calls = Calls(); _ = restoreNow(automatic: false, launch: nil, launching(CountingMover(), calls)); LaunchBatch.current?.cancel()
            for t in LaunchTrigger.allCases { Preferences.defaults.removeObject(forKey: "startMissing." + t.rawValue) }
            return ok && calls.ids.isEmpty
        })
        check("a settle with the same screens (wake, resolution) is no plug; a gained screen is; a pending desktop never starts", {
            var watch = ScreenWatch(known: ["A"])
            let wake = launchTrigger(for: .screensSettled(displays: []), plugged: watch.settle(["A"]))
            let plug = launchTrigger(for: .screensSettled(displays: []), plugged: watch.settle(["A", "B"]))
            let again = launchTrigger(for: .screensSettled(displays: []), plugged: watch.settle(["A", "B"]))
            let unplug = launchTrigger(for: .screensSettled(displays: []), plugged: watch.settle(["A"]))
            return wake == nil && plug == .screenPlug && again == nil && unplug == nil
                && launchTrigger(for: .spaceChanged(displays: []), plugged: true) == nil && launchTrigger(for: .start(screens: [], displays: []), plugged: false) == .login
        })
        check("a batch expects only the apps it started, and not after it ended", {
            let batch = LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: nil)) { _ in }
            let during = batch?.expects(notes) == true && batch?.expects(w.bundleID) == false && batch?.expects(nil) == false
            batch?.cancel()
            return during && batch?.expects(notes) == false && LaunchBatch.current == nil
        })
        check("the sweep places a window that existed before the batch saw it, and only that app's", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts) }
            lines = []; let mover = CountingMover(), calls = Calls()
            LaunchBatch.begin([notes], scope: nil, launching(mover, calls, windows: [wMoved, wNotes]))
            spin()
            return calls.ids == [notes] && mover.sets == [2] && lines.count == 1 && lines[0].contains("started Notes")
        })
        check("an app that opens no window is named late after the deadline", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts) }
            lines = []; let mover = CountingMover()
            LaunchBatch.begin([notes], scope: nil, launching(mover, Calls(), windows: [wMoved]))
            spin()
            return mover.sets.isEmpty && lines.count == 1 && lines[0].contains("Notes did not open a window within 20 s")
        })
        check("a desktop change ends the batch at once and moves nothing", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts) }
            lines = []; let mover = CountingMover(); var desk = atDesktop1
            var p = launching(mover, Calls(), windows: [wMoved, wNotes], outcome: nil); p.context = { desk }
            let batch = LaunchBatch.begin([notes], scope: nil, p)
            desk = atDesktop2; batch?.contextMayHaveChanged()
            spin()
            return mover.sets.isEmpty && lines.count == 1 && lines[0].contains("stopped placing: the desktop changed") && batch?.finished == true
        })
        check("a notification with the same desktop does not end the batch", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts); LaunchBatch.current?.cancel() }
            lines = []; let mover = CountingMover()
            let batch = LaunchBatch.begin([notes], scope: nil, launching(mover, Calls(), outcome: nil))
            batch?.contextMayHaveChanged()
            return batch?.finished == false && lines.isEmpty
        })
        check("only a window of an app the batch waits for belongs to the batch", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts); LaunchBatch.current?.cancel() }
            let batch = LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: nil))
            return batch != nil && LaunchBatch.owner(of: notes) === batch && LaunchBatch.owner(of: "com.apple.Safari") == nil && LaunchBatch.owner(of: nil) == nil
        })
        check("a missing or failing app is named in the final line", {
            try layoutStore().save(withNotes); defer { try? layoutStore().save(guardLayouts) }
            lines = []
            LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: .notInstalled))
            LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: .failed("Notes")))
            return lines.count == 2 && lines.allSatisfy { $0.contains("Notes could not be started") }
        })
        check("a second batch ends the first without a line of its own", {
            lines = []
            let first = LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: nil))
            let second = LaunchBatch.begin([notes], scope: nil, launching(CountingMover(), Calls(), outcome: nil))
            let ended = first?.finished == true && second?.finished == false && LaunchBatch.current === second
            spin()
            return ended && lines.count == 1
        })
        check("Apply & Save starts the missing member of a zones layout; the capture layout and a switch that is off start nothing", {
            defer { try? layoutStore().save(guardLayouts); LaunchBatch.current?.cancel() }
            let zone = Zone(rect: UnitRect(x: 0, y: 0, width: 1, height: 1), members: [ZoneMember(bundleID: notes)])
            var zoned = Layouts(); zoned.set(ScreenArrangement(kind: .zones([zone])), setup: setup, desktop: 1, screen: screen.uuid)
            editor.desktopPopUp.selectItem(at: 0); editor.pick()
            @MainActor func run(_ layouts: Layouts, on: Bool) throws -> [String] {
                try layoutStore().save(layouts); Preferences.defaults.set(on, forKey: "startMissing.applySave")
                let calls = Calls(); editor.launchProviders = launching(CountingMover(), calls, outcome: nil)
                editor.startAfterSave(); LaunchBatch.current?.cancel(); return calls.ids
            }
            let zones = try run(zoned, on: true), capture = try run(guardLayouts, on: true), off = try run(zoned, on: false)
            Preferences.defaults.removeObject(forKey: "startMissing.applySave"); editor.launchProviders = launching(CountingMover(), Calls(), outcome: nil)
            return zones == [notes] && capture.isEmpty && off.isEmpty
        })
        func shot(_ window: NSWindow, _ name: String) throws {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            // Offscreen, the window background is not painted: give the content view the appearance's own background.
            view.wantsLayer = true
            window.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            view.layer?.backgroundColor = nil
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent(name + ".png"))
        }
        check("shots: Settings with a greyed switch (light, dark) and the editor member hint in both states", {
            defer { Preferences.defaults.removeObject(forKey: "restoreOnScreens"); Preferences.defaults.removeObject(forKey: "startMissing.restore"); try? layoutStore().save(guardLayouts) }
            Preferences.defaults.set(false, forKey: "restoreOnScreens")
            let settings = SettingsWindow(); settings.refresh()
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                settings.window.appearance = NSAppearance(named: appearance); settings.window.contentView?.layoutSubtreeIfNeeded()
                try shot(settings.window, "settings-start-missing-\(mode)")
            }
            let screenPlug = settings.startToggles.first { $0.identifier?.rawValue == "startMissing.screenPlug" }!
            let greyed = !screenPlug.isEnabled
            // A name that sorts first, so the member row with its hint is inside the shot.
            let zone = Zone(rect: UnitRect(x: 0, y: 0, width: 1, height: 1), members: [ZoneMember(bundleID: "a.first.app")])
            var zoned = Layouts(); zoned.set(ScreenArrangement(kind: .zones([zone])), setup: setup, desktop: 1, screen: screen.uuid)
            try layoutStore().save(zoned)
            var hints: [String] = []
            for on in [true, false] {
                Preferences.defaults.set(on, forKey: "startMissing.restore")
                let ed = LayoutsWindow(); ed.accessProvider = { true }
                ed.contextProvider = { WorkspaceContext(screens: [screen], counts: [screen.uuid: 2], desktops: [screen.uuid: 1]) }
                ed.launchProviders = launching(CountingMover(), Calls(), outcome: nil)
                ed.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
                ed.screens = [screen]; ed.spaces = [screen.uuid: 2]
                ed.screenPopUp.addItem(withTitle: screen.name); ed.desktopPopUp.addItems(withTitles: ["Desktop 1", "Desktop 2"])
                ed.mode.selectItem(at: 1); ed.pick(); ed.canvas.editor?.selected = 0; ed.refresh()
                ed.advancedWindow.setContentSize(NSSize(width: 980, height: 640)); ed.advancedWindow.contentView?.layoutSubtreeIfNeeded()
                if let hint = ed.members.arrangedSubviews.compactMap({ ($0 as? NSStackView)?.arrangedSubviews.first { $0.identifier?.rawValue == "memberHint" } as? NSTextField }).first { hints.append(hint.stringValue) }
                try shot(ed.advancedWindow, "editor-member-hint-" + (on ? "starts" : "off"))
                ed.window.close(); ed.advancedWindow.close()
            }
            return greyed && hints == [LayoutsWindow().memberHint(startsOnRestore: true), LayoutsWindow().memberHint(startsOnRestore: false)]
        })
        check("automatic restore waits while the editor holds a draft", {
            LayoutsWindow.shown = editor; editor.pick(); editor.ruleEdits["draft.rule"] = AppRule(bundleID: "draft.rule", desktop: 1, screen: screen.uuid, area: AppRule.full)
            defer { LayoutsWindow.shown = nil; editor.pick() }
            let mover = CountingMover(), menu = CountingMover()
            let automatic = restoreNow(automatic: true, fake(mover, flipAt: nil))
            let viaMenu = restoreNow(automatic: false, fake(menu, flipAt: nil))
            let newWindow = placeNewWindow(fakeElement, app: "Terminal", fake(mover, flipAt: nil))
            return automatic == nil && newWindow == nil && mover.sets.isEmpty && menu.sets == [1] && viaMenu != nil
        })
        try backup.write(to: layoutStore().file)
        check("settings-only save keeps the layout and rules", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            editor.ruleEdits[w.bundleID] = AppRule(bundleID: w.bundleID, desktop: 1, screen: screen.uuid, area: AppRule.full)
            editor.save()
            let seeded = try layoutStore().load()
            editor.setOrderAuto(true); editor.sortToggled()
            guard editor.unsaved == ["window order"] else { return false }
            editor.applyAndSave()
            let after = try layoutStore().load()
            try layoutStore().save(before)
            editor.setOrderAuto(false); editor.pick()
            return after.rules == seeded.rules && !after.rules.isEmpty
                && after.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == seeded.arrangement(setup: setup, desktop: 1, screen: screen.uuid)
                && after.arrangeSettings(desktop: 1, screen: screen.uuid).sortsByName
        })
        check("the order menu persists for this screen and desktop only", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            guard !editor.orderIsAuto, editor.unsaved.isEmpty else { return false }
            editor.setOrderAuto(true); editor.sortToggled()
            guard editor.unsaved == ["window order"] else { return false }
            editor.applyAndSave()
            let saved = try layoutStore().load()
            let reloaded = editor.loadedSettings.sortsByName && editor.unsaved.isEmpty
            let other = saved.arrangeSettings(desktop: 2, screen: screen.uuid).sortsByName
            let here = saved.arrangeSettings(desktop: 1, screen: screen.uuid).sortsByName
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            let otherOff = !editor.orderIsAuto
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.pick()
            let backOn = editor.orderIsAuto
            editor.setOrderAuto(false); editor.sortToggled(); editor.applyAndSave()
            let cleared = try layoutStore().load().arrange.isEmpty
            try layoutStore().save(before)
            return reloaded && here && !other && otherOff && backOn && cleared
        })
        check("a sorted preset reads in name order", {
            let names: [(String, Int)] = [("Safari", 1), ("Mail", 2), ("Terminal", 3), ("Notes", 4)]
            let named = names.map { name, id in
                WindowInfo(windowID: id, bundleID: "com.apple.\(name)", title: "", frame: w.frame, screenUUID: screen.uuid, order: id, appName: name)
            }
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick(); editor.previewMode.selectItem(at: 0)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: named), Listing()) }
            let button = NSButton(title: "Grid", target: nil, action: nil); button.tag = 0
            editor.setOrderAuto(false); editor.sortToggled(); editor.stagePreset(button)
            let plain = editor.manualDraft?.map(\.windowID) == [1, 2, 3, 4] && !editor.result.stringValue.contains("sorted by name")
            editor.setOrderAuto(true); editor.sortToggled(); editor.stagePreset(button)
            let draft = editor.manualDraft ?? []
            let ordered = draft.map(\.windowID) == [2, 4, 1, 3] && editor.result.stringValue.contains("sorted by name")
            let reading = zip(draft, draft.dropFirst()).allSatisfy { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
            @MainActor func shoot(_ prefix: String) throws -> Bool {
                for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    editor.window.appearance = NSAppearance(named: look)
                    editor.window.contentView?.layoutSubtreeIfNeeded()
                    guard let content = editor.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
                    // Offscreen, the window background is not painted: give the content view the appearance's own background.
                    content.wantsLayer = true
                    editor.window.effectiveAppearance.performAsCurrentDrawingAppearance { content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    content.layer?.backgroundColor = nil
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent("sort-\(prefix)\(name).png"))
                }
                return true
            }
            editor.setOrderAuto(false); editor.sortToggled(); editor.stagePreset(button)
            guard try shoot("before-") else { return false }
            editor.setOrderAuto(true); editor.sortToggled(); editor.stagePreset(button)
            guard try shoot("") else { return false }
            editor.window.appearance = nil
            editor.setOrderAuto(false); editor.resetDraft(); editor.sortToggled()
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
            return plain && ordered && reading
        })
        check("gap persists for this screen and desktop only", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            editor.gapField.integerValue = 8; editor.gapTyped()
            guard editor.unsaved == ["gap settings"], editor.draftSettings.gapPoints == 8 else { return false }
            editor.applyAndSave()
            let saved = try layoutStore().load()
            let here = saved.arrangeSettings(desktop: 1, screen: screen.uuid), other = saved.arrangeSettings(desktop: 2, screen: screen.uuid)
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            let otherZero = editor.gapField.integerValue == 0
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.pick()
            let back = editor.gapField.integerValue == 8 && editor.unsaved.isEmpty
            try layoutStore().save(before); editor.pick()
            return here.gapPoints == 8 && other.gapPoints == 0 && otherZero && back
        })
        check("lower switches follow Keep live", {
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            let off = !editor.pushBackSwitch.isEnabled && !editor.resizeSwitch.isEnabled && !editor.liveHint.isHidden
            editor.gapField.integerValue = 8; editor.gapTyped()
            let on = editor.keepLiveSwitch.state == .on && editor.pushBackSwitch.isEnabled && editor.resizeSwitch.isEnabled && editor.liveHint.isHidden
            editor.pick()
            return off && on
        })
        check("untouched fields stay nil", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            editor.gapField.integerValue = 8; editor.gapTyped(); editor.applyAndSave()
            let one = try layoutStore().load().arrangeSettings(desktop: 1, screen: screen.uuid)
            let onlyGap = one.gap == 8 && one.keepLive == nil && one.pushBackOnTop == nil && one.correctResize == nil && one.sortByName == nil
            editor.gapField.integerValue = 0; editor.gapTyped(); editor.applyAndSave()
            let cleared = try layoutStore().load().arrange.isEmpty
            try layoutStore().save(before); editor.pick()
            return onlyGap && cleared
        })
        check("the preview redraws with the gap", {
            let named = [1, 2, 3, 4].map { WindowInfo(windowID: $0, bundleID: "a.\($0)", title: "", frame: w.frame, screenUUID: screen.uuid, order: $0) }
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick(); editor.previewMode.selectItem(at: 0)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: named), Listing()) }
            let button = NSButton(title: "Grid", target: nil, action: nil); button.tag = 0
            editor.stagePreset(button)
            let flat = editor.manualDraft ?? []
            editor.gapField.integerValue = 8; editor.gapTyped()
            let gapped = editor.manualDraft ?? []
            let redrawn = flat != gapped && gapped.count == 4 && editor.result.stringValue.contains("gap 8 pt")
            @MainActor func shoot(_ name: String) throws {
                for (look, mode) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    editor.window.appearance = NSAppearance(named: look)
                    editor.window.contentView?.layoutSubtreeIfNeeded()
                    guard let content = editor.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                    content.wantsLayer = true
                    editor.window.effectiveAppearance.performAsCurrentDrawingAppearance { content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    content.layer?.backgroundColor = nil
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent("gap-\(name)-\(mode).png"))
                }
            }
            let wide = editor.window.frame
            for (label, width) in [("100", 1040.0), ("narrow", 880.0)] {
                editor.window.setContentSize(NSSize(width: width, height: 800))
                editor.gapField.integerValue = 0; editor.gapTyped(); editor.resetDraft()
                try shoot("\(label)-defaults")
                editor.stagePreset(button); editor.gapField.integerValue = 8; editor.gapTyped()
                try shoot("\(label)-gap8")
            }
            editor.window.setFrame(wide, display: false); editor.window.appearance = nil
            editor.gapField.integerValue = 64; editor.gapTyped()
            let noRoom = applyGap(presetFrames(.grid, count: 4, in: screen.visibleFrame), gap: 64).skipped
            let maybeSkipped = editor.result.stringValue.contains(noRoom ? "gap skipped: no room" : "gap 64 pt")
            editor.gapField.integerValue = 0; editor.gapTyped(); editor.resetDraft()
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
            return redrawn && maybeSkipped
        })
        check("the result line names what was applied", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            editor.gapField.integerValue = 8; editor.gapTyped(); editor.setOrderAuto(true); editor.sortToggled()
            editor.applyAndSave()
            let line = editor.result.stringValue
            try layoutStore().save(before); editor.pick()
            return line.hasPrefix("✓ Settings saved") && line.contains("gap 8 pt") && line.contains("sorted by name") && line.contains("keep live on")
        })
        check("the gap line fits at 880", {
            let room = 880.0 - 2 * 28
            return editor.window.minSize.width <= 880 && editor.settingRows.count == 2 && editor.settingRows.allSatisfy { $0.fittingSize.width < room }
        })
        let tileNames: [(String, Int)] = [("Safari", 1), ("Mail", 2), ("Terminal", 3), ("Notes", 4)]
        let tileWindows = tileNames.map { name, id in
            WindowInfo(windowID: id, bundleID: "com.apple.\(name)", title: "", frame: w.frame, screenUUID: screen.uuid, order: id, appName: name)
        }
        @MainActor func stageTiles() -> NSButton {
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick(); editor.previewMode.selectItem(at: 0)
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: tileWindows), Listing()) }
            let button = NSButton(title: "Grid", target: nil, action: nil); button.tag = 0
            editor.stagePreset(button); return button
        }
        @MainActor func centre(_ id: Int) -> CGPoint {
            let f = editor.presetTiles.first { $0.id == id }!.frame
            return CGPoint(x: f.x + f.width / 2, y: f.y + f.height / 2)
        }
        @MainActor func restore() {
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
        }
        check("a drop on a tile swaps in manual mode", {
            let before = try layoutStore().load()
            let button = stageTiles()
            guard !editor.orderIsAuto, editor.manualDraft?.map(\.windowID) == [1, 2, 3, 4] else { return false }
            let tile4 = centre(4), tile1 = centre(1)
            editor.dropped(1, at: tile4)
            guard editor.manualDraft?.map(\.windowID) == [4, 2, 3, 1], editor.unsaved.contains("window order"),
                  editor.result.stringValue.contains("your order") else { return false }
            editor.setOrderAuto(true); editor.sortToggled(); editor.setOrderAuto(false); editor.sortToggled()
            guard editor.manualDraft?.map(\.windowID) == [4, 2, 3, 1] else { return false }
            let shot = editor.draftSettings.manualOrder?.map(\.bundleID)
            editor.applyAndSave()
            let stored = try layoutStore().load().arrangeSettings(desktop: 1, screen: screen.uuid).manualOrder?.map(\.bundleID)
            editor.resetDraft(); editor.pick()
            _ = stageTiles()
            let reopened = editor.manualDraft?.map(\.windowID) == [4, 2, 3, 1]
            // A drop outside every tile is a free move: the order stays.
            editor.dropped(4, at: CGPoint(x: -50, y: -50))
            let free = editor.manualDraft?.map(\.windowID) == [4, 2, 3, 1]
            _ = tile1; _ = button
            try layoutStore().save(before); editor.resetDraft(); editor.pick(); restore()
            return shot == stored && stored?.first == "com.apple.Notes" && reopened && free
        })
        check("order shots", {
            let before = try layoutStore().load()
            @MainActor func shoot(_ name: String) throws {
                for (look, mode) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    editor.window.appearance = NSAppearance(named: look)
                    editor.window.contentView?.layoutSubtreeIfNeeded()
                    guard let content = editor.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                    content.wantsLayer = true
                    editor.window.effectiveAppearance.performAsCurrentDrawingAppearance { content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    content.layer?.backgroundColor = nil
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent("order-\(name)-\(mode).png"))
                }
            }
            let wide = editor.window.frame
            for (label, width) in [("100", 1040.0), ("880", 880.0)] {
                editor.window.setContentSize(NSSize(width: width, height: 800))
                _ = stageTiles()
                try shoot("\(label)-manual-before")
                editor.dropped(1, at: centre(4))
                try shoot("\(label)-manual-after")
                editor.setOrderAuto(true); editor.sortToggled()
                try shoot("\(label)-byname")
                editor.dropped(2, at: centre(3))
                try shoot("\(label)-byname-drop")
                editor.setOrderAuto(false); editor.resetDraft(); editor.pick()
            }
            editor.window.setFrame(wide, display: false); editor.window.appearance = nil
            try layoutStore().save(before); editor.pick(); restore()
            return true
        })
        check("no swap in by-name mode", {
            let before = try layoutStore().load()
            _ = stageTiles()
            editor.setOrderAuto(true); editor.sortToggled()
            let order = editor.manualDraft?.map(\.windowID)
            editor.dropped(1, at: centre(4))
            let same = editor.manualDraft?.map(\.windowID) == order && editor.draftSettings.manualOrder == nil
            let line = editor.result.stringValue.contains("Order is by app name. Choose “I arrange the order myself” to swap tiles.")
            editor.setOrderAuto(false); editor.resetDraft(); editor.sortToggled(); restore()
            try layoutStore().save(before); editor.pick()
            return same && line
        })
        check("a gap change after a swap keeps it", {
            let before = try layoutStore().load()
            _ = stageTiles()
            // As a real drag does: the dragged window moves first (stageWindow puts it at index 0), then it is dropped.
            let tile3 = editor.presetTiles.first { $0.id == 3 }!.frame
            editor.stageWindow(2, frame: tile3)
            editor.dropped(2, at: centre(3))
            let swapped = editor.manualDraft?.map(\.windowID) == [1, 3, 2, 4]
            editor.gapField.integerValue = 8; editor.gapTyped()
            let kept = editor.manualDraft?.map(\.windowID) == [1, 3, 2, 4] && editor.result.stringValue.contains("gap 8 pt")
            editor.gapField.integerValue = 0; editor.gapTyped(); editor.resetDraft(); restore()
            try layoutStore().save(before); editor.pick()
            return swapped && kept
        })
        check("corrupt state disables Save and remains unchanged", {
            let corrupt = Data("broken".utf8); try corrupt.write(to: layoutStore().file); editor.pick(); editor.save()
            let after = try Data(contentsOf: layoutStore().file)
            return editor.readFailed && !editor.saveButton.isEnabled && after == corrupt
        })
        check("two screens: a window with a minimum size wider than its tile stays inside its own screen (shots before and after)", {
            final class Stub: WindowMover {
                var frames: [Int: Frame]; let minimum: [Int: (Double, Double)]
                init(_ f: [Int: Frame], _ m: [Int: (Double, Double)]) { frames = f; minimum = m }
                func frame(of id: Int) -> Frame? { frames[id] }
                func setFrame(_ f: Frame, of id: Int) {
                    var g = f; if let (w, h) = minimum[id] { g.width = max(g.width, w); g.height = max(g.height, h) }; frames[id] = g
                }
            }
            var left = screen; left.uuid = "L"; left.name = "Laptop"; left.frame = Frame(x: 0, y: 0, width: 1200, height: 800); left.visibleFrame = Frame(x: 0, y: 25, width: 1200, height: 775)
            var right = screen; right.uuid = "R"; right.name = "Display"; right.frame = Frame(x: 1200, y: 0, width: 1200, height: 800); right.visibleFrame = Frame(x: 1200, y: 25, width: 1200, height: 775)
            let tile = Frame(x: 600, y: 25, width: 600, height: 775)
            let move = Move(windowID: 1, from: Frame(x: 100, y: 100, width: 400, height: 300), to: tile, area: left.visibleFrame)
            let mover = Stub([1: move.from, 2: Frame(x: 1300, y: 100, width: 500, height: 400)], [1: (900, 500)])
            // What the old apply left behind: the window at its tile origin with its minimum size.
            let before = Frame(x: tile.x, y: tile.y, width: 900, height: 775)
            let r = applyPlan(Plan(moves: [move], skipped: [], unchanged: 0), mover: mover)
            guard let after = mover.frame(of: 1), after.isInside(left.visibleFrame), r.shiftedIDs == [1], !before.isInside(left.visibleFrame) else { return false }
            let line = ResultLine.restored(r, shifted: ["Editor"], desktop: 1, at: "08:00")
            guard line.contains("moved inside the screen: Editor") else { return false }
            for (name, f) in [("before", before), ("after", after)] {
                let box = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 250)); box.wantsLayer = true
                box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                let views = [left, right].enumerated().map { i, s -> ScreenPreview in
                    let v = ScreenPreview(frame: NSRect(x: 10 + i * 490, y: 0, width: 480, height: 250)); v.screen = s
                    v.windows = i == 0 ? [PreviewWindow(frame: f, title: "Editor", bundleID: "editor")]
                                       : [PreviewWindow(frame: mover.frame(of: 2) ?? f, title: "Browser", bundleID: "browser")]
                                         + (name == "before" ? [PreviewWindow(frame: f, title: "Editor (hangs over)", bundleID: "editor")] : [])
                    box.addSubview(v); return v
                }
                _ = views
                guard let bitmap = box.bitmapImageRepForCachingDisplay(in: box.bounds) else { return false }
                box.cacheDisplay(in: box.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: state).appendingPathComponent("offscreen-\(name).png"))
            }
            return true
        })
        check("no check reached the real launcher, and the real launcher refuses to open an app under a test state dir", {
            var outcome: LaunchOutcome?
            liveLaunch("com.apple.mail") { outcome = $0 }
            spin()
            guard case .failed? = outcome else { return false }
            return blockedLiveLaunches == 1  // only the probe above
        })
        // WO-GROUPS G2: the group list.
        try? FileManager.default.removeItem(at: layoutStore().file)  // the corrupt-state check above left a broken file
        var groupsDesktop = 1
        var gdisplay = screen; gdisplay.uuid = "G-A"; gdisplay.name = "Studio display"
        let gwin = [WindowInfo(windowID: 11, bundleID: "com.apple.Terminal", title: "Build", frame: Frame(x: 0, y: 25, width: 600, height: 775), screenUUID: "G-A", order: 0),
                    WindowInfo(windowID: 12, bundleID: "com.apple.Terminal", title: "Logs", frame: Frame(x: 600, y: 25, width: 600, height: 775), screenUUID: "G-A", order: 1)]
        func groupsWindow(_ disconnected: Bool = false) -> GroupsWindow {
            GroupsWindow(context: { WorkspaceContext(screens: [gdisplay, screen], counts: ["G-A": 3, screen.uuid: 2], desktops: ["G-A": groupsDesktop, screen.uuid: 1]) },
                         snapshot: { (ListReport(trusted: true, desktop: nil, screens: [gdisplay, screen], windows: gwin), Listing()) })
        }
        func loadGroups() throws -> [WindowGroup] { try layoutStore().load().groups }
        func gline(_ g: GroupsWindow, _ i: Int) -> [NSView] { (g.rows.arrangedSubviews[i] as? NSStackView)?.arrangedSubviews ?? [] }
        let termMember = ZoneMember(bundleID: "com.apple.Terminal"), logMember = ZoneMember(bundleID: "com.apple.Terminal", titlePattern: "Logs")
        check("groups: the Groups… button opens the window and the rows are the stored groups in file order", {
            var l = Layouts()
            l.setGroup(WindowGroup(id: "g1", name: "Work", members: [termMember]))
            l.setGroup(WindowGroup(id: "g2", name: "Mail", members: [logMember], screen: "G-A", desktops: [1, 3]))
            try layoutStore().save(l)
            let hasButton = editor.window.contentView.map { v -> Bool in
                var found = false
                func walk(_ x: NSView) { if let b = x as? NSButton, b.title == "Groups…" { found = true }; x.subviews.forEach(walk) }
                walk(v); return found
            } ?? false
            GroupsWindow.shown = nil; GroupsWindow.show()
            defer { GroupsWindow.shown?.window.close(); GroupsWindow.shown = nil }
            guard let g = GroupsWindow.shown else { return false }
            let names = (0..<g.rows.arrangedSubviews.count).compactMap { gline(g, $0).compactMap { $0 as? NSTextField }.first?.stringValue }
            return hasButton && g.window.isVisible && names == ["Work", "Mail"]
        })
        check("groups: add + member + Save stores the group; a duplicate name is refused and the file stays byte-equal", {
            try layoutStore().save(Layouts())
            let g = groupsWindow()
            g.addGroup(openMembers: false)
            _ = g.addMember(0, bundleID: "com.apple.Terminal", pattern: nil)
            g.save()
            let one = try loadGroups()
            g.addGroup(openMembers: false); _ = g.addMember(1, bundleID: "com.apple.Notes", pattern: nil)
            g.rename(1, "group 1 ")
            let before = try Data(contentsOf: layoutStore().file)
            g.save()
            let after = try Data(contentsOf: layoutStore().file)
            return one.count == 1 && one[0].name == "Group 1" && one[0].members == [termMember] && one[0].screen == nil && one[0].mode == .tiled
                && before == after && g.status.stringValue.contains("already called") && g.dirty
        })
        check("groups: a name is trimmed when typed and stored trimmed", {
            try layoutStore().save(Layouts())
            let g = groupsWindow(); g.addGroup(openMembers: false); _ = g.addMember(0, bundleID: "com.apple.Terminal", pattern: nil)
            g.rename(0, "  Spaced out \n"); g.save()
            return try loadGroups().map(\.name) == ["Spaced out"]
        })
        check("groups: a memberless group is dropped on Save with the count in the status", {
            try layoutStore().save(Layouts())
            let g = groupsWindow(); g.addGroup(openMembers: false); g.save()
            return try loadGroups().isEmpty && g.status.stringValue.contains("1 group without apps was not saved") && !g.dirty
        })
        check("groups: removing a member of a saved group drops only its positions; the last one makes it tiled", {
            var l = Layouts()
            let pos = [GroupPosition(matcher: Matcher(bundleID: "com.apple.Terminal"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                       GroupPosition(matcher: Matcher(bundleID: "com.apple.Terminal", titlePattern: "Logs"), fraction: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))]
            l.setGroup(WindowGroup(id: "s", name: "Saved", members: [termMember, logMember], screen: "G-A", desktops: [1], mode: .saved(pos)))
            try layoutStore().save(l)
            let g = groupsWindow()
            g.removeMember(0, 1); g.save()
            guard let one = try loadGroups().first, case .saved(let left) = one.mode else { return false }
            g.removeMember(0, 0); g.save()
            let emptied = try loadGroups().isEmpty
            return left.count == 1 && left[0].matcher.titlePattern == nil && one.members == [termMember] && emptied
        })
        check("groups: Not assigned clears the desktops and disables the pull-down; a disconnected stored screen is kept", {
            var l = Layouts()
            l.setGroup(WindowGroup(id: "a", name: "A", members: [termMember], screen: "G-A", desktops: [1, 3]))
            l.setGroup(WindowGroup(id: "b", name: "B", members: [termMember], screen: "GONE", desktops: [2]))
            try layoutStore().save(l)
            let g = groupsWindow()
            g.toggleDesktop(0, 2)
            let toggled = g.draft[0].desktops == [1, 2, 3]
            g.setScreen(0, nil)
            let desks = gline(g, 0).compactMap { $0 as? NSPopUpButton }[1]
            let cleared = g.draft[0].desktops.isEmpty && !desks.isEnabled
            let gonePop = gline(g, 1).compactMap { $0 as? NSPopUpButton }[0]
            g.toggleDesktop(1, 1); g.save()
            let stored = try loadGroups()
            return toggled && cleared && gonePop.titleOfSelectedItem == "Display not connected" && stored[1].screen == "GONE" && stored[1].desktops == [1, 2] && stored[0].screen == nil
        })
        check("groups: ▲▼ order is saved, Revert restores the loaded list, closing with changes asks", {
            var l = Layouts()
            for (id, n) in [("1", "One"), ("2", "Two"), ("3", "Three")] { l.setGroup(WindowGroup(id: id, name: n, members: [termMember])) }
            try layoutStore().save(l)
            let g = groupsWindow()
            g.move(0, by: 1); g.move(2, by: 1)
            let moved = g.draft.map(\.name) == ["Two", "One", "Three"]
            g.save()
            let saved = try loadGroups().map(\.name) == ["Two", "One", "Three"]
            g.delete(0); g.revertTapped()
            let reverted = g.draft.map(\.name) == ["Two", "One", "Three"] && !g.dirty
            var asked = 0; g.confirmDiscard = { asked += 1; return false }
            g.delete(1)
            let refused = !g.windowShouldClose(g.window) && asked == 1
            g.confirmDiscard = { asked += 1; return true }
            let discarded = g.windowShouldClose(g.window) && asked == 2 && !g.dirty
            return moved && saved && reverted && refused && discarded
        })
        check("groups: Capture works with injected windows, is disabled off-desktop, and refuses an empty capture", {
            var l = Layouts()
            l.setGroup(WindowGroup(id: "c", name: "C", members: [termMember, logMember], screen: "G-A", desktops: [2]))
            l.setGroup(WindowGroup(id: "d", name: "D", members: [ZoneMember(bundleID: "no.such.app")], screen: "G-A", desktops: [2]))
            try layoutStore().save(l)
            groupsDesktop = 1
            let g = groupsWindow()
            let off = g.captureProblem(g.draft[0]) != nil
            groupsDesktop = 2
            g.setMode(0, saved: true)
            let pending = g.draft[0].mode == .tiled
            g.capture(0)
            guard case .saved(let positions) = g.draft[0].mode else { return false }
            g.setMode(1, saved: true); g.capture(1)
            let empty = g.draft[1].mode == .tiled && g.status.stringValue.contains("No window of this group is open on Studio display")
            g.setMode(0, saved: false)
            return off && pending && positions.count == 2 && empty && g.draft[0].mode == .tiled
        })
        check("groups: deleting every group leaves schema 2 with no groups key", {
            var l = Layouts(); l.setGroup(WindowGroup(id: "z", name: "Z", members: [termMember])); try layoutStore().save(l)
            let g = groupsWindow(); g.delete(0); g.save()
            let text = String(decoding: try Data(contentsOf: layoutStore().file), as: UTF8.self)
            return !text.contains("\"groups\"") && text.contains("\"schema\" : 2")
        })
        check("groups: a groups save keeps the snapshot, rules and settings; a layout save keeps the groups", {
            var l = Layouts()
            l.set(remember([w], on: screen), setup: setup, desktop: 1, screen: screen.uuid)
            l.setRule(AppRule(bundleID: w.bundleID, desktop: 1, screen: screen.uuid, area: AppRule.full))
            l.setGroup(WindowGroup(id: "k", name: "K", members: [termMember]))
            try layoutStore().save(l)
            let g = groupsWindow(); g.rename(0, "Kept"); g.save()
            let after = try layoutStore().load()
            let keptBy = after.groups.first?.name == "Kept" && after.rules.contains { $0.bundleID == w.bundleID } && after.arrangement(setup: setup, desktop: 1, screen: screen.uuid) != nil
            editor.pick(); editor.ruleEdits[w.bundleID] = AppRule(bundleID: w.bundleID, desktop: 1, screen: screen.uuid, area: AppRule.full); editor.save()
            let still = try loadGroups().first?.name == "Kept"
            return keptBy && still
        })
        check("groups: an unreadable layout file disables Save and is not written", {
            let corrupt = Data("broken".utf8); try corrupt.write(to: layoutStore().file)
            let g = groupsWindow(); g.addGroup(openMembers: false); g.save()
            let unchanged = try Data(contentsOf: layoutStore().file) == corrupt
            return g.readFailed && !g.saveButton.isEnabled && unchanged
        })
        check("shots: groups-list (light, dark), groups-members, groups-refused, editor-header", {
            try? FileManager.default.removeItem(at: layoutStore().file)
            var l = Layouts()
            l.setGroup(WindowGroup(id: "u", name: "Reading", members: [ZoneMember(bundleID: "com.apple.Safari")]))
            l.setGroup(WindowGroup(id: "t", name: "Work", members: [termMember, logMember], screen: "G-A", desktops: [1, 3]))
            l.setGroup(WindowGroup(id: "s", name: "Review", members: [termMember], screen: "GONE", desktops: [2],
                                   mode: .saved([GroupPosition(matcher: Matcher(bundleID: "com.apple.Terminal"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1))])))
            try layoutStore().save(l)
            groupsDesktop = 1
            let g = groupsWindow(); g.window.setContentSize(NSSize(width: 1100, height: 300))
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                g.window.appearance = NSAppearance(named: appearance); g.window.contentView?.layoutSubtreeIfNeeded()
                try shot(g.window, "groups-list-\(mode)")
            }
            g.window.appearance = NSAppearance(named: .aqua)
            g.rename(0, "work "); g.window.contentView?.layoutSubtreeIfNeeded()
            try shot(g.window, "groups-refused")
            g.window.appearance = NSAppearance(named: .darkAqua); try shot(editor.window, "editor-header-dark"); editor.window.appearance = nil
            try shot(editor.window, "editor-header")
            let members = g.membersView(1); let host = NSWindow(contentRect: NSRect(origin: .zero, size: members.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            host.contentView = members; host.contentView?.layoutSubtreeIfNeeded()
            try shot(host, "groups-members")
            return true
        })
        editor.window.close()
    } catch { print("FAIL UI setup: \(error)"); failed += 1 }
    print("UI: \(passed) passed / \(failed) failed")
    return failed == 0 ? 0 : 1
}
