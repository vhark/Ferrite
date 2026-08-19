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
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)

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
        for name in Self.notifications {
            AXObserverAddNotification(axObserver, appElement, name as CFString, refcon)
        }
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
