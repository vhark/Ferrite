import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a window's chrome sits inside its frame.
///
/// Pure geometry so the hit tests that decide "the user grabbed the title bar"
/// are testable without a window server. CG space throughout: the title bar is
/// the band at the TOP of the frame, which is the low-y end.
public enum WindowChrome {
    /// Standard macOS title bar height. Apps with tall unified toolbars also
    /// zoom on a double-click anywhere in that toolbar, but 28pt is the band we
    /// can assert without guessing per-app chrome.
    public static let titleBarHeight: CGFloat = 28

    /// The title bar band of `frame`, clamped so a very short window cannot
    /// report a band taller than itself.
    public static func titleBar(of frame: CGRect,
                                height: CGFloat = titleBarHeight) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: frame.width, height: min(height, frame.height))
    }

    public static func isInTitleBar(_ point: CGPoint, of frame: CGRect,
                                    height: CGFloat = titleBarHeight) -> Bool {
        titleBar(of: frame, height: height).contains(point)
    }
}
