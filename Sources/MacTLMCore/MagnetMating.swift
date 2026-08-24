import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Decides whether a just-dropped window mates with a neighbour, and where it
/// should land. Pure geometry in AX/CG space (origin top-left, y downward).
public enum MagnetMating {
    /// Which edge OF THE DRAGGED WINDOW meets the mate.
    public enum Edge: String, Codable, Equatable {
        case left, right, top, bottom

        var isHorizontal: Bool { self == .left || self == .right }
    }

    public struct Candidate: Equatable {
        public let mateID: Int
        public let edge: Edge
        public let snapped: CGRect
        public let distance: CGFloat
    }

    /// How near facing edges must be, in points, before they mate.
    public static let defaultThreshold: CGFloat = 24
    /// How much the perpendicular extents must overlap, as a fraction of the
    /// shorter side. Stops a corner graze from counting as a mate.
    public static let defaultMinimumOverlap: Double = 0.25

    public static func candidate(dragged: CGRect,
                                 others: [(id: Int, frame: CGRect)],
                                 threshold: CGFloat = defaultThreshold,
                                 minimumOverlap: Double = defaultMinimumOverlap,
                                 gap: CGFloat = 8) -> Candidate? {
        var best: Candidate?
        for other in others {
            for edge in [Edge.right, .left, .bottom, .top] {
                let distance = facingDistance(dragged, other.frame, edge: edge)
                guard distance <= threshold,
                      overlapFraction(dragged, other.frame, edge: edge) >= minimumOverlap
                else { continue }
                let snapped = snap(dragged, to: other.frame, edge: edge,
                                   gap: gap, threshold: threshold)
                if best == nil || distance < best!.distance {
                    best = Candidate(mateID: other.id, edge: edge,
                                     snapped: snapped, distance: distance)
                }
            }
        }
        return best
    }

    /// Gap between the dragged window's `edge` and the mate's facing edge.
    private static func facingDistance(_ dragged: CGRect, _ other: CGRect,
                                       edge: Edge) -> CGFloat {
        switch edge {
        case .right: return abs(other.minX - dragged.maxX)
        case .left: return abs(dragged.minX - other.maxX)
        case .bottom: return abs(other.minY - dragged.maxY)
        case .top: return abs(dragged.minY - other.maxY)
        }
    }

    /// Shared extent along the axis perpendicular to the mating edge, as a
    /// fraction of the shorter of the two sides.
    private static func overlapFraction(_ a: CGRect, _ b: CGRect, edge: Edge) -> Double {
        if edge.isHorizontal {
            let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let shorter = min(a.height, b.height)
            guard shorter > 0 else { return 0 }
            return Double(max(0, shared) / shorter)
        }
        let shared = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let shorter = min(a.width, b.width)
        guard shorter > 0 else { return 0 }
        return Double(max(0, shared) / shorter)
    }

    /// Flush against the mate, plus perpendicular alignment when the user was
    /// already close to level. Deliberate offsets are preserved.
    private static func snap(_ dragged: CGRect, to other: CGRect, edge: Edge,
                             gap: CGFloat, threshold: CGFloat) -> CGRect {
        var origin = dragged.origin
        switch edge {
        case .right: origin.x = other.minX - gap - dragged.width
        case .left: origin.x = other.maxX + gap
        case .bottom: origin.y = other.minY - gap - dragged.height
        case .top: origin.y = other.maxY + gap
        }
        if edge.isHorizontal {
            if abs(dragged.minY - other.minY) <= threshold {
                origin.y = other.minY
            } else if abs(dragged.maxY - other.maxY) <= threshold {
                origin.y = other.maxY - dragged.height
            }
        } else {
            if abs(dragged.minX - other.minX) <= threshold {
                origin.x = other.minX
            } else if abs(dragged.maxX - other.maxX) <= threshold {
                origin.x = other.maxX - dragged.width
            }
        }
        return CGRect(origin: origin, size: dragged.size)
    }
}
