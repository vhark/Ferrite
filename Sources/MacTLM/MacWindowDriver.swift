import AppKit
import MacTLMCore

/// AX-backed implementation of the Core driver seam.
final class MacWindowDriver: WindowDriving {
    /// Handles cached by stableID so setFrame can reach the AXUIElement.
    /// Refreshed on every enumeration.
    private var handleCache: [Int: AXWindowHandle] = [:]

    func windows(ofBundleID bundleID: String) -> [DriverWindow] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        var result: [DriverWindow] = []
        for app in apps {
            let handle = AXAppHandle(pid: app.processIdentifier)
            for window in handle.windows {
                guard let frame = window.frame, frame.width > 1, frame.height > 1
                else { continue }
                handleCache[window.stableID] = window
                result.append(DriverWindow(id: window.stableID,
                                           title: window.title,
                                           frame: frame))
            }
        }
        return result
    }

    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect {
        guard let handle = handleCache[window.id] else { return window.frame }
        return handle.setFrame(frame) ?? window.frame
    }
}
