import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Propagates a shared-edge drag to the mates that share that edge.
public enum MagnetResize {
    public typealias Mode = MagnetGroup.ResizeMode

    /// Ignore sub-pixel jitter; AX frames are not exact.
    private static let epsilon: CGFloat = 0.5

    /// Returns new frames for the members that must move. `changed` is never
    /// in the result — the user already put it where they want it.
    public static func propagate(frames: [Int: CGRect],
                                 changed: Int,
                                 previous: CGRect,
                                 mode: Mode,
                                 gap: CGFloat = 8,
                                 minimumSize: CGSize = CGSize(width: 240, height: 160),
                                 adjacencyTolerance: CGFloat = 12) -> [Int: CGRect] {
        guard let now = frames[changed] else { return [:] }
        // Standard mode: the user resized one window and meant only that one.
        guard mode != .standard else { return [:] }
        // A pure translation is a mating gesture; only edge motion propagates.
        let sizeChanged = abs(now.width - previous.width) > epsilon
            || abs(now.height - previous.height) > epsilon
        guard sizeChanged else { return [:] }

        var result: [Int: CGRect] = [:]
        var live = frames
        var visited: Set<Int> = [changed]
        var queue: [(id: Int, previous: CGRect, now: CGRect)] = [(changed, previous, now)]

        while let step = queue.first {
            queue.removeFirst()
            for edge in Edge.allCases {
                let delta = edge.delta(from: step.previous, to: step.now)
                guard abs(delta) > epsilon else { continue }
                for (id, frame) in live where !visited.contains(id) {
                    guard edge.isAdjacent(step.previous, frame, gap: gap,
                                          tolerance: adjacencyTolerance) else { continue }
                    let updated: CGRect
                    switch mode {
                    case .shrink:
                        updated = edge.resizingMate(frame, toFollow: step.now,
                                                    gap: gap, minimumSize: minimumSize)
                    case .nudge:
                        updated = edge.translatingMate(frame, by: delta)
                    case .standard:
                        // Unreachable — the early guard returns first. Kept so
                        // adding a mode can never silently fall through here.
                        continue
                    }
                    visited.insert(id)
                    result[id] = updated
                    live[id] = updated
                    if mode == .nudge {
                        // A nudged window pushes its own mates.
                        queue.append((id, frame, updated))
                    }
                }
            }
        }
        return result
    }

    /// Which edge of the CHANGED window moved, described from its point of view.
    private enum Edge: CaseIterable {
        case leading, trailing, top, bottom

        var isHorizontal: Bool { self == .leading || self == .trailing }

        func delta(from previous: CGRect, to now: CGRect) -> CGFloat {
            switch self {
            case .leading: return now.minX - previous.minX
            case .trailing: return now.maxX - previous.maxX
            case .top: return now.minY - previous.minY
            case .bottom: return now.maxY - previous.maxY
            }
        }

        /// Is `mate` flush against this edge of `subject`?
        func isAdjacent(_ subject: CGRect, _ mate: CGRect,
                        gap: CGFloat, tolerance: CGFloat) -> Bool {
            let facing: CGFloat
            switch self {
            case .trailing: facing = abs(mate.minX - subject.maxX - gap)
            case .leading: facing = abs(subject.minX - mate.maxX - gap)
            case .bottom: facing = abs(mate.minY - subject.maxY - gap)
            case .top: facing = abs(subject.minY - mate.maxY - gap)
            }
            guard facing <= tolerance else { return false }
            if isHorizontal {
                return min(subject.maxY, mate.maxY) - max(subject.minY, mate.minY) > 0
            }
            return min(subject.maxX, mate.maxX) - max(subject.minX, mate.minX) > 0
        }

        /// Mate keeps its far edge and follows the shared one.
        func resizingMate(_ mate: CGRect, toFollow subject: CGRect,
                          gap: CGFloat, minimumSize: CGSize) -> CGRect {
            switch self {
            case .trailing:
                let x = subject.maxX + gap
                return CGRect(x: x, y: mate.minY,
                              width: max(minimumSize.width, mate.maxX - x),
                              height: mate.height)
            case .leading:
                let maxX = subject.minX - gap
                let width = max(minimumSize.width, maxX - mate.minX)
                return CGRect(x: maxX - width, y: mate.minY,
                              width: width, height: mate.height)
            case .bottom:
                let y = subject.maxY + gap
                return CGRect(x: mate.minX, y: y, width: mate.width,
                              height: max(minimumSize.height, mate.maxY - y))
            case .top:
                let maxY = subject.minY - gap
                let height = max(minimumSize.height, maxY - mate.minY)
                return CGRect(x: mate.minX, y: maxY - height,
                              width: mate.width, height: height)
            }
        }

        func translatingMate(_ mate: CGRect, by delta: CGFloat) -> CGRect {
            isHorizontal ? mate.offsetBy(dx: delta, dy: 0)
                         : mate.offsetBy(dx: 0, dy: delta)
        }
    }
}
