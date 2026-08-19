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

// Full app assembly arrives in Task 13.
if !AXPermission.isGranted { AXPermission.request() }
print("MacTLM: accessibility granted = \(AXPermission.isGranted)")
