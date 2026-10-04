import AppKit
import WindowOrganizerCore

/// The group list (WO-GROUPS G2): one line per group, its own draft and Save. Nothing here moves a window.
@MainActor
final class GroupsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static var shown: GroupsWindow?
    static func show() {
        let w = shown ?? GroupsWindow(); shown = w
        if !w.window.isVisible && !w.dirty { w.reload() }
        NSApp.activate(ignoringOtherApps: true); w.window.center(); w.window.makeKeyAndOrderFront(nil)
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let rows = TopStackView()
    let scroll = NSScrollView()
    let status = NSTextField(labelWithString: "")
    let addButton = NSButton(title: "+ Add group", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    let saveButton = NSButton(title: "Save groups", target: nil, action: nil)
    var contextProvider: () -> WorkspaceContext = { WorkspaceContext.live() }
    var snapshotProvider: () -> (ListReport, Listing) = { snapshot() }
    var confirmDiscard: () -> Bool = {
        let alert = NSAlert(); alert.messageText = "Discard unsaved group changes?"
        alert.informativeText = "Save your changes before closing this window."
        alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }
    var draft: [WindowGroup] = []
    var loaded: [WindowGroup] = []
    var readFailed = false
    /// Groups whose mode popup says "Saved positions" but that have no positions yet: Capture decides.
    var savedRequested: Set<String> = []
    var popover: NSPopover?
    var dirty: Bool { draft != loaded }

    init(context: (() -> WorkspaceContext)? = nil, snapshot: (() -> (ListReport, Listing))? = nil) {
        super.init()
        if let context { contextProvider = context }
        if let snapshot { snapshotProvider = snapshot }
        window.title = "Groups"; window.minSize = NSSize(width: 1100, height: 300)
        window.isReleasedWhenClosed = false; window.delegate = self
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = rows
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                                     rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)])
        for (button, action) in [(addButton, #selector(addTapped)), (revertButton, #selector(revertTapped)), (saveButton, #selector(saveTapped))] {
            button.target = self; button.action = action
        }
        saveButton.keyEquivalent = "\r"
        status.lineBreakMode = .byTruncatingTail; status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addButton, status, NSView(), revertButton, saveButton]); footer.spacing = 10
        let title = NSTextField(labelWithString: "Groups"); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let hint = NSTextField(labelWithString: "A group is a set of apps or windows with a screen and desktops. Edit and save here; nothing moves yet.")
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
        let content = NSStackView(views: [title, hint, scroll, footer]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = content
        for view in [scroll, footer] { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        reload()
    }

    // MARK: load, save

    func reload() {
        window.makeFirstResponder(nil); popover?.close()
        do { loaded = try layoutStore().load().groups; readFailed = false; status.stringValue = "" }
        catch { loaded = []; readFailed = true; status.stringValue = "Could not read the layouts: \(error)" }
        draft = loaded; savedRequested = []
        rebuild()
    }

    @objc func revertTapped() { reload() }
    @objc func saveTapped() { save() }

    func save() {
        window.makeFirstResponder(nil)
        guard !readFailed else { status.stringValue = "Not saved: repair the unreadable layout file first."; return }
        for g in draft where !g.members.isEmpty {
            if let why = WindowGroup.nameProblem(g.name, id: g.id, in: draft.filter { !$0.members.isEmpty }) { status.stringValue = "Not saved: \(why)"; rebuild(); return }
        }
        do {
            let store = layoutStore()
            var fresh = try store.load()
            let dropped = fresh.replaceGroups(draft)
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.save(fresh)
            loaded = fresh.groups; draft = loaded
            savedRequested = savedRequested.intersection(Set(draft.map(\.id)))
            status.stringValue = dropped == 0 ? "Saved \(loaded.count) group(s)." :
                "Saved \(loaded.count) group(s). \(dropped) group\(dropped == 1 ? "" : "s") without apps \(dropped == 1 ? "was" : "were") not saved."
        } catch { status.stringValue = "Not saved: \(error)" }
        rebuild()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.makeFirstResponder(nil)
        guard dirty else { return true }
        guard confirmDiscard() else { return false }
        reload(); return true
    }

    // MARK: edits (the controls call these; the smoke does too)

    func addGroup(openMembers: Bool = true) {
        var n = 1
        while draft.contains(where: { $0.name.lowercased() == "group \(n)" }) { n += 1 }
        draft.append(WindowGroup(id: UUID().uuidString, name: "Group \(n)", members: []))
        rebuild()
        if openMembers { showMembers(draft.count - 1) }
    }
    func rename(_ i: Int, _ name: String) {
        guard draft.indices.contains(i) else { return }
        draft[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines); rebuild()
        if let why = WindowGroup.nameProblem(draft[i].name, id: draft[i].id, in: draft) { status.stringValue = "Not saved: \(why)" }
    }
    func delete(_ i: Int) {
        guard draft.indices.contains(i) else { return }
        savedRequested.remove(draft[i].id); draft.remove(at: i); rebuild()
    }
    func move(_ i: Int, by delta: Int) {
        guard draft.indices.contains(i), draft.indices.contains(i + delta) else { return }
        draft.swapAt(i, i + delta); rebuild()
    }
    func addMember(_ i: Int, bundleID: String, pattern: String?) -> String? {
        guard draft.indices.contains(i) else { return nil }
        let p = pattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        let member = ZoneMember(bundleID: bundleID, titlePattern: (p?.isEmpty ?? true) ? nil : p)
        if draft[i].members.contains(member) { return "That app and title are already in this group." }
        draft[i].members.append(member); rebuild(); return nil
    }
    func removeMember(_ i: Int, _ m: Int) {
        guard draft.indices.contains(i) else { return }
        draft[i] = draft[i].removingMember(at: m)
        rebuild()
    }
    func setPattern(_ i: Int, _ m: Int, _ text: String) -> String? {
        guard draft.indices.contains(i), draft[i].members.indices.contains(m) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = draft[i].members[m], new = ZoneMember(bundleID: old.bundleID, titlePattern: t.isEmpty ? nil : t)
        if new == old { return nil }
        if draft[i].members.contains(new) { return "That app and title are already in this group." }
        draft[i].members[m] = new
        if case .saved(let positions) = draft[i].mode {   // a rect taken for the old filter must not place another window
            let kept = positions.filter { !($0.matcher.bundleID == old.bundleID && $0.matcher.titlePattern == old.titlePattern) }
            if kept.count != positions.count {
                draft[i].mode = kept.isEmpty ? .tiled : .saved(kept)
                status.stringValue = "Saved position of \(Self.appName(old.bundleID)) dropped: its title filter changed. Capture again."
            }
        }
        rebuild(); return nil
    }
    func setScreen(_ i: Int, _ uuid: String?) {
        guard draft.indices.contains(i) else { return }
        draft[i].screen = uuid
        if uuid == nil { draft[i].desktops = [] }
        rebuild()
    }
    func toggleDesktop(_ i: Int, _ n: Int) {
        guard draft.indices.contains(i), draft[i].screen != nil else { return }
        if let at = draft[i].desktops.firstIndex(of: n) { draft[i].desktops.remove(at: at) }
        else { draft[i].desktops = (draft[i].desktops + [n]).sorted() }
        rebuild()
    }
    func setMode(_ i: Int, saved: Bool) {
        guard draft.indices.contains(i) else { return }
        if saved { if case .tiled = draft[i].mode { savedRequested.insert(draft[i].id) } }
        else { draft[i].mode = .tiled; savedRequested.remove(draft[i].id) }
        rebuild()
    }
    /// The screen the group is on, when it is connected and showing one of the group's desktops right now.
    func captureProblem(_ g: WindowGroup) -> String? {
        let context = contextProvider()
        guard let uuid = g.screen, context.screens.contains(where: { $0.uuid == uuid }) else { return "Connect the group's display to capture positions." }
        guard let now = context.desktops[uuid], g.desktops.contains(now) else { return "Switch that display to one of the group's desktops to capture positions." }
        return nil
    }
    func capture(_ i: Int) {
        guard draft.indices.contains(i) else { return }
        let g = draft[i]
        if let why = captureProblem(g) { status.stringValue = why; return }
        let context = contextProvider()
        guard let screen = context.screens.first(where: { $0.uuid == g.screen }) else { return }
        let positions = capturePositions(g, windows: snapshotProvider().0.windows, screen: screen)
        if positions.isEmpty { status.stringValue = "No window of this group is open on \(screen.name)."; return }
        draft[i].mode = .saved(positions); savedRequested.remove(g.id)
        status.stringValue = "Captured \(positions.count) position(s) for \(g.name)."
        rebuild()
    }

    // MARK: drawing

    func summary(_ g: WindowGroup) -> String {
        if g.members.isEmpty { return "No apps" }
        return g.members.map { m in m.titlePattern.map { "\(Self.appName(m.bundleID)) \"\($0)\"" } ?? Self.appName(m.bundleID) }.joined(separator: ", ")
    }
    static func appName(_ id: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.deletingPathExtension().lastPathComponent }
        return id
    }
    private func fixed(_ view: NSView, _ width: CGFloat) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true; return view
    }

    func rebuild() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let context = contextProvider()
        if draft.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: "No groups yet. Add one to start.")) }
        for (i, g) in draft.enumerated() { rows.addArrangedSubview(line(i, g, context)) }
        revertButton.isEnabled = dirty; saveButton.isEnabled = !readFailed && (dirty || draft.contains { $0.members.isEmpty })
        addButton.isEnabled = !readFailed && draft.count < Layouts.maxGroups
    }

    func line(_ i: Int, _ g: WindowGroup, _ context: WorkspaceContext) -> NSView {
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action); b.tag = i; b.bezelStyle = .rounded; return b
        }
        let up = button("▲", #selector(upTapped(_:))), down = button("▼", #selector(downTapped(_:)))
        up.isEnabled = i > 0; down.isEnabled = i < draft.count - 1
        up.toolTip = "Move up"; down.toolTip = "Move down"
        let name = NSTextField(string: g.name); name.tag = i; name.delegate = self; name.target = self; name.action = #selector(nameEdited(_:))
        (name.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        let problem = WindowGroup.nameProblem(g.name, id: g.id, in: draft)
        name.wantsLayer = true; name.layer?.cornerRadius = 4
        name.layer?.borderWidth = problem == nil ? 0 : 1.5; name.layer?.borderColor = NSColor.systemRed.cgColor
        name.toolTip = problem
        name.setAccessibilityLabel("Group name")
        let members = button(summary(g) + " ▾", #selector(membersTapped(_:)))
        members.lineBreakMode = .byTruncatingTail; members.toolTip = g.members.isEmpty ? "Add apps" : summary(g)
        let screen = NSPopUpButton(); screen.tag = i; screen.target = self; screen.action = #selector(screenPicked(_:))
        screen.addItem(withTitle: "Not assigned"); screen.lastItem?.representedObject = nil
        for s in context.screens { screen.addItem(withTitle: s.name); screen.lastItem?.representedObject = s.uuid }
        if let uuid = g.screen {
            if let at = context.screens.firstIndex(where: { $0.uuid == uuid }) { screen.selectItem(at: at + 1) }
            else { screen.addItem(withTitle: "Display not connected"); screen.lastItem?.isEnabled = false; screen.selectItem(at: screen.numberOfItems - 1) }
        }
        screen.setAccessibilityLabel("Screen")
        let desks = NSPopUpButton(frame: .zero, pullsDown: true); desks.tag = i
        let stored = (g.desktops.max() ?? 0)
        let count = max(g.screen.flatMap { context.counts[$0] } ?? 1, stored, 1)
        desks.addItem(withTitle: g.desktops.isEmpty ? "No desktop" : "Desktops: " + g.desktops.map(String.init).joined(separator: ", "))
        for n in 1...count {
            desks.addItem(withTitle: "Desktop \(n)"); desks.lastItem?.tag = n
            desks.lastItem?.state = g.desktops.contains(n) ? .on : .off
            desks.lastItem?.target = self; desks.lastItem?.action = #selector(desktopPicked(_:)); desks.lastItem?.representedObject = i
        }
        desks.isEnabled = g.screen != nil; desks.setAccessibilityLabel("Desktops")
        let isSaved: Bool = { if case .saved = g.mode { return true } else { return savedRequested.contains(g.id) } }()
        let mode = NSPopUpButton(); mode.tag = i; mode.target = self; mode.action = #selector(modePicked(_:))
        mode.addItems(withTitles: ["Tiled", "Saved positions"]); mode.selectItem(at: isSaved ? 1 : 0); mode.setAccessibilityLabel("Mode")
        let capture = button("Capture", #selector(captureTapped(_:)))
        capture.isHidden = !isSaved
        capture.isEnabled = captureProblem(g) == nil; capture.toolTip = captureProblem(g) ?? "Remember where this group's windows are now"
        let remove = button("−", #selector(deleteTapped(_:))); remove.toolTip = "Delete this group"
        let line = NSStackView(views: [up, down, fixed(name, 130), fixed(members, 190), fixed(screen, 175), fixed(desks, 130), fixed(mode, 140), fixed(capture, 90), remove])
        line.spacing = 8; line.alignment = .centerY
        return line
    }

    @objc func upTapped(_ s: NSButton) { move(s.tag, by: -1) }
    @objc func downTapped(_ s: NSButton) { move(s.tag, by: 1) }
    @objc func deleteTapped(_ s: NSButton) { delete(s.tag) }
    @objc func addTapped() { addGroup() }
    @objc func captureTapped(_ s: NSButton) { capture(s.tag) }
    @objc func membersTapped(_ s: NSButton) { showMembers(s.tag) }
    @objc func nameEdited(_ s: NSTextField) {
        rename(s.tag, s.stringValue)
    }
    @objc func screenPicked(_ s: NSPopUpButton) {
        guard let item = s.selectedItem, item.isEnabled else { return }
        setScreen(s.tag, item.representedObject as? String)
    }
    @objc func desktopPicked(_ item: NSMenuItem) { if let i = item.representedObject as? Int { toggleDesktop(i, item.tag) } }
    @objc func modePicked(_ s: NSPopUpButton) { setMode(s.tag, saved: s.indexOfSelectedItem == 1) }

    // MARK: members popover

    func showMembers(_ i: Int) {
        guard draft.indices.contains(i), i < rows.arrangedSubviews.count,
              let anchor = (rows.arrangedSubviews[i] as? NSStackView)?.arrangedSubviews[3] else { return }
        popover?.close()
        let pop = NSPopover(); pop.behavior = .transient
        pop.contentViewController = NSViewController(); pop.contentViewController?.view = membersView(i)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY); popover = pop
    }

    func membersView(_ i: Int) -> NSView {
        let g = draft[i]
        let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        let note = NSTextField(labelWithString: ""); note.textColor = .systemRed; note.font = .systemFont(ofSize: 11)
        if g.members.isEmpty { list.addArrangedSubview(NSTextField(labelWithString: "No apps yet. Pick one below.")) }
        for (m, member) in g.members.enumerated() {
            let pattern = NSTextField(string: member.titlePattern ?? ""); pattern.placeholderString = "Whole app"
            pattern.toolTip = "Optional title filter; * matches any text"; pattern.tag = m
            pattern.target = self; pattern.action = #selector(patternEdited(_:)); pattern.identifier = NSUserInterfaceItemIdentifier("\(i)")
            let remove = NSButton(title: "Remove", target: self, action: #selector(memberRemoved(_:))); remove.tag = m
            remove.identifier = NSUserInterfaceItemIdentifier("\(i)")
            let row = NSStackView(views: [fixed(NSTextField(labelWithString: Self.appName(member.bundleID)), 120), fixed(pattern, 150), remove]); row.spacing = 8
            list.addArrangedSubview(row)
        }
        let apps = NSPopUpButton(); apps.tag = i
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.compactMap(\.bundleIdentifier)
        for id in Set(running).sorted(by: { Self.appName($0).localizedCaseInsensitiveCompare(Self.appName($1)) == .orderedAscending }) {
            apps.addItem(withTitle: Self.appName(id)); apps.lastItem?.representedObject = id
        }
        let add = NSButton(title: "Add app", target: self, action: #selector(memberAdded(_:))); add.tag = i
        add.isEnabled = apps.numberOfItems > 0
        membersAppPopUp = apps; membersNote = note
        let bottom = NSStackView(views: [apps, add]); bottom.spacing = 8
        let stack = NSStackView(views: [list, bottom, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return stack
    }
    var membersAppPopUp: NSPopUpButton?
    var membersNote: NSTextField?

    func refreshMembers(_ i: Int, note: String?) {
        guard let pop = popover, draft.indices.contains(i) else { return }
        pop.contentViewController?.view = membersView(i); membersNote?.stringValue = note ?? ""
    }
    @objc func memberAdded(_ s: NSButton) {
        guard let id = membersAppPopUp?.selectedItem?.representedObject as? String else { return }
        let note = addMember(s.tag, bundleID: id, pattern: nil); refreshMembers(s.tag, note: note)
    }
    @objc func memberRemoved(_ s: NSButton) {
        guard let i = Int(s.identifier?.rawValue ?? "") else { return }
        removeMember(i, s.tag); refreshMembers(i, note: nil)
    }
    @objc func patternEdited(_ s: NSTextField) {
        guard let i = Int(s.identifier?.rawValue ?? "") else { return }
        let note = setPattern(i, s.tag, s.stringValue); refreshMembers(i, note: note)
    }
}
