import AppKit
import SwiftUI

/// Single reusable Preferences window. The app is an accessory (no Dock icon),
/// so it activates itself before showing the window.
final class PreferencesWindowController {
    private var window: NSWindow?
    private var layoutsModel: LayoutsPreferencesModel?
    private var appsModel: AppsPreferencesModel?
    private var reflowsModel: ReflowsPreferencesModel?
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            // The window and its models are cached for the daemon's lifetime;
            // re-read on every show so live window titles and records reflect
            // the world now, not when the window was first created.
            layoutsModel?.reload()
            appsModel?.reload()
            reflowsModel?.reload()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let layoutsModel = LayoutsPreferencesModel(coordinator: coordinator)
        let appsModel = AppsPreferencesModel(coordinator: coordinator)
        let reflowsModel = ReflowsPreferencesModel(coordinator: coordinator)
        self.layoutsModel = layoutsModel
        self.appsModel = appsModel
        self.reflowsModel = reflowsModel
        let hosting = NSHostingController(
            rootView: PreferencesRootView(layoutsModel: layoutsModel,
                                          appsModel: appsModel,
                                          reflowsModel: reflowsModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ferrite Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Layouts, Apps and Reflows share one window, macOS System Settings style.
private struct PreferencesRootView: View {
    @ObservedObject var layoutsModel: LayoutsPreferencesModel
    @ObservedObject var appsModel: AppsPreferencesModel
    @ObservedObject var reflowsModel: ReflowsPreferencesModel

    var body: some View {
        TabView {
            LayoutsPreferencesView(model: layoutsModel)
                .tabItem { Text("Layouts") }
            AppsPreferencesView(model: appsModel)
                .tabItem { Text("Apps") }
            ReflowsPreferencesView(model: reflowsModel)
                .tabItem { Text("Reflows") }
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 420)
    }
}
