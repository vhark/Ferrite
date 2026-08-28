import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Scales a magnet group as one combined window when an outer edge is dragged.
///
/// Settle-on-release: during the drag macOS gives the dragged window the full
/// delta; correcting it mid-drag fights the user's grip. On mouse-up every
/// member — the dragged window included — is remapped to its proportional
/// share of the new bounding box. Per-axis: an axis participates only when an
/// outer edge on it moved, and non-participating axes keep their release-time
/// values so a live shared-edge adjustment made during the same drag survives.
public enum MagnetScale {
    private static let epsilon: CGFloat = 0.5

    /// True when any edge of `frame` is flush against `other` — the same
    /// adjacency semantics as resize propagation and outer-edge
    /// classification, exposed so membership decisions never re-derive
    /// geometry.
    public static func isAdjacent(_ frame: CGRect, to other: CGRect,
                                  gap: CGFloat = 8,
                                  tolerance: CGFloat = 12) -> Bool {
        let all: [MagnetMating.Edge] = [.left, .right, .top, .bottom]
        return all.contains {
            isFlush(frame, other, edge: $0, gap: gap, tolerance: tolerance)
        }
    }

    /// Edges of `frame` that no mate is flush against. Same adjacency
    /// semantics as `MagnetResize`: facing edges within `gap + tolerance` and
    /// overlapping perpendicular extents.
    public static func outerEdges(of frame: CGRect, among mates: [CGRect],
                                  gap: CGFloat = 8,
                                  tolerance: CGFloat = 12) -> Set<MagnetMating.Edge> {
        let all: [MagnetMating.Edge] = [.left, .right, .top, .bottom]
        return Set(all.filter { edge in
            !mates.contains { isFlush(frame, $0, edge: edge, gap: gap, tolerance: tolerance) }
        })
    }

    private static func isFlush(_ subject: CGRect, _ mate: CGRect,
                                edge: MagnetMating.Edge,
                                gap: CGFloat, tolerance: CGFloat) -> Bool {
        let facing: CGFloat
        switch edge {
        case .right: facing = abs(mate.minX - subject.maxX - gap)
        case .left: facing = abs(subject.minX - mate.maxX - gap)
        case .bottom: facing = abs(mate.minY - subject.maxY - gap)
        case .top: facing = abs(subject.minY - mate.maxY - gap)
        }
        guard facing <= tolerance else { return false }
        if edge == .left || edge == .right {
            return min(subject.maxY, mate.maxY) - max(subject.minY, mate.minY) > 0
        }
        return min(subject.maxX, mate.maxX) - max(subject.minX, mate.minX) > 0
    }

    /// Frames that must move so the group scales as one window. `changed` may
    /// itself appear in the result: its proportional share is smaller than the
    /// full delta macOS gave it during the drag.
    public static func settle(startFrames: [Int: CGRect],
                              releaseFrames: [Int: CGRect],
                              changed: Int,
                              outerEdges: Set<MagnetMating.Edge>,
                              minimumSize: CGSize = CGSize(width: 240, height: 160))
        -> [Int: CGRect] {
        guard startFrames.count > 1,
              let start = startFrames[changed],
              let release = releaseFrames[changed] else { return [:] }

        var bbox = start
        for frame in startFrames.values { bbox = bbox.union(frame) }

        // Outer-edge deltas only; shared edges belong to live propagation.
        let dLeft = outerEdges.contains(.left) ? release.minX - start.minX : 0
        let dRight = outerEdges.contains(.right) ? release.maxX - start.maxX : 0
        let dTop = outerEdges.contains(.top) ? release.minY - start.minY : 0
        let dBottom = outerEdges.contains(.bottom) ? release.maxY - start.maxY : 0
        let scaleX = abs(dLeft) > epsilon || abs(dRight) > epsilon
        let scaleY = abs(dTop) > epsilon || abs(dBottom) > epsilon
        guard scaleX || scaleY else { return [:] }

        let newWidth = bbox.width + dRight - dLeft
        let newHeight = bbox.height + dBottom - dTop
        // A window cannot invert. Refuse a degenerate extent outright rather
        // than emitting negative frames; per-member floors handle mere shrinks.
        guard newWidth > minimumSize.width, newHeight > minimumSize.height else { return [:] }
        let fx = newWidth / bbox.width
        let fy = newHeight / bbox.height

        var result: [Int: CGRect] = [:]
        for (id, startFrame) in startFrames {
            let current = releaseFrames[id] ?? startFrame
            var target = current
            if scaleX {
                target.origin.x = bbox.minX + dLeft + (startFrame.minX - bbox.minX) * fx
                target.size.width = max(minimumSize.width, startFrame.width * fx)
            }
            if scaleY {
                target.origin.y = bbox.minY + dTop + (startFrame.minY - bbox.minY) * fy
                target.size.height = max(minimumSize.height, startFrame.height * fy)
            }
            let moved = abs(target.minX - current.minX) > epsilon
                || abs(target.minY - current.minY) > epsilon
                || abs(target.width - current.width) > epsilon
                || abs(target.height - current.height) > epsilon
            if moved { result[id] = target }
        }
        return result
    }

    /// Proportionally remaps frames from one bounding box into another —
    /// display reflow's keep-groups path: the solver places the group's box,
    /// this carries the mated formation into it. Pure geometry; the caller
    /// owns minimum-size policy (the solver already clamped the target box).
    public static func remap(frames: [Int: CGRect], from source: CGRect,
                             to target: CGRect) -> [Int: CGRect] {
        guard source.width > 0, source.height > 0 else { return frames }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return frames.mapValues { frame in
            CGRect(x: target.minX + (frame.minX - source.minX) * scaleX,
                   y: target.minY + (frame.minY - source.minY) * scaleY,
                   width: frame.width * scaleX,
                   height: frame.height * scaleY)
        }
    }
}
