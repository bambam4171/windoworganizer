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
            editor.sortSwitch.state = .on; editor.sortToggled()
            guard editor.unsaved == ["sort setting"] else { return false }
            editor.applyAndSave()
            let after = try layoutStore().load()
            try layoutStore().save(before)
            editor.sortSwitch.state = .off; editor.pick()
            return after.rules == seeded.rules && !after.rules.isEmpty
                && after.arrangement(setup: setup, desktop: 1, screen: screen.uuid) == seeded.arrangement(setup: setup, desktop: 1, screen: screen.uuid)
                && after.arrangeSettings(desktop: 1, screen: screen.uuid).sortsByName
        })
        check("Sort by name persists for this screen and desktop only", {
            let before = try layoutStore().load()
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.accessProvider = { true }; editor.pick()
            guard editor.sortSwitch.state == .off, !editor.unsaved.contains("sort setting") else { return false }
            editor.sortSwitch.state = .on; editor.sortToggled()
            guard editor.unsaved.contains("sort setting") else { return false }
            editor.applyAndSave()
            let saved = try layoutStore().load()
            let reloaded = editor.loadedSort && !editor.unsaved.contains("sort setting")
            let other = saved.arrangeSettings(desktop: 2, screen: screen.uuid).sortsByName
            let here = saved.arrangeSettings(desktop: 1, screen: screen.uuid).sortsByName
            visibleDesktop = 2; editor.desktopPopUp.selectItem(at: 1); editor.pick()
            let otherOff = editor.sortSwitch.state == .off
            visibleDesktop = 1; editor.desktopPopUp.selectItem(at: 0); editor.pick()
            let backOn = editor.sortSwitch.state == .on
            editor.sortSwitch.state = .off; editor.applyAndSave()
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
            editor.sortSwitch.state = .off; editor.stagePreset(button)
            let plain = editor.manualDraft?.map(\.windowID) == [1, 2, 3, 4] && !editor.result.stringValue.contains("sorted by name")
            editor.sortSwitch.state = .on; editor.stagePreset(button)
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
            editor.sortSwitch.state = .off; editor.stagePreset(button)
            guard try shoot("before-") else { return false }
            editor.sortSwitch.state = .on; editor.stagePreset(button)
            guard try shoot("") else { return false }
            editor.window.appearance = nil
            editor.sortSwitch.state = .off; editor.resetDraft()
            editor.snapshotProvider = { (ListReport(trusted: true, desktop: nil, screens: [screen], windows: [w]), Listing()) }
            return plain && ordered && reading
        })
        check("corrupt state disables Save and remains unchanged", {
            let corrupt = Data("broken".utf8); try corrupt.write(to: layoutStore().file); editor.pick(); editor.save()
            let after = try Data(contentsOf: layoutStore().file)
            return editor.readFailed && !editor.saveButton.isEnabled && after == corrupt
        })
        editor.window.close()
    } catch { print("FAIL UI setup: \(error)"); failed += 1 }
    print("UI: \(passed) passed / \(failed) failed")
    return failed == 0 ? 0 : 1
}
