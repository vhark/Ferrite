import AppKit
import MacTLMCore
import ServiceManagement

let arguments = CommandLine.arguments

if arguments.contains("--login-status") || arguments.contains("--login-register")
    || arguments.contains("--login-unregister") {
    let service = SMAppService.mainApp
    func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval (approve in System Settings > Login Items)"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
    print("bundle path: \(Bundle.main.bundlePath)")
    print("bundle id:   \(Bundle.main.bundleIdentifier ?? "nil")")
    if arguments.contains("--login-register") {
        do { try service.register(); print("register: ok") }
        catch { print("register FAILED: \(error)") }
    }
    if arguments.contains("--login-unregister") {
        do { try service.unregister(); print("unregister: ok") }
        catch { print("unregister FAILED: \(error)") }
    }
    print("status: \(describe(service.status))")
    exit(0)
}

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
        if windows.isEmpty {
            // Report why: AX error, or windows present but all frame-filtered.
            let handles = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .map { AXAppHandle(pid: $0.processIdentifier).windowsResult() }
            let rawCount = handles.reduce(0) { $0 + $1.windows.count }
            let errors = handles.map { "\($0.error.rawValue)" }.joined(separator: ",")
            print("\n\(bundleID)  [0 usable | raw AX windows: \(rawCount), AXError: \(errors)]")
            for handle in handles {
                for window in handle.windows {
                    print("    raw \"\(window.title)\" frame=\(String(describing: window.frame))")
                }
            }
            continue
        }
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
