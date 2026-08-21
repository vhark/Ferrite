import AppKit
import MacTLMCore

/// AX-backed implementation of the Core driver seam.
final class MacWindowDriver: WindowDriving {
    /// Handles cached by stableID so setFrame can reach the AXUIElement.
    /// Entries for a bundle are evicted and rebuilt on each enumeration.
    private var handleCache: [Int: AXWindowHandle] = [:]
    private var idsByBundle: [String: [Int]] = [:]

    func windows(ofBundleID bundleID: String) -> [DriverWindow] {
        for id in idsByBundle[bundleID] ?? [] { handleCache.removeValue(forKey: id) }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        var result: [DriverWindow] = []
        var ids: [Int] = []
        for app in apps {
            guard !app.isHidden else { continue }
            let handle = AXAppHandle(pid: app.processIdentifier)
            for window in handle.windows {
                guard window.isStandardWindow, !window.isMinimized,
                      let frame = window.frame, frame.width > 1, frame.height > 1
                else { continue }
                handleCache[window.stableID] = window
                ids.append(window.stableID)
                result.append(DriverWindow(id: window.stableID,
                                           pid: app.processIdentifier,
                                           title: window.title,
                                           titleHash: WindowIdentity.hash(window.title),
                                           frame: frame))
            }
        }
        idsByBundle[bundleID] = ids
        return result
    }

    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect {
        guard let handle = handleCache[window.id] else { return window.frame }
        return handle.setFrame(frame) ?? window.frame
    }

    /// Live AX handle for a window id from the most recent enumeration.
    func handle(forWindowID id: Int) -> AXWindowHandle? {
        handleCache[id]
    }
}
