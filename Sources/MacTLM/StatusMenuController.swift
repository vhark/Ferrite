import AppKit
import ServiceManagement
import MacTLMCore

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength)
    private let coordinator: PersistenceCoordinator
    private var menuLayouts: [UUID: MonitorLayout] = [:]

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

        let library = coordinator.layoutLibraryStore.load()
        let connectedIDs = Set(ScreenGeometry.allDisplays.map(\.info.id))
        let byDisplay = Dictionary(grouping: library.layouts, by: \.displayID)

        // Sections per connected display.
        for display in ScreenGeometry.allDisplays {
            guard let layouts = byDisplay[display.info.id], !layouts.isEmpty else { continue }
            menu.addItem(sectionHeader(display.name))
            for layout in layouts.sorted(by: { $0.name < $1.name }) {
                menu.addItem(layoutItem(layout, indent: 1))
            }
        }

        // Inactive monitor layouts (collapsed submenu), adaptive launch.
        let inactive = library.layouts.filter { !connectedIDs.contains($0.displayID) }
        if !inactive.isEmpty {
            let parent = NSMenuItem(title: "Inactive Monitor Layouts",
                                    action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (displayName, layouts) in Dictionary(grouping: inactive, by: \.displayName)
                .sorted(by: { $0.key < $1.key }) {
                submenu.addItem(sectionHeader(displayName))
                for layout in layouts.sorted(by: { $0.name < $1.name }) {
                    submenu.addItem(layoutItem(layout, indent: 1))
                }
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
        let login = actionItem("Launch at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
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

    private func layoutItem(_ layout: MonitorLayout, indent: Int) -> NSMenuItem {
        let title = layout.stageMode == .clearStage ? "\(layout.name) · clears stage" : layout.name
        let item = NSMenuItem(title: title,
                              action: #selector(launchLayout(_:)), keyEquivalent: "")
        item.target = self
        item.indentationLevel = indent
        item.representedObject = layout.id as NSUUID
        menuLayouts[layout.id] = layout
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func launchLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = menuLayouts[id] else { return }
        coordinator.applyLayout(layout)
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
                sender.state = .off
            } else {
                try service.register()
                sender.state = .on
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}
