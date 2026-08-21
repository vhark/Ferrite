import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Applies remembered frames to an app's open windows.
/// Clamp policy: set → read back → one retry → accept. Never loop.
public final class RestoreEngine {
    public static let tolerance: CGFloat = 2.0
    private let driver: WindowDriving

    public init(driver: WindowDriving) {
        self.driver = driver
    }

    /// Returns the number of windows a placement was attempted for (clamps accepted).
    @discardableResult
    public func restore(records: [WindowRecord], bundleID: String,
                        visibleArea: CGRect) -> Int {
        guard !records.isEmpty else { return 0 }
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        // Order fallback is only safe when the app produced at least as many
        // windows as we expect. A relaunched app showing fewer (e.g. a document
        // app that restored nothing and is showing an Open dialog) must not have
        // a transient window dragged into a remembered slot.
        let allowOrderFallback = windows.count >= records.count
        let assignment = WindowMatcher.assign(records: records, to: candidates,
                                              allowOrderFallback: allowOrderFallback)
        var placed = 0
        for window in windows {
            guard let record = assignment[window.id] else { continue }
            let target = record.frame.rect(in: visibleArea)
            let achieved = driver.setFrame(target, of: window)
            if !achieved.approximatelyEquals(target, tolerance: Self.tolerance) {
                _ = driver.setFrame(target, of: window) // one retry, then accept
            }
            placed += 1
        }
        return placed
    }
}

extension CGRect {
    /// Frame comparison used by every applier: the driver's read-back frame is
    /// never bit-exact, so "did the app accept it?" is a tolerance question.
    public func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
