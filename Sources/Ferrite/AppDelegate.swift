import AppKit
import FerriteCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PersistenceCoordinator?
    private var statusMenu: StatusMenuController?
    private var keepAwake: KeepAwakeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXPermission.isGranted {
            NSLog("Ferrite: accessibility not granted; prompting and polling")
            AXPermission.request()
            // Poll until granted, then start (System Settings grant is async).
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard AXPermission.isGranted else {
                        NSLog("Ferrite: still waiting for accessibility grant")
                        return
                    }
                    timer.invalidate()
                    self?.startServices()
                }
            }
        } else {
            startServices()
        }
    }

    private func startServices() {
        NSLog("Ferrite: accessibility granted; starting services")
        do {
            let coordinator = try PersistenceCoordinator()
            coordinator.start()
            self.coordinator = coordinator
            let power = KeepAwakeController(
                store: KeepAwakeSettingsStore(
                    url: coordinator.supportDirectory.appendingPathComponent("power.json")),
                powerSource: SystemPowerSource(),
                helper: XpcKeepAwakeHelperClient(),
                assertions: IOKitPowerAssertionController(),
                loginItem: MainAppLoginItemController())
            power.start()
            self.keepAwake = power
            self.statusMenu = StatusMenuController(coordinator: coordinator, keepAwake: power)
        } catch {
            NSLog("Ferrite failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake?.stop()
    }
}
