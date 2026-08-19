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

    init(pid: pid_t) {
        self.pid = pid
        element = AXUIElementCreateApplication(pid)
        // Electron apps expose windows only after this.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    var windows: [AXWindowHandle] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array.map(AXWindowHandle.init)
    }
}
