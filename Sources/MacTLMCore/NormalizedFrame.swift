import CoreGraphics
import Foundation

/// A window frame stored as fractions (0–1) of a display's visible area.
/// `windowFrame` and `visibleArea` must share one coordinate space (CG space
/// everywhere in MacTLM).
public struct NormalizedFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public init(windowFrame: CGRect, visibleArea: CGRect) {
        precondition(visibleArea.width > 0 && visibleArea.height > 0)
        x = (windowFrame.minX - visibleArea.minX) / visibleArea.width
        y = (windowFrame.minY - visibleArea.minY) / visibleArea.height
        w = windowFrame.width / visibleArea.width
        h = windowFrame.height / visibleArea.height
    }

    public func rect(in visibleArea: CGRect) -> CGRect {
        CGRect(x: visibleArea.minX + x * visibleArea.width,
               y: visibleArea.minY + y * visibleArea.height,
               width: w * visibleArea.width,
               height: h * visibleArea.height)
    }
}
