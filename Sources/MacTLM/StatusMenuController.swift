import AppKit
import ServiceManagement
import KeyboardShortcuts
import MacTLMCore

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
            accessibilityDescription: "MacTLM")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild on every open so layouts and displays stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuLayouts.removeAll()

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
        menu.addItem(NSMenuItem(title: "Quit MacTLM",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    // MARK: - Item builders

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
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
        if let shortcut = LayoutShortcuts.shortcut(forBundle: bundle.name) {
            item.setShortcut(shortcut)
        }
        // A one-display workspace has nothing to disambiguate, so it acts directly.
        guard bundle.layouts.count > 1 else {
            item.action = #selector(launchBundle(_:))
            return item
        }
        let submenu = NSMenu()
        let all = NSMenuItem(title: "All displays",
                             action: #selector(launchBundle(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = bundle.name as NSString
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
            NSLog("MacTLM: login item toggle failed: %@", error.localizedDescription)
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
                message: "macOS needs you to allow MacTLM in Login Items before it "
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
