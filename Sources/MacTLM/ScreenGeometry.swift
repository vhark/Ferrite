import AppKit
import MacTLMCore

enum ScreenGeometry {
    /// The main screen's visible area (minus menu bar/Dock) in CG space —
    /// the coordinate space the AX API uses. NS→CG conversion lives only in
    /// this file (cgArea helper).
    static var cgVisibleAreaOfMainScreen: CGRect {
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first
        else { return .zero }
        return cgArea(of: screen, primary: primary)
    }

    /// All connected displays with CG-space visible areas and human names.
    static var allDisplays: [SnapshotPlanner.Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let info = displayInfo(for: screen) else { return nil }
            return SnapshotPlanner.Display(info: info,
                                           name: screen.localizedName,
                                           visibleArea: cgArea(of: screen, primary: primary))
        }
    }

    /// Flips a screen's visible frame from NS (bottom-left origin) to CG
    /// (top-left origin) space, anchored to the primary screen.
    private static func cgArea(of screen: NSScreen, primary: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX,
                      y: primary.frame.maxY - visible.maxY,
                      width: visible.width,
                      height: visible.height)
    }

    /// Current display configuration from attached screens.
    static var currentConfiguration: DisplayConfiguration {
        DisplayConfiguration(displays: NSScreen.screens.compactMap(displayInfo(for:)))
    }

    private static func displayInfo(for screen: NSScreen) -> DisplayInfo? {
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
}
