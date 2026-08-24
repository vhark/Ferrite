import AppKit
import ServiceManagement
import KeyboardShortcuts
import FerriteCore

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength)
    private let coordinator: PersistenceCoordinator
    private var menuLayouts: [UUID: MonitorLayout] = [:]
    private lazy var preferences = PreferencesWindowController(coordinator: coordinator)

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "Ferrite")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild on every open so layouts and displays stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuLayouts.removeAll()

        // PRD §4: the reflow row sits at the top, above anything user-created.
        // The row reflows the frontmost window's group when it has one, so the
        // header says which.
        let groups = coordinator.magnetGroupSummaries()
        menu.addItem(sectionHeader(groups.contains { $0.isActive }
            ? "Reflow this group" : "Reflow this display"))
        menu.addItem(presetRow())
        menu.addItem(.separator())

        if !groups.isEmpty {
            menu.addItem(sectionHeader("Groups"))
            for group in groups { menu.addItem(groupItem(group)) }
            menu.addItem(.separator())
        }

        // One row per workspace. Archived bundles are already excluded, so
        // their layouts never surface here even though they stay on disk.
        let connected = Set(ScreenGeometry.allDisplays.map(\.info.id))
        var attached: [LayoutBundle] = []
        var detached: [LayoutBundle] = []
        for bundle in coordinator.loadBundles() {
            if bundle.layoutsByConnection(connectedDisplayIDs: connected)
                .connected.isEmpty {
                detached.append(bundle)
            } else {
                attached.append(bundle)
            }
        }

        if !attached.isEmpty {
            menu.addItem(sectionHeader("Workspaces"))
            for bundle in attached {
                menu.addItem(workspaceItem(bundle, connectedDisplayIDs: connected))
            }
        }

        // Workspaces with nothing attached collapse out of the way.
        if !detached.isEmpty {
            let parent = NSMenuItem(title: "Workspaces for other displays",
                                    action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for bundle in detached {
                submenu.addItem(workspaceItem(bundle, connectedDisplayIDs: connected))
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if menu.items.isEmpty == false { menu.addItem(.separator()) }
        menu.addItem(actionItem("Save Current Arrangement as Layout…",
                                #selector(saveArrangement)))
        menu.addItem(actionItem("Restore All Window Positions", #selector(restoreAll)))
        menu.addItem(.separator())
        let pause = actionItem("Pause Persistence", #selector(togglePause))
        pause.state = coordinator.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(actionItem("Exclude Frontmost App", #selector(excludeFrontmost)))
        menu.addItem(.separator())
        let loginStatus = SMAppService.mainApp.status
        let loginTitle = loginStatus == .requiresApproval
            ? "Launch at Login (needs approval)"
            : "Launch at Login"
        let login = actionItem(loginTitle, #selector(toggleLoginItem))
        login.state = loginStatus == .enabled ? .on : .off
        menu.addItem(login)
        let preferences = actionItem("Preferences…", #selector(showPreferences))
        preferences.keyEquivalent = ","
        preferences.keyEquivalentModifierMask = [.command]
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ferrite",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    // MARK: - Item builders

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Presets in menu order: weighted treemaps first, then the even splits.
    private static let reflowPresets: [(preset: GroupLayoutSolver.Preset,
                                       title: String)] = [
        (.treemap(bias: .center), "Treemap — heaviest in the centre"),
        (.treemap(bias: .left), "Treemap — heaviest on the left"),
        (.treemap(bias: .right), "Treemap — heaviest on the right"),
        (.symmetric, "Symmetric — equal areas"),
        (.columns, "Columns"),
        (.rows, "Rows"),
        (.grid, "Grid"),
        (.mainSide, "Main + side"),
    ]

    /// One row of glyph buttons. A menu item's view is never auto-sized, so the
    /// stack gets an explicit frame from its own fitting size.
    private func presetRow() -> NSMenuItem {
        let buttons = Self.reflowPresets.indices.map { index -> NSButton in
            let entry = Self.reflowPresets[index]
            let button = NSButton(image: PresetGlyph.image(for: entry.preset),
                                  target: self, action: #selector(reflowPreset(_:)))
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = entry.title
            button.setAccessibilityLabel(entry.title)
            button.widthAnchor.constraint(
                equalToConstant: PresetGlyph.size.width + 4).isActive = true
            button.heightAnchor.constraint(
                equalToConstant: PresetGlyph.size.height + 4).isActive = true
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 2
        // Left inset lines the glyphs up with the indented rows below.
        row.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 4, right: 12)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        let item = NSMenuItem()
        item.view = row
        return item
    }

    /// A weight nudge rather than a jump: a few grows promote a window
    /// noticeably without collapsing its mates.
    private static let growFactor = 1.25
    private static let shrinkFactor = 0.8

    /// One group row: the mated apps, with everything that acts on the group in
    /// its submenu. Nothing acts from the row itself — `Ungroup` is one click
    /// from a title, and titles are for reading.
    private func groupItem(_ group: PersistenceCoordinator.GroupSummary) -> NSMenuItem {
        let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        let submenu = NSMenu()

        let modeItem = NSMenuItem(title: "Resize mode", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        let choices: [(title: String, mode: MagnetGroup.ResizeMode, action: Selector)] = [
            ("Shrink", .shrink, #selector(setGroupModeShrink(_:))),
            ("Nudge", .nudge, #selector(setGroupModeNudge(_:))),
        ]
        for choice in choices {
            let row = groupActionItem(choice.title, choice.action, group.id)
            row.state = group.resizeMode == choice.mode ? .on : .off
            modes.addItem(row)
        }
        modeItem.submenu = modes
        submenu.addItem(modeItem)
        submenu.addItem(.separator())
        submenu.addItem(groupActionItem("Grow frontmost",
                                        #selector(growGroupFrontmost(_:)), group.id))
        submenu.addItem(groupActionItem("Shrink frontmost",
                                        #selector(shrinkGroupFrontmost(_:)), group.id))
        submenu.addItem(.separator())
        submenu.addItem(groupActionItem("Ungroup",
                                        #selector(ungroupGroup(_:)), group.id))
        item.submenu = submenu
        return item
    }

    private func groupActionItem(_ title: String, _ action: Selector,
                                 _ groupID: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = groupID as NSUUID
        return item
    }

    // `LayoutShortcuts.shortcut(forBundle:)` and `NSMenuItem.setShortcut` are
    // main-actor bound; menu building already happens on the main actor.
    @MainActor
    private func workspaceItem(_ bundle: LayoutBundle,
                               connectedDisplayIDs: Set<String>) -> NSMenuItem {
        let item = NSMenuItem(title: bundle.name, action: nil, keyEquivalent: "")
        item.target = self
        item.indentationLevel = 1
        item.representedObject = bundle.name as NSString
        let shortcut = LayoutShortcuts.shortcut(forBundle: bundle.name)
        // A one-display workspace has nothing to disambiguate, so it acts directly.
        guard bundle.layouts.count > 1 else {
            item.action = #selector(launchBundle(_:))
            if let shortcut { item.setShortcut(shortcut) }
            return item
        }
        let submenu = NSMenu()
        let all = NSMenuItem(title: "All displays",
                             action: #selector(launchBundle(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = bundle.name as NSString
        // AppKit does not draw a key equivalent on a submenu parent, so the glyph
        // goes on the row the hotkey actually triggers.
        if let shortcut { all.setShortcut(shortcut) }
        submenu.addItem(all)
        for layout in bundle.layouts {
            // "(adapted)" warns that this display is absent, so the layout will
            // be remapped onto whatever is attached.
            let title = connectedDisplayIDs.contains(layout.displayID)
                ? layout.displayName
                : "\(layout.displayName) (adapted)"
            let row = NSMenuItem(title: title,
                                 action: #selector(launchSingleLayout(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = layout.id as NSUUID
            menuLayouts[layout.id] = layout
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func reflowPreset(_ sender: NSButton) {
        guard Self.reflowPresets.indices.contains(sender.tag) else { return }
        coordinator.reflowDisplay(Self.reflowPresets[sender.tag].preset)
        // A button inside a menu item's view does not dismiss the menu itself.
        statusItem.menu?.cancelTracking()
    }

    @objc private func setGroupModeShrink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.setResizeMode(.shrink, ofGroup: id)
    }

    @objc private func setGroupModeNudge(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.setResizeMode(.nudge, ofGroup: id)
    }

    @objc private func growGroupFrontmost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.adjustFrontmostWeight(inGroup: id, by: Self.growFactor)
    }

    @objc private func shrinkGroupFrontmost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.adjustFrontmostWeight(inGroup: id, by: Self.shrinkFactor)
    }

    @objc private func ungroupGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.ungroup(id)
    }

    @objc private func launchSingleLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = menuLayouts[id] else { return }
        coordinator.applyLayout(layout)
    }

    @objc private func launchBundle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        coordinator.applyBundle(named: name)
    }

    @objc private func saveArrangement() {
        let alert = NSAlert()
        alert.messageText = "Save Current Arrangement"
        alert.informativeText = "Name this layout. Windows on each display are saved per monitor."
        let nameLabel = NSTextField(frame: NSRect(x: 0, y: 56, width: 320, height: 16))
        nameLabel.stringValue = "Layout name"
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        field.placeholderString = "Layout name"
        let clearStage = NSButton(checkboxWithTitle: "Hide other apps when launching",
                                  target: nil, action: nil)
        clearStage.frame = NSRect(x: 0, y: 0, width: 320, height: 18)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 76))
        accessory.addSubview(nameLabel)
        accessory.addSubview(field)
        accessory.addSubview(clearStage)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        coordinator.saveCurrentArrangement(
            name: name,
            stageMode: clearStage.state == .on ? .clearStage : .leaveOthers)
    }

    @objc private func restoreAll() { coordinator.restoreAll() }

    @objc private func showPreferences() { preferences.show() }

    @objc private func togglePause(_ sender: NSMenuItem) {
        coordinator.isPaused.toggle()
        sender.state = coordinator.isPaused ? .on : .off
    }

    @objc private func excludeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        coordinator.exclude(bundleID: bundleID)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Ferrite: login item toggle failed: %@", error.localizedDescription)
            presentLoginItemAlert(
                title: "Couldn't change Launch at Login",
                message: error.localizedDescription,
                offerSettings: false)
        }
        // Re-read: register() can succeed yet still need user approval.
        let status = service.status
        sender.state = status == .enabled ? .on : .off
        if status == .requiresApproval {
            presentLoginItemAlert(
                title: "Approval needed",
                message: "macOS needs you to allow Ferrite in Login Items before it "
                    + "can start automatically.",
                offerSettings: true)
        }
    }

    /// Shows a modal alert, optionally with a button that opens the
    /// Login Items pane of System Settings.
    private func presentLoginItemAlert(title: String, message: String,
                                       offerSettings: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if offerSettings {
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard offerSettings, response == .alertFirstButtonReturn,
              let url = URL(string:
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
