import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PersistenceCoordinator?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXPermission.isGranted {
            NSLog("MacTLM: accessibility not granted; prompting and polling")
            AXPermission.request()
            // Poll until granted, then start (System Settings grant is async).
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard AXPermission.isGranted else {
                    NSLog("MacTLM: still waiting for accessibility grant")
                    return
                }
                timer.invalidate()
                self?.startServices()
            }
        } else {
            startServices()
        }
    }

    private func startServices() {
        NSLog("MacTLM: accessibility granted; starting services")
        do {
            let coordinator = try PersistenceCoordinator()
            coordinator.start()
            self.coordinator = coordinator
            self.statusMenu = StatusMenuController(coordinator: coordinator)
        } catch {
            NSLog("MacTLM failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }
}
