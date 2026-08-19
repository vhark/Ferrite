import AppKit
import MacTLMCore

enum ScreenGeometry {
    /// The main screen's visible area (minus menu bar/Dock) in CG space —
    /// the coordinate space the AX API uses. THE only NS→CG conversion point.
    static var cgVisibleAreaOfMainScreen: CGRect {
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first
        else { return .zero }
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX,
                      y: primary.frame.maxY - visible.maxY,
                      width: visible.width,
                      height: visible.height)
    }

    /// Current display configuration from attached screens.
    static var currentConfiguration: DisplayConfiguration {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let uuid: String
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, cfUUID) as String
            } else {
                uuid = String(displayID)
            }
            return DisplayInfo(id: uuid,
                               width: screen.frame.width,
                               height: screen.frame.height,
                               scale: screen.backingScaleFactor)
        }
        return DisplayConfiguration(displays: displays)
    }
}
