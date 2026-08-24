import AppKit
import ApplicationServices

/// Per-app AXObserver forwarding window created/moved/resized/title events.
final class AppObserver {
    /// A window-level AX event, for features that need more than
    /// "something changed" — mating, resize propagation, frame caches.
    struct WindowEvent {
        enum Kind { case created, moved, resized, titleChanged }
        let kind: Kind
        let bundleID: String
        let pid: pid_t
        /// Stable id of the window element, matching `DriverWindow.id`.
        let windowID: Int
        let frame: CGRect
    }

    /// Maps the four subscribed AX notification names onto event kinds.
    /// An unknown name produces no rich event; the coarse signal still fires.
    private static func kind(of notification: String) -> WindowEvent.Kind? {
        switch notification {
        case kAXWindowCreatedNotification: return .created
        case kAXWindowMovedNotification: return .moved
        case kAXWindowResizedNotification: return .resized
        case kAXTitleChangedNotification: return .titleChanged
        default: return nil
        }
    }

    let pid: pid_t
    let bundleID: String
    private var observer: AXObserver?
    private let appElement: AXUIElement
    private let onActivity: (String) -> Void
    private let onWindowEvent: ((WindowEvent) -> Void)?

    private static let notifications = [
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
    ]

    init?(app: NSRunningApplication,
          onActivity: @escaping (String) -> Void,
          onWindowEvent: ((WindowEvent) -> Void)? = nil) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.pid = app.processIdentifier
        self.bundleID = bundleID
        self.onActivity = onActivity
        self.onWindowEvent = onWindowEvent
        self.appElement = AXUIElementCreateApplication(pid)
        // NOTE: AXManualAccessibility is deliberately NOT set here. Setting it
        // eagerly makes Finder report zero windows; AXAppHandle enables it
        // lazily (process-wide) only for apps whose window list comes back empty.

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let this = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            // The coarse signal fires unconditionally: window persistence
            // depends on it, and it must not hinge on reading a frame.
            this.onActivity(this.bundleID)
            guard let handler = this.onWindowEvent,
                  let kind = AppObserver.kind(of: notification as String)
            else { return }
            let window = AXWindowHandle(element: element)
            guard let frame = window.frame else { return }
            handler(WindowEvent(kind: kind,
                                bundleID: this.bundleID,
                                pid: this.pid,
                                windowID: window.stableID,
                                frame: frame))
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
