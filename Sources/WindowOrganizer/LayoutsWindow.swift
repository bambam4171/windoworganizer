import AppKit
import WindowOrganizerCore

extension WorkspaceContext {
    @MainActor static func live() -> WorkspaceContext {
        let screens = currentScreens()
        let displays = SkyLight.displaySpaces(mainUUID: screens.first?.uuid, screenUUIDs: screens.map(\.uuid))
        return WorkspaceContext(screens: screens,
            counts: Dictionary(displays.map { ($0.display, $0.spaces.count) }, uniquingKeysWith: max),
            desktops: displays.isEmpty ? Dictionary(uniqueKeysWithValues: screens.map { ($0.uuid, 0) }) : currentDesktops(displays),
            identities: displays)
    }
}

struct WorkspaceActionError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// The zone editor window (plan §4, slice S6b): pick a desktop and a screen, draw zones on the screen's picture,
// tick the apps that belong in the selected zone, Save. The rules live in the core's ZoneEditor.

@MainActor
final class LayoutsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static var shown: LayoutsWindow?

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let desktopPopUp = NSPopUpButton(), screenPopUp = NSPopUpButton()
    let mode = NSPopUpButton()
    let preview = ScreenPreview()
    let screenCards = NSStackView()
    let workflowStatus = NSTextField(labelWithString: "")
    let primaryButton = NSButton(title: "Save layout", target: nil, action: nil)
    let resetDraftButton = NSButton(title: "Reset", target: nil, action: nil)
    /// WINDOW-GAP S2: the settings of the picked screen and desktop. `loadedSettings` is what the file holds, `draftSettings`
    /// what the controls say; an untouched field stays nil so it keeps following the default. Pending until Apply & Save.
    /// SORT-MODE: "Sort automatically by name" (item 0) or "I arrange the order myself" (item 1, the default).
    let orderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    var orderIsAuto: Bool { orderPopUp.indexOfSelectedItem == 0 }
    func setOrderAuto(_ auto: Bool) { orderPopUp.selectItem(at: auto ? 0 : 1) }
    /// The staged preset's tiles, in the order the windows fill them: what a drop is tested against.
    var presetTiles: [(id: Int, frame: Frame)] = []
    let gapField = NSTextField(string: "0")
    let gapStepper = NSStepper()
    let keepLiveSwitch = NSButton(checkboxWithTitle: "Keep live", target: nil, action: nil)
    let pushBackSwitch = NSButton(checkboxWithTitle: "Push back when dropped on top", target: nil, action: nil)
    let resizeSwitch = NSButton(checkboxWithTitle: "Also when resizing", target: nil, action: nil)
    let liveHint = NSTextField(labelWithString: "Turn on Keep live to use these.")
    var loadedSettings = ArrangeSettings()
    var draftSettings = ArrangeSettings()
    var lastPreset: NSButton?
    var settingRows: [NSView] = []
    let advancedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    var manualDraft: [WindowInfo]?
    var draftContext: WorkspaceContext?
    var presetButtons: [NSButton] = []
    var cardsSignature = ""
    let previewMode = NSPopUpButton()
    let previewCaption = NSTextField(wrappingLabelWithString: "")
    let refreshPreviewButton = NSButton(title: "Refresh windows", target: nil, action: nil)
    let saveCurrentButton = NSButton(title: "Save current window arrangement", target: nil, action: nil)
    var liveWindows: [WindowInfo] = []
    var previewMessage = ""
    var observedContext: WorkspaceContext?
    var previewContext: WorkspaceContext?
    var accessProvider: () -> Bool = { Permission.trusted }
    var lastPreviewTime = Date.distantPast

    let workspaceLabel = NSTextField(wrappingLabelWithString: "")
    let savedLabel = NSTextField(wrappingLabelWithString: "")
    let captureButton = NSButton(title: "Capture current positions", target: nil, action: nil)
    let arrangeButton = NSButton(title: "Arrange automatically now", target: nil, action: nil)
    let restoreButton = NSButton(title: "Restore saved arrangement", target: nil, action: nil)
    let visibleButton = NSButton(title: "Use visible desktop", target: nil, action: nil)
    let permissionButton = NSButton(title: "Enable window access…", target: nil, action: nil)
    var capturedDraft = false
    var contextProvider: () -> WorkspaceContext = { WorkspaceContext.live() }
    var snapshotProvider: () -> (ListReport, Listing) = { snapshot() }
    var launchProviders: WorkspaceProviders = .live
    var applyProvider: (Plan, Listing, WorkspaceContext) -> ApplyResult = { RestoreSession.shared.apply($0, listing: $1, context: $2) }
    var contextTimer: Timer?
    var loadedSetup = ""

    let hint = NSTextField(wrappingLabelWithString: "")
    let snapshotRows = TopStackView()
    var snapshotHeight: NSLayoutConstraint!
    let snapshotScroll = NSScrollView()
    var middle: NSStackView!
    var placements: [Placement] = []
    var loadedPlacements: [Placement] = []
    var loadedZones: [Zone] = []
    var loadedMode = 0
    var selectedScreen = 0, selectedDesktop = 0
    var readFailed = false
    let saveButton = NSButton(title: "Save changes", target: nil, action: nil)
    let preset = NSPopUpButton()
    let warning = NSTextField(labelWithString: "")
    let canvas = ZoneCanvas()
    let members = TopStackView()
    let deleteButton = NSButton(title: "Delete zone", target: nil, action: nil)
    var screens: [ScreenInfo] = []
    var spaces: [String: Int] = [:]
    var layouts = Layouts()
    var editor: ZoneEditor?
    /// App rules changed since the last load: app → its new rule, or nil when removed. Written by Save.
    var ruleEdits: [String: AppRule?] = [:]
    let rulesList = NSStackView()
    let ruleApp = NSPopUpButton(), ruleArea = NSPopUpButton()
    static let areas: [(String, UnitRect)] = [("Full screen area", AppRule.full),
                                              ("Left half", UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                                              ("Right half", UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
                                              ("Top half", UnitRect(x: 0, y: 0, width: 1, height: 0.5)),
                                              ("Bottom half", UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))]
    /// The line under the buttons: saved, or why not.
    let result = NSTextField(labelWithString: "")

    static func show() {
        let w = shown ?? LayoutsWindow()
        shown = w
        if !w.window.isVisible && !w.dirty { w.reload() }
        w.workspaceDidChange()
        NSApp.activate(ignoringOtherApps: true)
        w.window.center()
        w.window.makeKeyAndOrderFront(nil)
    }

    override init() {
        super.init()
        snapshotProvider = { [weak self] in snapshot(screenUUID: self?.screen?.uuid) }
        window.title = "Window Organizer"
        window.minSize = NSSize(width: 880, height: 730)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        saveCurrentButton.target = self; saveCurrentButton.action = #selector(saveCurrentArrangement)
        refreshPreviewButton.target = self; refreshPreviewButton.action = #selector(refreshCurrentWindows)
        previewMode.addItems(withTitles: ["Current windows", "Saved arrangement"])
        previewMode.target = self; previewMode.action = #selector(previewModePicked)
        previewCaption.textColor = .secondaryLabelColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        captureButton.target = self; captureButton.action = #selector(captureCurrent)
        arrangeButton.target = self; arrangeButton.action = #selector(arrangeCurrent)
        restoreButton.target = self; restoreButton.action = #selector(restoreCurrent)
        visibleButton.target = self; visibleButton.action = #selector(useVisibleDesktop)
        permissionButton.target = self; permissionButton.action = #selector(openPermissions)
        workspaceLabel.font = .boldSystemFont(ofSize: 14)
        savedLabel.textColor = .secondaryLabelColor
        contextTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.workspaceDidChange() }
        }
        desktopPopUp.target = self; desktopPopUp.action = #selector(desktopPicked)
        screenPopUp.target = self; screenPopUp.action = #selector(screenPicked)
        deleteButton.target = self; deleteButton.action = #selector(deleteZone)
        saveButton.target = self; saveButton.action = #selector(save); saveButton.keyEquivalent = "\r"
        mode.addItems(withTitles: ["My window positions", "Drawn zones", "Automatic grid"])
        mode.target = self; mode.action = #selector(modePicked)
        preset.addItems(withTitles: ["Add a preset…", "Full usable area", "Left half", "Right half", "Top half", "Bottom half"])
        preset.target = self; preset.action = #selector(addPreset)
        let revert = NSButton(title: "Revert", target: self, action: #selector(revert))
        canvas.changed = { [weak self] in self?.refresh() }
        members.orientation = .vertical
        members.alignment = .leading
        warning.textColor = .systemOrange
        result.textColor = .secondaryLabelColor

        let top = NSStackView(views: [NSTextField(labelWithString: "Desktop"), desktopPopUp,
                                      NSTextField(labelWithString: "Screen"), screenPopUp])
        let side = NSStackView(views: [NSTextField(labelWithString: "Apps in the selected zone"), members])
        side.orientation = .vertical
        side.alignment = .leading
        side.removeArrangedSubview(members); members.removeFromSuperview()
        let memberScroll = NSScrollView(); memberScroll.hasVerticalScroller = true; memberScroll.borderType = .noBorder
        memberScroll.documentView = members
        members.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([members.topAnchor.constraint(equalTo: memberScroll.contentView.topAnchor),
            members.leadingAnchor.constraint(equalTo: memberScroll.contentView.leadingAnchor),
            members.widthAnchor.constraint(equalTo: memberScroll.contentView.widthAnchor)])
        side.addArrangedSubview(memberScroll)
        NSLayoutConstraint.activate([memberScroll.widthAnchor.constraint(equalToConstant: 250), memberScroll.heightAnchor.constraint(equalToConstant: 245)])
        middle = NSStackView(views: [canvas, side])
        middle.alignment = .top
        let buttons = NSStackView(views: [deleteButton, preset, NSView(), revert, saveButton])
        snapshotRows.orientation = .vertical; snapshotRows.alignment = .leading; snapshotRows.spacing = 10
        snapshotScroll.hasVerticalScroller = true; snapshotScroll.documentView = snapshotRows
        snapshotRows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([snapshotRows.topAnchor.constraint(equalTo: snapshotScroll.contentView.topAnchor),
            snapshotRows.leadingAnchor.constraint(equalTo: snapshotScroll.contentView.leadingAnchor),
            snapshotRows.widthAnchor.constraint(equalTo: snapshotScroll.contentView.widthAnchor),
            snapshotScroll.widthAnchor.constraint(equalToConstant: 750), snapshotScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)])
        snapshotHeight = snapshotScroll.heightAnchor.constraint(equalToConstant: 50); snapshotHeight.isActive = true
        rulesList.orientation = .vertical
        rulesList.alignment = .leading
        ruleArea.addItems(withTitles: Self.areas.map(\.0))
        let addRule = NSStackView(views: [NSTextField(labelWithString: "Always put"), ruleApp, NSTextField(labelWithString: "in"), ruleArea,
                                          NSButton(title: "Add rule", target: self, action: #selector(addRule))])
        let rulesTitle = NSTextField(labelWithString: "App rules · apply while this display shows the selected desktop")
        rulesTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        hint.textColor = .secondaryLabelColor
        let all = NSStackView(views: [top, NSStackView(views: [NSTextField(labelWithString: "Arrangement"), mode]),
            NSStackView(views: [captureButton, arrangeButton]), hint, warning, middle, snapshotScroll, rulesTitle, rulesList, addRule, buttons])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 14
        all.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        canvas.setAccessibilityElement(true); canvas.setAccessibilityRole(.group); canvas.setAccessibilityLabel("Zone editor. Drag to draw zones; select a zone to edit its app members.")
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([canvas.widthAnchor.constraint(equalToConstant: 480),
                                     canvas.heightAnchor.constraint(equalToConstant: 270),
                                     side.widthAnchor.constraint(equalToConstant: 250),
                                     buttons.widthAnchor.constraint(equalTo: middle.widthAnchor)])
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let doc = TopDocumentView(); scroll.documentView = doc; doc.addSubview(all)
        doc.translatesAutoresizingMaskIntoConstraints = false; all.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            all.leadingAnchor.constraint(equalTo: doc.leadingAnchor), all.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            all.topAnchor.constraint(equalTo: doc.topAnchor), all.bottomAnchor.constraint(equalTo: doc.bottomAnchor)])
        advancedWindow.title = "Advanced layouts"
        advancedWindow.isReleasedWhenClosed = false
        advancedWindow.contentView = scroll
        buildWorkflow()
        window.setContentSize(NSSize(width: 1040, height: 800))
    }

    func buildWorkflow() {
        func label(_ title: String, size: CGFloat = 15, weight: NSFont.Weight = .semibold) -> NSTextField {
            let text = NSTextField(labelWithString: title); text.font = .systemFont(ofSize: size, weight: weight); return text
        }
        func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.spacing = 10; stack.alignment = .centerY; return stack }
        let title = label("Make room for your ideas.", size: 28)
        let settings = NSButton(title: "Settings", target: self, action: #selector(showSettings))
        let advanced = NSButton(title: "Advanced…", target: self, action: #selector(showAdvanced))
        let header = row([title, NSView(), advanced, settings])
        let stepOne = label("1  Choose your screen")
        screenCards.orientation = .horizontal; screenCards.spacing = 12
        let contextTip = label("Switch desktops in Mission Control. This app follows you.", size: 12, weight: .regular)
        contextTip.textColor = .secondaryLabelColor
        let presets = ["Grid", "Columns", "Rows"].enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(stagePreset(_:))); button.tag = index
            button.image = NSImage(systemSymbolName: ["square.grid.2x2", "rectangle.split.3x1", "rectangle.split.1x3"][index], accessibilityDescription: title)
            button.imagePosition = .imageLeading; button.bezelStyle = .rounded; return button
        }
        presetButtons = presets
        previewMode.removeAllItems(); previewMode.addItems(withTitles: ["Live canvas", "Saved layout"])
        refreshPreviewButton.title = "Refresh"
        refreshPreviewButton.toolTip = "Reload live window positions and clear the unsaved preview"
        resetDraftButton.target = self; resetDraftButton.action = #selector(resetDraft)
        let arrangeHeader = row([label("2  Arrange your windows"), NSView(), previewMode, refreshPreviewButton])
        visibleButton.title = "Use current desktop"
        orderPopUp.addItems(withTitles: ["Sort automatically by name", "I arrange the order myself"])
        orderPopUp.target = self; orderPopUp.action = #selector(sortToggled)
        orderPopUp.toolTip = "Grid, Columns, Rows and automatic tiling on this screen and desktop. Saved windows, zones and app rules keep their place."
        gapStepper.minValue = 0; gapStepper.maxValue = Double(ArrangeSettings.maxGap); gapStepper.increment = 1; gapStepper.valueWraps = false
        gapStepper.target = self; gapStepper.action = #selector(gapStepped)
        gapField.target = self; gapField.action = #selector(gapTyped); gapField.alignment = .right
        gapField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        for control in [keepLiveSwitch, pushBackSwitch, resizeSwitch] { control.target = self; control.action = #selector(sortToggled) }
        liveHint.font = .systemFont(ofSize: 12); liveHint.textColor = .secondaryLabelColor
        let scope = "For the selected screen and desktop only."
        for control in [gapField, gapStepper, keepLiveSwitch, pushBackSwitch, resizeSwitch] { control.toolTip = scope }
        gapField.toolTip = "Points between neighbouring windows (0 to \(ArrangeSettings.maxGap)). " + scope
        let toolbar = row(presets + [resetDraftButton, NSView(), visibleButton, permissionButton])
        let gapLine = row([label("Gap", size: 13, weight: .regular), gapField, gapStepper, label("pt", size: 13, weight: .regular), NSView(), label("Order", size: 13, weight: .regular), orderPopUp])
        let liveLine = row([keepLiveSwitch, pushBackSwitch, resizeSwitch, liveHint])
        settingRows = [gapLine, liveLine]
        preview.changed = { [weak self] id, frame in self?.stageWindow(id, frame: frame) }
        preview.dropped = { [weak self] id, point in self?.dropped(id, at: point) }
        preview.toolTip = "Drag a window card to move it. Drag its bottom-right corner to resize. Changes apply when you choose Apply & Save."
        primaryButton.target = self; primaryButton.action = #selector(applyAndSave)
        primaryButton.bezelStyle = .rounded; primaryButton.bezelColor = .controlAccentColor
        primaryButton.font = .systemFont(ofSize: 15, weight: .semibold); primaryButton.keyEquivalent = "\r"
        primaryButton.controlSize = .large
        restoreButton.title = "Restore saved layout"
        restoreButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil); restoreButton.imagePosition = .imageLeading
        let footer = row([label("3  Keep your layout"), workflowStatus, NSView(), restoreButton, primaryButton])
        result.maximumNumberOfLines = 2; result.lineBreakMode = .byTruncatingTail
        result.font = .systemFont(ofSize: 12); result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewCaption.font = .systemFont(ofSize: 12)
        let root = NSStackView(views: [header, stepOne, screenCards, contextTip, arrangeHeader, toolbar, gapLine, liveLine, preview, previewCaption, footer, result])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 15
        root.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(root); window.contentView = content
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor), root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        for view in [header, screenCards, arrangeHeader, toolbar, preview, footer, previewCaption, result] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        }
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    func rebuildScreenCards() {
        let context = contextProvider()
        let signature = screens.map { "\($0.uuid):\(context.desktops[$0.uuid] ?? 0)" }.joined(separator: "|") + ":\(screenPopUp.indexOfSelectedItem):\(desktopNumber)"
        guard signature != cardsSignature else { return }
        cardsSignature = signature
        screenCards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, display) in screens.enumerated() {
            let chosen = index == screenPopUp.indexOfSelectedItem
            let desktop = chosen ? desktopNumber : context.desktops[display.uuid] ?? 0
            let button = NSButton(title: "\(display.name)\n\(desktop > 0 ? "Desktop \(desktop)" : "Desktop unknown")", target: self, action: #selector(chooseScreen(_:)))
            button.tag = index; button.bezelStyle = .regularSquare; button.setButtonType(.pushOnPushOff); button.state = chosen ? .on : .off
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Screen"); button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: chosen ? .semibold : .regular)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true; button.heightAnchor.constraint(equalToConstant: 54).isActive = true
            screenCards.addArrangedSubview(button)
        }
    }
    @objc func chooseScreen(_ button: NSButton) { screenPopUp.selectItem(at: button.tag); screenPicked() }
    @objc func showSettings() { SettingsWindow.show() }
    @objc func showAdvanced() { advancedWindow.center(); advancedWindow.makeKeyAndOrderFront(nil) }
    func stageWindow(_ id: Int, frame: Frame) {
        guard preview.editable, let context = previewContext, context == contextProvider() else { return }
        var draft = manualDraft ?? liveWindows
        guard let index = draft.firstIndex(where: { $0.windowID == id }) else { return }
        draft[index].frame = frame
        let active = draft.remove(at: index); draft.insert(active, at: 0)
        manualDraft = draft; draftContext = context; refreshWorkspaceStatus()
        result.stringValue = "Preview your changes, then choose Apply & Save."
    }
    @objc func stagePreset(_ button: NSButton) {
        guard previewMode.indexOfSelectedItem == 0, !readFailed else { return }
        do {
            // A preset replaces the whole preview, so enumerate now rather than reusing an older draft.
            let (selection, report, listing, context) = try workspaceSnapshot(allowPartial: true)
            guard let screen else { throw WorkspaceError.screenDisconnected }
            let found = report.windows.filter { $0.screenUUID == selection.screenUUID }
            guard !found.isEmpty else { throw WorkspaceError.noWindows }
            let sorted = draftSettings.sortsByName
            let current = arrangeOrder(found, settings: draftSettings)
            let (frames, noRoom) = applyGap(presetFrames([.grid, .columns, .rows][min(max(button.tag, 0), 2)], count: current.count, in: screen.visibleFrame),
                                            gap: draftSettings.gapPoints)
            lastPreset = button
            presetTiles = zip(current, frames).map { ($0.windowID, $1) }
            var draft = current
            for i in draft.indices { draft[i].frame = frames[i] }
            liveWindows = current; previewContext = context; previewMessage = listing.warnings.joined(separator: " ")
            manualDraft = draft; draftContext = context; refreshWorkspaceStatus()
            let gapNote = draftSettings.gapPoints == 0 ? "" : noRoom ? " · gap skipped: no room" : " · gap \(draftSettings.gapPoints) pt"
            previewCaption.stringValue = "\(draft.count) windows in preview · Drag to move. Pull a bottom-right corner to resize." + (sorted ? "" : " Drag a window onto another tile to swap them.")
            result.stringValue = "\(button.title) preview · \(draft.count) windows\(sorted ? " · sorted by name" : " · your order")\(gapNote) · Adjust, then Apply & Save."
        } catch { result.stringValue = "Preview unavailable: \(error)" }
    }
    /// Every settings control ends here: the controls become `draftSettings`, a staged preset redraws at once.
    @objc func sortToggled() {
        let gap = min(max(Int(gapField.stringValue.trimmingCharacters(in: .whitespaces)) ?? loadedSettings.gapPoints, 0), ArrangeSettings.maxGap)
        var next = draftSettings
        next.gap = gap == 0 ? nil : gap
        next.sortByName = orderIsAuto ? true : nil
        let live = keepLiveSwitch.state == .on
        // Only a touched Keep live is stored; one that agrees with the default for this gap stays nil.
        if live != draftSettings.isLive || draftSettings.keepLive != nil { next.keepLive = live == (gap > 0) ? nil : live }
        next.pushBackOnTop = pushBackSwitch.state == .on ? true : nil
        next.correctResize = resizeSwitch.state == .on ? nil : false
        draftSettings = next
        showControls()
        if manualDraft != nil, let lastPreset { stagePreset(lastPreset) } else { refreshWorkspaceStatus() }
    }
    /// A drop that ends inside another window's tile swaps the two tiles, in "I arrange the order myself" mode only.
    /// `point` is in screen coordinates. Tiles are the staged preset's frames, never the windows' frames or the draft order.
    func dropped(_ id: Int, at point: CGPoint) {
        guard lastPreset != nil, manualDraft != nil, let from = presetTiles.firstIndex(where: { $0.id == id }),
              let to = presetTiles.firstIndex(where: { $0.id != id && Self.contains($0.frame, point) }) else { return }
        guard !draftSettings.sortsByName else {
            result.stringValue = "Order is by app name. Choose “I arrange the order myself” to swap tiles."; return
        }
        var ids = presetTiles.map(\.id)
        ids.swapAt(from, to)
        let byID = Dictionary(liveWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        draftSettings.manualOrder = manualOrder(for: ids.compactMap { byID[$0] })
        if let lastPreset { stagePreset(lastPreset) }
        result.stringValue = "Swapped two tiles · " + result.stringValue
    }
    static func contains(_ f: Frame, _ p: CGPoint) -> Bool { p.x >= f.x && p.x < f.x + f.width && p.y >= f.y && p.y < f.y + f.height }
    @objc func gapStepped() { gapField.integerValue = gapStepper.integerValue; sortToggled() }
    @objc func gapTyped() { sortToggled() }
    /// The controls show `draftSettings`; the two lower switches only work with Keep live.
    func showControls() {
        let d = draftSettings
        gapField.integerValue = d.gapPoints; gapStepper.integerValue = d.gapPoints
        setOrderAuto(d.sortsByName)
        keepLiveSwitch.state = d.isLive ? .on : .off
        pushBackSwitch.state = d.pushesBackOnTop ? .on : .off
        resizeSwitch.state = d.correctsResize ? .on : .off
        pushBackSwitch.isEnabled = d.isLive; resizeSwitch.isEnabled = d.isLive; liveHint.isHidden = d.isLive
    }
    /// " · gap 8 pt · sorted by name · keep live on" for the result line.
    var settingsSummary: String {
        let d = loadedSettings
        return (d.gapPoints > 0 ? " · gap \(d.gapPoints) pt" : "") + (d.sortsByName ? " · sorted by name" : d.manualOrder != nil ? " · your order" : "") + (d.isLive ? " · keep live on" : "")
    }
    @objc func refreshCurrentWindows() {
        do {
            let (selection, report, listing, context) = try workspaceSnapshot(allowPartial: true)
            manualDraft = nil; draftContext = nil; preview.selectedID = nil
            previewMode.selectItem(at: 0)
            liveWindows = report.windows.filter { $0.screenUUID == selection.screenUUID }
            previewContext = context; lastPreviewTime = Date()
            previewMessage = listing.warnings.isEmpty ? (liveWindows.isEmpty ? "No standard windows are visible on this screen." : "") : "Some windows unavailable: " + listing.warnings.joined(separator: " ")
            refreshWorkspaceStatus()
            result.stringValue = "Refreshed · \(liveWindows.count) windows · Live positions reloaded."
        } catch { result.stringValue = "Refresh unavailable: \(error)" }
    }
    @objc func resetDraft() { manualDraft = nil; draftContext = nil; lastPreset = nil; result.stringValue = ""; refreshLivePreview(); refreshWorkspaceStatus() }
    @objc func applyAndSave() {
        window.makeFirstResponder(nil)   // a gap still being typed commits before Apply & Save reads it (Zeus, S2 note 1)
        // A settings-only change writes the settings alone: capturing the live windows would overwrite the layout and clear the rules (Z-380).
        if manualDraft == nil, !unsaved.isEmpty, unsaved.allSatisfy({ $0 == "gap settings" || $0 == "window order" }) {
            save()
            if unsaved.isEmpty, let screen { result.stringValue = "✓ Settings saved · \(screen.name), \(desktopName)" + settingsSummary; startAfterSave() }
            refreshWorkspaceStatus(); return
        }
        guard let draft = manualDraft else {
            saveCurrentArrangement(); if !dirty { startAfterSave() }
            previewMode.selectItem(at: 0); updatePreview(); refreshWorkspaceStatus(); return
        }
        guard !advancedPending else {
            result.stringValue = "Not applied: Advanced has unsaved changes for this desktop. Save or discard them first."; return
        }
        do {
            let (selection, report, listing, context) = try workspaceSnapshot()
            guard context == draftContext, let screen else { throw WorkspaceActionError(message: "Your screen or desktop changed. Return to it or Reset the preview.") }
            let actual = report.windows.filter { $0.screenUUID == selection.screenUUID }
            guard Set(actual.map(\.windowID)) == Set(draft.map(\.windowID)) else { throw WorkspaceActionError(message: "The open windows changed. Reset to refresh them before arranging.") }
            let moves = draft.compactMap { target -> Move? in
                guard let source = actual.first(where: { $0.windowID == target.windowID }), source.frame != target.frame else { return nil }
                return Move(windowID: source.windowID, from: source.frame, to: target.frame, area: screen.visibleFrame)
            }
            let applied = applyProvider(Plan(moves: moves, skipped: [], unchanged: draft.count - moves.count), listing, context)
            guard applied.cancelled == 0 else { throw WorkspaceActionError(message: "The desktop changed while moving. Your preview is still here; try again.") }
            guard applied.failed == 0 else { throw WorkspaceActionError(message: "Some windows could not be moved. Your preview is still here; try again.") }
            let (_, after, _, afterContext) = try workspaceSnapshot()
            guard afterContext == context, Set(after.windows.filter { $0.screenUUID == selection.screenUUID }.map(\.windowID)) == Set(draft.map(\.windowID)) else { throw WorkspaceActionError(message: "The desktop changed before saving. Return and try again.") }
            let captured = try captureWorkspace(selection, windows: after.windows, screens: context.screens, desktops: context.desktops)
            // An explicit arrangement replaces conflicting rules only on this screen and desktop.
            try persist(desktop: selection.desktop, screen: selection.screenUUID, removingRulesFor: Set(draft.map(\.bundleID))) {
                $0.set(captured, setup: ScreenSetup(screens: context.screens), desktop: selection.desktop, screen: selection.screenUUID)
            }
            // Only what was written is cleared; Advanced has no pending edit here (guarded above).
            manualDraft = nil; draftContext = nil
            if case .snapshot(let ps) = captured.kind { placements = ps }
            loadedPlacements = placements; loadedMode = 0; mode.selectItem(at: 0)
            refreshSnapshotRows(); refresh()
            previewMode.selectItem(at: 0); updatePreview()
            assert(unsaved.isEmpty)
            defer { startAfterSave() }
            result.stringValue = "✓ Layout saved · \(screen.name), \(desktopName)" + settingsSummary + (applied.keptMinimum > 0 ? " · Some apps kept their minimum size." : "")
            refreshWorkspaceStatus()
        } catch { result.stringValue = "Not saved: \(error)" }
    }

    /// Screens and desktops as they are now; keeps the picked screen and desktop when they still exist.
    func reload() {
        let keepUUID = screen?.uuid
        let context = contextProvider()
        screens = context.screens; spaces = context.counts
        screenPopUp.removeAllItems()
        screenPopUp.addItems(withTitles: screens.map(\.name))
        screenPopUp.selectItem(at: screens.firstIndex { $0.uuid == keepUUID } ?? 0)
        fillDesktops(current: screen.flatMap { context.desktops[$0.uuid] })
        pick()
    }

    /// Desktop 1 … the screen's number of desktops (up to 16 when SkyLight does not say).
    func fillDesktops(current: Int?) {
        let keep = desktopPopUp.indexOfSelectedItem
        let count = screen.flatMap { spaces[$0.uuid] } ?? 0
        desktopPopUp.removeAllItems()
        if count == 0 { desktopPopUp.addItem(withTitle: "Desktop unknown (manual)") }
        else { desktopPopUp.addItems(withTitles: (1...count).map { "Desktop \($0)" }) }
        desktopPopUp.selectItem(at: current.map { $0 - 1 } ?? min(max(keep, 0), max(count - 1, 0)))
    }

    var screen: ScreenInfo? {
        let i = screenPopUp.indexOfSelectedItem
        return screens.indices.contains(i) ? screens[i] : nil
    }

    var desktopNumber: Int { screen.flatMap { spaces[$0.uuid] }.map { $0 > 0 ? desktopPopUp.indexOfSelectedItem + 1 : 0 } ?? 0 }
    /// An Advanced arrangement edit (mode, zones, snapshot rows or a capture) not yet written.
    var advancedPending: Bool { capturedDraft || mode.indexOfSelectedItem != loadedMode || (canvas.editor?.zones ?? []) != loadedZones || placements != loadedPlacements }
    /// Everything on this window not yet written to disk; the one source for the dirty flag and the result line.
    var unsaved: [String] {
        var u: [String] = []
        if manualDraft != nil { u.append("canvas preview") }
        if advancedPending { u.append("Advanced arrangement") }
        if !ruleEdits.isEmpty { u.append("app rules") }
        let a = draftSettings, b = loadedSettings
        if a.sortByName != b.sortByName || a.manualOrder != b.manualOrder { u.append("window order") }
        var rest = a; rest.sortByName = b.sortByName; rest.manualOrder = b.manualOrder
        if rest != b { u.append("gap settings") }
        return u
    }
    var dirty: Bool { !unsaved.isEmpty }
    var desktopName: String { desktopNumber == 0 ? "Desktop unknown (manual)" : "Desktop \(desktopNumber)" }
    var selection: WorkspaceSelection? { screen.map { WorkspaceSelection(screenUUID: $0.uuid, desktop: desktopNumber) } }

    func workspaceDidChange() {
        guard window.isVisible else { return }
        let context = contextProvider()
        if !dirty && context != observedContext {
            reload()
        } else { refreshWorkspaceStatus() }
        if manualDraft == nil && NSApp.isActive && accessProvider() && previewMode.indexOfSelectedItem == 0 && Date().timeIntervalSince(lastPreviewTime) >= 4 {
            refreshLivePreview()
        }
    }

    func refreshWorkspaceStatus() {
        let context = contextProvider()
        let visible = selection?.isVisible(desktops: context.desktops) == true && context.screens == screens
        let trusted = accessProvider()
        visibleButton.isHidden = visible
        workspaceLabel.stringValue = screen.map { "Editing \($0.name) · \(desktopName)" } ?? "No screen connected"
        if !visible { workspaceLabel.stringValue += " — switch to this desktop to capture or arrange" }
        else if desktopNumber == 0 { workspaceLabel.stringValue += " — desktop detection unavailable; this manual layout is shared" }
        else { workspaceLabel.stringValue += " — currently visible" }
        permissionButton.isHidden = trusted
        permissionButton.title = trusted ? "Window access enabled" : "Enable window access…"
        captureButton.isEnabled = trusted && visible && !readFailed
        arrangeButton.isEnabled = trusted && visible && !readFailed
        saveCurrentButton.isEnabled = trusted && visible && !readFailed
        refreshPreviewButton.isEnabled = trusted && visible
        if previewContext != context { liveWindows = []; previewContext = nil }
        updatePreview()
        let saved = screen.flatMap { layouts.arrangement(setup: ScreenSetup(screens: screens), desktop: desktopNumber, screen: $0.uuid) }
        restoreButton.isEnabled = trusted && visible && !readFailed && saved != nil
        switch saved?.kind {
        case .snapshot(let ps)?: savedLabel.stringValue = "Saved for this screen and desktop: \(ps.count) window positions"
        case .zones(let zs)?: savedLabel.stringValue = "Saved for this screen and desktop: \(zs.count) zones"
        case .autoTile?: savedLabel.stringValue = "Saved for this screen and desktop: automatic grid"
        case nil: savedLabel.stringValue = "No arrangement saved for this screen and desktop yet."
        }
        if !trusted { savedLabel.stringValue += " Enable window access to capture and arrange windows." }
        saveButton.title = "Save advanced changes"
        primaryButton.title = manualDraft == nil ? "Save layout" : "Apply & Save"
        primaryButton.isEnabled = trusted && visible && !readFailed && !(manualDraft ?? liveWindows).isEmpty
        resetDraftButton.isEnabled = manualDraft != nil
        presetButtons.forEach { $0.isEnabled = trusted && visible && !readFailed && previewMode.indexOfSelectedItem == 0 }
        workflowStatus.stringValue = !visible ? "Switch to \(desktopName) in Mission Control" : manualDraft != nil ? "Unsaved changes · ready to apply" : saved == nil ? "Create your first layout" : "Layout saved for this desktop"
        workflowStatus.textColor = manualDraft == nil ? .secondaryLabelColor : .systemOrange
        rebuildScreenCards()
    }

    @objc func openPermissions() { NSWorkspace.shared.open(Permission.settingsURL) }
    @objc func useVisibleDesktop() {
        guard allowDiscard() else { return }
        previewMode.selectItem(at: 0)
        reload()
        result.stringValue = "Using \(screen?.name ?? "screen") · \(desktopName). " + (accessProvider() ? "\(liveWindows.count) windows listed. \(previewMessage)" : "macOS is not granting this running copy window access yet. Refresh its existing permission in System Settings.")
    }

    /// Read windows between two context observations; never apply a list from a desktop transition.
    func workspaceSnapshot(allowPartial: Bool = false) throws -> (WorkspaceSelection, ListReport, Listing, WorkspaceContext) {
        guard let selection else { throw WorkspaceError.screenDisconnected }
        var providers = WorkspaceProviders.live
        providers.context = contextProvider; providers.snapshot = snapshotProvider
        let (report, listing, before) = try guardedSnapshot(providers, before: { before in
            guard before.screens == self.screens else { throw WorkspaceError.screenDisconnected }
            guard selection.isVisible(desktops: before.desktops) else { throw WorkspaceError.desktopNotVisible }
        }, after: { report, listing in
            guard report.trusted else { throw WorkspaceActionError(message: "Enable window access in Accessibility settings first.") }
            guard allowPartial || listing.warnings.isEmpty else { throw WorkspaceActionError(message: listing.warnings.joined(separator: " ")) }
        })
        return (selection, report, listing, before)
    }

    @objc func previewModePicked() {
        if previewMode.indexOfSelectedItem == 0 { refreshLivePreview() } else { updatePreview() }
    }

    @objc func refreshLivePreview() {
        lastPreviewTime = Date()
        do {
            let (_, report, listing, context) = try workspaceSnapshot(allowPartial: true)
            liveWindows = report.windows.filter { $0.screenUUID == screen?.uuid }
            previewContext = context
            previewMessage = listing.warnings.isEmpty ? (liveWindows.isEmpty ? "No standard windows are visible on this screen." : "") : "Some windows unavailable: " + listing.warnings.joined(separator: " ")
        } catch { liveWindows = []; previewContext = nil; previewMessage = String(describing: error) }
        refreshWorkspaceStatus()
    }

    func updatePreview() {
        preview.editable = accessProvider() && selection?.isVisible(desktops: contextProvider().desktops) == true && previewMode.indexOfSelectedItem == 0 && !readFailed
        preview.screen = screen
        let saved = screen.flatMap { layouts.arrangement(setup: ScreenSetup(screens: screens), desktop: desktopNumber, screen: $0.uuid) }
        let showSaved = previewMode.indexOfSelectedItem == 1
        if showSaved {
            switch saved?.kind {
            case .snapshot(let ps)?:
                preview.windows = ps.map { p in
                    let frame = p.screenUUID == screen?.uuid && p.visibleFrame == screen?.visibleFrame ? p.pixel : p.fraction.frame(in: screen!.visibleFrame)
                    return PreviewWindow(frame: frame, title: "\(appName(p.matcher.bundleID)) · \(p.matcher.seenTitle ?? "Window")", bundleID: p.matcher.bundleID)
                }
                preview.message = "No window positions saved yet."
            case .zones(let zones)?:
                preview.windows = zones.map { PreviewWindow(frame: $0.rect.frame(in: screen!.visibleFrame), title: $0.members.map { appName($0.bundleID) }.joined(separator: ", "), bundleID: $0.members.first?.bundleID ?? "zone") }
                preview.message = "No zones saved yet."
            case .autoTile?: preview.windows = []; preview.message = "Automatic grid saved. Cell sizes depend on the windows open when restored."
            case nil: preview.windows = []; preview.message = "No arrangement saved for this screen and desktop yet."
            }
            previewCaption.stringValue = "Your saved layout · Choose Restore to put open windows back here."
        } else {
            preview.windows = (manualDraft ?? liveWindows).map { PreviewWindow(frame: $0.frame, title: "\(appName($0.bundleID)) · \($0.title)", bundleID: $0.bundleID, windowID: $0.windowID) }
            preview.message = !accessProvider() ? "Enable window access to see your windows here." : previewMessage.isEmpty ? "Refresh windows to see their positions." : previewMessage
            previewCaption.stringValue = "\((manualDraft ?? liveWindows).count) windows\(manualDraft == nil ? "" : " in preview") · Drag to move. Pull a bottom-right corner to resize."
            if !liveWindows.isEmpty && !previewMessage.isEmpty { previewCaption.stringValue += " " + previewMessage }
        }
        preview.updateAccessibility()
    }

    @objc func saveCurrentArrangement() {
        window.makeFirstResponder(nil)
        guard !readFailed else { result.stringValue = "Not saved: repair the unreadable layout file first."; return }
        do {
            let (selection, report, _, context) = try workspaceSnapshot()
            let captured = try captureWorkspace(selection, windows: report.windows, screens: context.screens, desktops: context.desktops)
            if case .snapshot(let ps) = captured.kind { placements = ps }
            for rule in layouts.rules(desktop: selection.desktop, screen: selection.screenUUID) where report.windows.contains(where: { $0.bundleID == rule.bundleID && $0.screenUUID == selection.screenUUID }) { ruleEdits[rule.bundleID] = .some(nil) }
            mode.selectItem(at: 0); capturedDraft = true; refreshSnapshotRows()
            liveWindows = report.windows.filter { $0.screenUUID == selection.screenUUID }; previewContext = context
            save()
            if !dirty {
                result.stringValue = "✓ Saved \(placements.count) windows · \(screen?.name ?? "screen"), \(desktopName)"
                previewMode.selectItem(at: 1); updatePreview()
            }
        } catch { result.stringValue = "Not saved: \(error)" }
    }

    @objc func captureCurrent() {
        window.makeFirstResponder(nil)
        do {
            let (selection, report, _, context) = try workspaceSnapshot()
            let captured = try captureWorkspace(selection, windows: report.windows, screens: context.screens, desktops: context.desktops)
            if case .snapshot(let ps) = captured.kind { placements = ps }
            mode.selectItem(at: 0); capturedDraft = true; liveWindows = report.windows.filter { $0.screenUUID == selection.screenUUID }; previewContext = context; refreshSnapshotRows(); refresh()
            result.stringValue = "Captured \(placements.count) windows on \(screen?.name ?? "screen") · \(desktopName). Save to keep these positions."
        } catch { result.stringValue = "Not captured: \(error)" }
    }

    @objc func arrangeCurrent() {
        window.makeFirstResponder(nil)
        do {
            let (selection, report, listing, context) = try workspaceSnapshot()
            _ = try planAutomaticWorkspace(selection, windows: report.windows, screens: context.screens, desktops: context.desktops)
            var draft = try layoutStore().load()
            draft.set(ScreenArrangement(kind: .autoTile), setup: ScreenSetup(screens: context.screens), desktop: selection.desktop, screen: selection.screenUUID)
            guard let plan = try planWorkspace(draft, selection: selection, windows: report.windows, screens: context.screens, desktops: context.desktops) else { return }
            let applied = applyProvider(plan, listing, context)
            mode.selectItem(at: 2); capturedDraft = true; refresh(); refreshLivePreview()
            result.stringValue = ResultLine.restored(applied, shifted: shiftedApps(applied, in: report.windows), desktop: desktopNumber, at: clock()) + ". Save to keep this screen's automatic grid."
        } catch { result.stringValue = "Not arranged: \(error)" }
    }

    @objc func restoreCurrent() {
        guard allowDiscard() else { return }
        manualDraft = nil; draftContext = nil
        previewMode.selectItem(at: 0)
        do {
            let (selection, report, listing, context) = try workspaceSnapshot()
            let saved = try layoutStore().load()
            let plan = try planWorkspace(saved, selection: selection, windows: report.windows, screens: context.screens, desktops: context.desktops)
            let starting = startMissingApps(.restore, layouts: saved, report: report, desktops: context.desktops, scope: selection, launchProviders)
            guard let plan else {
                result.stringValue = starting.isEmpty ? "No saved arrangement for this screen and desktop."
                    : ResultLine.restored(ApplyResult(placed: 0, keptMinimum: 0, failed: 0, unchanged: 0, notOpen: 0), starting: starting, desktop: desktopNumber, at: clock())
                return
            }
            result.stringValue = { let applied = applyProvider(plan, listing, context)
                return ResultLine.restored(applied, starting: starting, shifted: shiftedApps(applied, in: report.windows), desktop: desktopNumber, at: clock()) }()
            refreshLivePreview()
        } catch { result.stringValue = "Not restored: \(error)" }
    }
    /// After a successful Apply & Save: starts the apps the saved layout needs (switch "Apply & Save"). The capture and canvas
    /// branches save exactly the open windows, so this is empty there; a zones layout with a member that is not running is not.
    func startAfterSave() {
        guard let (selection, report, _, context) = try? workspaceSnapshot(), let saved = try? layoutStore().load() else { return }
        let names = startMissingApps(.applySave, layouts: saved, report: report, desktops: context.desktops, scope: selection, launchProviders)
        if !names.isEmpty { result.stringValue += " · starting " + names.joined(separator: ", ") }
    }
    func allowDiscard() -> Bool {
        window.makeFirstResponder(nil)
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Discard unsaved layout changes?"
        alert.informativeText = "Save your changes before switching layouts or closing this window."
        alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allowDiscard() else { return false }; pick(); return true
    }
    @objc func screenPicked() {
        guard allowDiscard() else { screenPopUp.selectItem(at: selectedScreen); return }
        fillDesktops(current: screen.flatMap { contextProvider().desktops[$0.uuid] }); pick()
    }
    @objc func desktopPicked() {
        guard allowDiscard() else { desktopPopUp.selectItem(at: selectedDesktop); return }; pick()
    }
    @objc func revert() { guard allowDiscard() else { return }; pick() }
    @objc func modePicked() { refresh() }
    @objc func addPreset() {
        let index = preset.indexOfSelectedItem - 1; preset.selectItem(at: 0)
        guard Self.areas.indices.contains(index), canvas.editor != nil else { return }
        canvas.editor?.zones.append(Zone(rect: Self.areas[index].1, members: []))
        let selected = (canvas.editor?.zones.count ?? 1) - 1
        canvas.editor?.selected = selected; refresh()
    }

    /// Loads the picked screen's zones from disk; Revert does the same.
    @objc func pick() {
        observedContext = contextProvider()
        guard let screen else { editor = nil; canvas.editor = nil; refresh(); return }
        do { layouts = try layoutStore().load(); readFailed = false; result.stringValue = "" }
        catch { layouts = Layouts(); readFailed = true; result.stringValue = "Could not read the layouts: \(error)" }
        manualDraft = nil; draftContext = nil
        ruleEdits = [:]; capturedDraft = false; loadedSetup = ScreenSetup(screens: screens).key
        editor = ZoneEditor(layouts, setup: ScreenSetup(screens: screens),
                            desktop: desktopNumber, screen: screen.uuid)
        canvas.editor = editor
        loadedZones = editor?.zones ?? []; placements = []
        let kind = layouts.arrangement(setup: ScreenSetup(screens: screens), desktop: desktopNumber, screen: screen.uuid)?.kind
        switch kind {
        case .snapshot(let ps)?: placements = ps; loadedMode = 0
        case .zones?: loadedMode = 1
        case .autoTile?: loadedMode = 2
        case nil: loadedMode = 0
        }
        loadedPlacements = placements; mode.selectItem(at: loadedMode)
        loadedSettings = layouts.arrangeSettings(desktop: desktopNumber, screen: screen.uuid)
        draftSettings = loadedSettings; lastPreset = nil; showControls()
        selectedScreen = screenPopUp.indexOfSelectedItem; selectedDesktop = desktopPopUp.indexOfSelectedItem
        liveWindows = []; previewContext = nil
        refreshSnapshotRows()
        refresh()
        if accessProvider() { refreshLivePreview() }
    }

    @objc func deleteZone() { canvas.editor?.deleteSelected(); refresh() }

    /// The one write path: loads fresh (another Remember may have saved), applies the arrangement edit, applies the pending
    /// rule edits, drops rules the arrangement replaces on this screen and desktop, and saves once.
    func persist(desktop: Int, screen screenUUID: String, removingRulesFor apps: Set<String> = [], arrangement edit: (inout Layouts) -> Void) throws {
        let store = layoutStore()
        var fresh = try store.load()
        edit(&fresh)
        if draftSettings != loadedSettings { fresh.setArrangeSettings(draftSettings, desktop: desktop, screen: screenUUID) }
        for (app, rule) in ruleEdits { if let rule { fresh.setRule(rule) } else { fresh.removeRule(app) } }
        for rule in fresh.rules where rule.screen == screenUUID && rule.desktop == desktop && apps.contains(rule.bundleID) { fresh.removeRule(rule.bundleID) }
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.save(fresh)
        layouts = fresh
        ruleEdits = [:]
        loadedSettings = draftSettings
    }

    @objc func save() {
        window.makeFirstResponder(nil)
        guard let editor = canvas.editor, let screen, !readFailed else { return }
        guard ScreenSetup(screens: contextProvider().screens).key == loadedSetup else {
            result.stringValue = "Screen setup changed. Return to the original setup to save this draft."; return
        }
        guard manualDraft == nil else {
            result.stringValue = "Not saved: the canvas preview is not applied yet. Apply & Save it or Reset it first."; return
        }
        do {
            let setup = ScreenSetup(screens: screens)
            let writeArrangement = advancedPending
            try persist(desktop: desktopNumber, screen: screen.uuid) { fresh in
                guard writeArrangement else { return }
                switch self.mode.indexOfSelectedItem {
                case 1: editor.save(into: &fresh)
                case 2: fresh.set(ScreenArrangement(kind: .autoTile), setup: setup, desktop: self.desktopNumber, screen: screen.uuid)
                default: fresh.set(ScreenArrangement(kind: .snapshot(self.placements)), setup: setup, desktop: self.desktopNumber, screen: screen.uuid)
                }
            }
            capturedDraft = false; loadedZones = editor.zones; loadedPlacements = placements; loadedMode = mode.indexOfSelectedItem
            assert(unsaved.isEmpty)
            result.stringValue = "Saved \(screen.name) · \(desktopName). Switch to the next screen or desktop when ready."
            refresh()
        } catch {
            result.stringValue = "Not saved: \(error)"
        }
    }

    /// Redraws and rebuilds the member list for the selected zone: the running apps with windows, plus members not running.
    func refresh() {
        editor = canvas.editor
        refreshWorkspaceStatus()
        let zoneMode = mode.indexOfSelectedItem == 1
        middle.isHidden = !zoneMode; snapshotScroll.isHidden = mode.indexOfSelectedItem != 0
        preset.isHidden = !zoneMode; deleteButton.isHidden = !zoneMode
        saveButton.isEnabled = !readFailed && screen != nil && dirty
        mode.isEnabled = !readFailed
        hint.stringValue = zoneMode ? "Drag to draw. Drag a zone to move it; drag its lower-right corner to resize. Choose apps on the right."
            : mode.indexOfSelectedItem == 2 ? "Arrange automatically now previews a grid on this screen. Save to keep automatic tiling for this desktop."
            : "Move and resize windows on your actual screen, then Save current window arrangement. Their exact positions and sizes will be restored next time. Capture current positions lets you review a draft before saving."
        warning.stringValue = zoneMode ? editor?.warning ?? "" : ""
        warning.isHidden = warning.stringValue.isEmpty
        canvas.screen = screen
        canvas.needsDisplay = true
        refreshRules()
        members.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let e = editor, let i = e.selected else {
            deleteButton.isEnabled = false
            members.addArrangedSubview(NSTextField(labelWithString: "Draw a zone, or click one."))
            return
        }
        deleteButton.isEnabled = true
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        var ids = running.compactMap(\.bundleIdentifier)
        ids += e.zones[i].members.map(\.bundleID).filter { !ids.contains($0) }
        for id in Set(ids).sorted(by: { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }) {
            let box = NSButton(checkboxWithTitle: appName(id), target: self, action: #selector(toggle(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(id)
            box.state = e.zones[i].members.contains { $0.bundleID == id } ? .on : .off
            let pattern = NSTextField(string: e.zones[i].members.first { $0.bundleID == id }?.titlePattern ?? "")
            pattern.delegate = self
            pattern.placeholderString = "Any title"; pattern.toolTip = "Optional title filter; * matches any text"
            pattern.identifier = NSUserInterfaceItemIdentifier(id); pattern.target = self; pattern.action = #selector(zonePattern(_:))
            pattern.isEnabled = box.state == .on; pattern.widthAnchor.constraint(equalToConstant: 110).isActive = true
            var views: [NSView] = [box, pattern]
            if box.state == .on, !launchProviders.running().contains(id) {
                let note = NSTextField(labelWithString: memberHint(startsOnRestore: Preferences.startsMissing(.restore)))
                note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.identifier = NSUserInterfaceItemIdentifier("memberHint")
                note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 0; note.preferredMaxLayoutWidth = 230
                views.append(note)
            }
            let row = NSStackView(views: views); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
            members.addArrangedSubview(row)
        }
    }

    func memberHint(startsOnRestore: Bool) -> String {
        startsOnRestore ? "not running, started when you restore" : "not running, not started (Settings › Start missing apps)"
    }

    /// The rules as they will be saved, for the picked desktop and screen.
    var shownRules: [AppRule] {
        guard let screen else { return [] }
        var all = layouts
        for (app, rule) in ruleEdits { if let rule { all.setRule(rule) } else { all.removeRule(app) } }
        return all.rules(desktop: desktopNumber, screen: screen.uuid)
    }

    func refreshRules() {
        rulesList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rules = shownRules
        if rules.isEmpty { rulesList.addArrangedSubview(NSTextField(labelWithString: "No app rules here.")) }
        for rule in rules {
            let area = Self.areas.first { $0.1 == rule.area }?.0 ?? "custom area"
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeRule(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(rule.bundleID)
            rulesList.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "\(appName(rule.bundleID)) · \(area)"), remove]))
        }
        let keep = ruleApp.titleOfSelectedItem
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap(\.bundleIdentifier).filter { id in !rules.contains { $0.bundleID == id } }
        ruleApp.removeAllItems()
        for id in Set(apps).sorted(by: { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }) {
            ruleApp.addItem(withTitle: appName(id))
            ruleApp.lastItem?.representedObject = id
        }
        if let keep { ruleApp.selectItem(withTitle: keep) }
    }

    /// A rule for an app that already has one elsewhere moves it here (one rule per app).
    @objc func addRule() {
        guard let screen, let id = ruleApp.selectedItem?.representedObject as? String else { return }
        ruleEdits[id] = AppRule(bundleID: id, desktop: desktopNumber, screen: screen.uuid,
                                area: Self.areas[max(ruleArea.indexOfSelectedItem, 0)].1)
        refresh()
    }

    @objc func removeRule(_ button: NSButton) {
        guard let id = button.identifier?.rawValue else { return }
        ruleEdits[id] = .some(nil)
        refresh()
    }

    @objc func toggle(_ box: NSButton) {
        guard let id = box.identifier?.rawValue else { return }
        canvas.editor?.toggle(id)
        refresh()
    }

    func refreshSnapshotRows() {
        snapshotHeight.constant = min(270, max(50, CGFloat(placements.count) * 34))
        snapshotRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if placements.isEmpty { snapshotRows.addArrangedSubview(NSTextField(labelWithString: "Arrange your real windows as you like, then Save current window arrangement.")) }
        for (index, p) in placements.enumerated() {
            let label = NSTextField(labelWithString: "\(appName(p.matcher.bundleID)) · \(p.matcher.seenTitle ?? "Window")")
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: 440).isActive = true
            let field = NSTextField(string: p.matcher.titlePattern ?? "")
            field.delegate = self
            field.placeholderString = "Any title"; field.toolTip = "Optional text or * wildcard title filter"
            field.identifier = NSUserInterfaceItemIdentifier(String(index)); field.target = self; field.action = #selector(snapshotPattern(_:))
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            snapshotRows.addArrangedSubview(NSStackView(views: [label, field]))
        }
    }
    @objc func snapshotPattern(_ field: NSTextField) {
        guard let text = field.identifier?.rawValue, let index = Int(text), placements.indices.contains(index) else { return }
        placements[index].matcher.titlePattern = field.stringValue.isEmpty ? nil : field.stringValue; refresh()
    }
    @objc func zonePattern(_ field: NSTextField) {
        guard let id = field.identifier?.rawValue, let i = canvas.editor?.selected,
              let member = canvas.editor?.zones[i].members.firstIndex(where: { $0.bundleID == id }) else { return }
        canvas.editor?.zones[i].members[member].titlePattern = field.stringValue.isEmpty ? nil : field.stringValue; refresh()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        if Int(id) != nil { snapshotPattern(field) } else { zonePattern(field) }
    }

    func appName(_ id: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.deletingPathExtension().lastPathComponent }
        return id
    }
}

