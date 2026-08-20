import ApplicationServices
import AppKit

/// Wrapper over one window's AXUIElement. Frames are CG space (top-left).
final class AXWindowHandle {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    /// Stable for the window's lifetime: AXUIElement copies for the same
    /// window are CFEqual and share a CFHash.
    var stableID: Int { Int(bitPattern: CFHash(element)) }

    var title: String {
        (copyValue(kAXTitleAttribute) as? String) ?? ""
    }

    /// True only for ordinary document/app windows. Excludes Finder's desktop
    /// window, tooltips, popovers and other non-standard AX windows that would
    /// otherwise be captured into layouts and driven around.
    var isStandardWindow: Bool {
        (copyValue(kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
    }

    /// Minimized windows keep a stale on-screen frame and must never become
    /// layout members: raising one un-minimizes it behind the user's back.
    var isMinimized: Bool {
        (copyValue(kAXMinimizedAttribute) as? Bool) == true
    }

    var frame: CGRect? {
        guard let positionValue = copyValue(kAXPositionAttribute),
              let sizeValue = copyValue(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Rectangle's proven sequence: position, size, position again (apps may
    /// shift origin while applying the size). Returns the achieved frame.
    @discardableResult
    func setFrame(_ rect: CGRect) -> CGRect? {
        var point = rect.origin
        var size = rect.size
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        return frame
    }

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}

/// Wrapper over one running app's AX root element.
final class AXAppHandle {
    let element: AXUIElement
    let pid: pid_t
    private var didEnableManualAccessibility = false

    init(pid: pid_t) {
        self.pid = pid
        element = AXUIElementCreateApplication(pid)
    }

    var windows: [AXWindowHandle] { windowsResult().windows }

    /// Windows plus the raw AXError, so callers can diagnose empty results.
    ///
    /// AXManualAccessibility is applied LAZILY, only when a first query comes
    /// back empty: Electron apps expose windows only after that opt-in, but
    /// setting it eagerly makes Finder report zero windows (verified 2026-08-19).
    func windowsResult() -> (windows: [AXWindowHandle], error: AXError) {
        let first = copyWindows()
        if !first.windows.isEmpty || first.error != .success { return first }
        guard !didEnableManualAccessibility else { return first }
        didEnableManualAccessibility = true
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
        return copyWindows()
    }

    private func copyWindows() -> (windows: [AXWindowHandle], error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                                 &value)
        guard error == .success else { return ([], error) }
        guard let array = value as? [AXUIElement] else { return ([], .noValue) }
        return (array.map(AXWindowHandle.init), .success)
    }
}
