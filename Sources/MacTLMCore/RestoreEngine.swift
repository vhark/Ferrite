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
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        let assignment = WindowMatcher.assign(records: records, to: candidates)
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
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