/// The screen scaled onto the canvas, zones on top. Drag on empty space draws, drag a zone moves it,
/// drag its bottom-right corner resizes it.
@MainActor
final class ZoneCanvas: NSView {
    var editor: ZoneEditor?
    var screen: ScreenInfo?
    var changed: () -> Void = {}
    private enum Drag { case draw(CGPoint), move(Int, UnitRect, CGPoint), resize(Int) }
    private var drag: Drag?
    private var rubber: CGRect?

    override var isFlipped: Bool { true }   // top-left origin, like the core

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.15, of: .black)?.setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard let e = editor else { return }
        for i in e.zones.indices {
            let r = e.canvasRect(i, canvas: bounds.size).insetBy(dx: 1, dy: 1)
            let selected = e.selected == i
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.systemGray.withAlphaComponent(0.3)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            (selected ? NSColor.controlAccentColor : NSColor.systemGray).setStroke()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).stroke()
            let names = e.zones[i].members.map { LayoutsWindow.shown?.appName($0.bundleID) ?? $0.bundleID }
            (names.isEmpty ? "no apps" : names.joined(separator: ", ") as NSString)
                .draw(in: r.insetBy(dx: 6, dy: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                     .foregroundColor: NSColor.labelColor])
            if selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(rect: CGRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)).fill()
            }
        }
        if let rubber {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: rubber)
            p.setLineDash([4, 3], count: 2, phase: 0)
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard var e = editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = e.selected, e.isHandle(p, canvas: bounds.size) { drag = .resize(i); return }
        e.select(at: p, canvas: bounds.size)
        if let i = e.selected { drag = .move(i, e.zones[i].rect, p) } else { drag = .draw(p) }
        editor = e
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var e = editor, let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .draw(let start): rubber = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .move(let i, let from, let start): e.move(i, from: from, by: CGSize(width: p.x - start.x, height: p.y - start.y), canvas: bounds.size)
        case .resize(let i): e.resize(i, to: p, canvas: bounds.size)
        }
        editor = e
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; rubber = nil; needsDisplay = true; changed() }
        guard var e = editor, case .draw(let start)? = drag else { return }
        _ = e.draw(from: start, to: convert(event.locationInWindow, from: nil), canvas: bounds.size)
        editor = e
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { editor?.deleteSelected(); needsDisplay = true; changed() }   // ⌫, ⌦
        else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class TopStackView: NSStackView { override var isFlipped: Bool { true } }

@MainActor
final class TopDocumentView: NSView { override var isFlipped: Bool { true } }
