import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A window as reported by a platform driver. Frames are CG space (top-left).
///
/// `title` is live: pin matching and UI display, in-memory only. `titleHash` is
/// the opaque identity the app layer computed for it, and the only one of the
/// two that may ever reach disk. `pid` is the owning process, which the z-order
/// matcher needs to pair a driver window with its CGWindowList entry.
public struct DriverWindow: Equatable {
    public let id: Int       // stable for a window's lifetime
    public let pid: pid_t
    public let title: String
    public let titleHash: String?
    public let frame: CGRect

    public init(id: Int, pid: pid_t, title: String, titleHash: String?,
                frame: CGRect) {
        self.id = id; self.pid = pid; self.title = title
        self.titleHash = titleHash; self.frame = frame
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
