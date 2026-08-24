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
            apply(target: record.frame.rect(in: visibleArea), to: window)
            placed += 1
        }
        return placed
    }

    /// Places windows at ABSOLUTE target rects (the merged template path):
    /// no denormalization, same clamp policy as `restore`.
    /// Returns the number of windows a placement was attempted for.
    @discardableResult
    public func place(assignments: [(window: DriverWindow, target: CGRect)]) -> Int {
        for assignment in assignments {
            apply(target: assignment.target, to: assignment.window)
        }
        return assignments.count
    }

    /// THE clamp policy — set → read back → one retry → accept, never loop.
    /// Every placement entry funnels through here; extract, don't duplicate.
    private func apply(target: CGRect, to window: DriverWindow) {
        let achieved = driver.setFrame(target, of: window)
        if !achieved.approximatelyEquals(target, tolerance: Self.tolerance) {
            _ = driver.setFrame(target, of: window) // one retry, then accept
        }
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
