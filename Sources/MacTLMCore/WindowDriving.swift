import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A window as reported by a platform driver. Frames are CG space (top-left).
public struct DriverWindow: Equatable {
    public let id: Int       // stable for a window's lifetime
    public let title: String
    public let frame: CGRect

    public init(id: Int, title: String, frame: CGRect) {
        self.id = id; self.title = title; self.frame = frame
    }
}

/// Platform seam. macOS implements with AX; Linux later with
/// sway/Hyprland IPC or EWMH.
public protocol WindowDriving: AnyObject {
    /// Current windows of a running app, frontmost first.
    func windows(ofBundleID bundleID: String) -> [DriverWindow]
    /// Sets a frame and returns the frame the app actually accepted.
    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect
}
