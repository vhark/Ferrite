import AppKit
import MacTLMCore

let arguments = CommandLine.arguments

if arguments.contains("--list-windows") {
    guard AXPermission.isGranted else {
        print("Accessibility permission not granted. Run once without flags to request it.")
        exit(1)
    }
    let driver = MacWindowDriver()
    let area = ScreenGeometry.cgVisibleAreaOfMainScreen
    print("Visible area (CG): \(area)")
    print("Config key: \(ScreenGeometry.currentConfiguration.key)")
    var seen = Set<String>()
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
        guard let bundleID = app.bundleIdentifier else { continue }
        guard seen.insert(bundleID).inserted else { continue }
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { continue }
        print("\n\(bundleID)")
        for window in windows {
            print("  [\(window.id)] \"\(window.title)\" \(window.frame)")
        }
    }
    exit(0)
}

if arguments.contains("--watch") {
    guard AXPermission.isGranted else {
        print("Accessibility permission not granted.")
        exit(1)
    }
    let monitor = WorkspaceMonitor()
    monitor.onAppLaunched = { print("LAUNCH \($0)") }
    monitor.onAppTerminated = { print("QUIT   \($0)") }
    monitor.onActivity = { print("EVENT  \($0)") }
    monitor.start()
    print("Watching window events. Ctrl-C to stop.")
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
