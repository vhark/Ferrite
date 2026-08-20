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
        let layoutsModel = LayoutsPreferencesModel(coordinator: coordinator)
        let appsModel = AppsPreferencesModel(coordinator: coordinator)
        let hosting = NSHostingController(
            rootView: PreferencesRootView(layoutsModel: layoutsModel, appsModel: appsModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacTLM Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Layouts and Apps share one window, macOS System Settings style.
private struct PreferencesRootView: View {
    @ObservedObject var layoutsModel: LayoutsPreferencesModel
    @ObservedObject var appsModel: AppsPreferencesModel

    var body: some View {
        TabView {
            LayoutsPreferencesView(model: layoutsModel)
                .tabItem { Text("Layouts") }
            AppsPreferencesView(model: appsModel)
                .tabItem { Text("Apps") }
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 420)
    }
}
