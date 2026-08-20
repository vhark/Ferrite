import AppKit
import SwiftUI

/// Single reusable Preferences window. The app is an accessory (no Dock icon),
/// so it activates itself before showing the window.
final class PreferencesWindowController {
    private var window: NSWindow?
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = LayoutsPreferencesModel(coordinator: coordinator)
        let hosting = NSHostingController(rootView: LayoutsPreferencesView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacTLM Layouts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
