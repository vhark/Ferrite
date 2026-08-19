import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Matches AX-enumerated windows to CGWindowList entries (front-to-back) to
/// recover global stacking order. zIndex 0 = frontmost.
public enum ZOrderMatcher {
    public struct AXRef {
        public let id: Int
        public let pid: Int32
        public let frame: CGRect
        public init(id: Int, pid: Int32, frame: CGRect) {
            self.id = id; self.pid = pid; self.frame = frame
        }
    }

    public struct CGRef {
        public let pid: Int32
        public let frame: CGRect
        public init(pid: Int32, frame: CGRect) {
            self.pid = pid; self.frame = frame
        }
    }

    public static let tolerance: CGFloat = 3.0

    /// Returns AX window id → zIndex. Unmatched AX windows are appended
    /// behind all matched ones, preserving their input order.
    public static func zIndices(axWindows: [AXRef],
                                cgFrontToBack: [CGRef]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var claimedAX = Set<Int>()
        var nextIndex = 0
        for cg in cgFrontToBack {
            guard let match = axWindows.first(where: { ax in
                !claimedAX.contains(ax.id) && ax.pid == cg.pid
                    && ax.frame.approximatelyEquals(cg.frame, tolerance: Self.tolerance)
            }) else { continue }
            claimedAX.insert(match.id)
            result[match.id] = nextIndex
            nextIndex += 1
        }
        for ax in axWindows where !claimedAX.contains(ax.id) {
            result[ax.id] = nextIndex
            nextIndex += 1
        }
        return result
    }
}
