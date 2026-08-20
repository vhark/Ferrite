import AppKit
import ApplicationServices

/// Per-app AXObserver forwarding window created/moved/resized/title events.
final class AppObserver {
    let pid: pid_t
    let bundleID: String
    private var observer: AXObserver?
    private let appElement: AXUIElement
    private let onActivity: (String) -> Void

    private static let notifications = [
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
    ]

    init?(app: NSRunningApplication, onActivity: @escaping (String) -> Void) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.pid = app.processIdentifier
        self.bundleID = bundleID
        self.onActivity = onActivity
        self.appElement = AXUIElementCreateApplication(pid)
        // NOTE: AXManualAccessibility is deliberately NOT set here. Setting it
        // eagerly makes Finder report zero windows; AXAppHandle enables it
        // lazily (process-wide) only for apps whose window list comes back empty.

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let this = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            this.onActivity(this.bundleID)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success,
              let axObserver = created else { return nil }
        observer = axObserver

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.notifications {
            if AXObserverAddNotification(axObserver, appElement, name as CFString, refcon) == .success {
                registered += 1
            }
        }
        guard registered > 0 else { return nil } // deaf observer → monitor's retry path
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }

    /// Race handling: fire one synthetic activity so windows that existed
    /// before subscription get captured.
    func kickstart() {
        onActivity(bundleID)
    }

    deinit {
        if let observer {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
