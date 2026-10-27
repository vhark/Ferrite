import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure AX/CG geometry (top-left origin, y downward) for adding a window to a cluster.
public enum AutomaticClusterPlanner {
    public struct Window {
        public let id: Int
        public let frame: CGRect
        public let minimumSize: CGSize

        public init(id: Int, frame: CGRect,
                    minimumSize: CGSize = CGSize(width: 240, height: 160)) {
            self.id = id
            self.frame = frame
            self.minimumSize = minimumSize
        }
    }

    /// First try to attach without touching any existing member. Only if no edge
    /// fits do we pack the group again. Returns nil rather than clipping or stacking.
    public static func append(_ newcomer: Window, to cluster: [Window],
                              in bounds: CGRect, gap: CGFloat = 8) -> [Int: CGRect]? {
        guard bounds.width > 0, bounds.height > 0, gap >= 0,
              newcomer.frame.width > 0, newcomer.frame.height > 0,
              !cluster.contains(where: { $0.id == newcomer.id }),
              Set(cluster.map(\.id)).count == cluster.count else { return nil }
        let windows = cluster + [newcomer]
        guard windows.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }) else { return nil }

        if cluster.isEmpty {
            let size = newcomer.frame.size
            guard size.width <= bounds.width, size.height <= bounds.height else {
                return pack(windows, in: bounds, gap: gap)
            }
            return [newcomer.id: CGRect(x: min(max(newcomer.frame.minX, bounds.minX), bounds.maxX - size.width),
                                         y: min(max(newcomer.frame.minY, bounds.minY), bounds.maxY - size.height),
                                         width: size.width, height: size.height)]
        }

        var original = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        if valid(original, windows: windows, bounds: bounds, gap: gap) { return original }
        original.removeValue(forKey: newcomer.id)
        let existingFrames = cluster.map(\.frame)
        let size = newcomer.frame.size
        var best: CGRect?
        var bestDistance = CGFloat.infinity
        if size.width <= bounds.width, size.height <= bounds.height,
           valid(original, windows: nil, bounds: bounds, gap: gap, requireConnected: false) {
            for member in cluster {
                let other = member.frame
                // Include both endpoint alignments, the desired position, the
                // display edges, and the obstacle boundaries of other members.
                let xs = coordinates(desired: newcomer.frame.minX, size: size.width,
                                     memberStart: other.minX, memberEnd: other.maxX,
                                     boundsStart: bounds.minX, boundsEnd: bounds.maxX,
                                     obstacles: existingFrames, gap: gap, horizontal: true)
                let ys = coordinates(desired: newcomer.frame.minY, size: size.height,
                                     memberStart: other.minY, memberEnd: other.maxY,
                                     boundsStart: bounds.minY, boundsEnd: bounds.maxY,
                                     obstacles: existingFrames, gap: gap, horizontal: false)
                for x in xs {
                    for y in [other.minY - gap - size.height, other.maxY + gap] {
                        let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
                        consider(rect, existing: existingFrames, original: original, windows: windows,
                                 newcomer: newcomer, bounds: bounds, gap: gap,
                                 best: &best, bestDistance: &bestDistance)
                    }
                }
                for y in ys {
                    for x in [other.minX - gap - size.width, other.maxX + gap] {
                        let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
                        consider(rect, existing: existingFrames, original: original, windows: windows,
                                 newcomer: newcomer, bounds: bounds, gap: gap,
                                 best: &best, bestDistance: &bestDistance)
                    }
                }
            }
        }
        if let best {
            var result = original
            result[newcomer.id] = best
            return result
        }
        return pack(windows, in: bounds, gap: gap)
    }

    private static func coordinates(desired: CGFloat, size: CGFloat,
                                    memberStart: CGFloat, memberEnd: CGFloat,
                                    boundsStart: CGFloat, boundsEnd: CGFloat,
                                    obstacles: [CGRect], gap: CGFloat,
                                    horizontal: Bool) -> [CGFloat] {
        var result = [desired, memberStart, memberEnd - size,
                      boundsStart, boundsEnd - size,
                      min(max(desired, boundsStart), boundsEnd - size)]
        for obstacle in obstacles {
            let start = horizontal ? obstacle.minX : obstacle.minY
            let end = horizontal ? obstacle.maxX : obstacle.maxY
            result += [start, end - size, start - gap - size, end + gap]
        }
        return result
    }

    private static func consider(_ rect: CGRect, existing: [CGRect],
                                 original: [Int: CGRect], windows: [Window],
                                 newcomer: Window, bounds: CGRect, gap: CGFloat,
                                 best: inout CGRect?, bestDistance: inout CGFloat) {
        guard rect.minX >= bounds.minX, rect.minY >= bounds.minY,
              rect.maxX <= bounds.maxX, rect.maxY <= bounds.maxY else { return }
        var attached = false
        for other in existing {
            let overlapX = min(rect.maxX, other.maxX) - max(rect.minX, other.minX)
            let overlapY = min(rect.maxY, other.maxY) - max(rect.minY, other.minY)
            let separationX = max(rect.minX - other.maxX, other.minX - rect.maxX)
            let separationY = max(rect.minY - other.maxY, other.minY - rect.maxY)
            if overlapX > 0 && separationY < gap - 0.001 { return }
            if overlapY > 0 && separationX < gap - 0.001 { return }
            if (overlapX > 0 && abs(separationY - gap) < 0.001) ||
               (overlapY > 0 && abs(separationX - gap) < 0.001) {
                attached = true
            }
        }
        guard attached else { return }
        var candidate = original
        candidate[newcomer.id] = rect
        guard valid(candidate, windows: windows, bounds: bounds, gap: gap) else { return }
        let dx = rect.minX - newcomer.frame.minX
        let dy = rect.minY - newcomer.frame.minY
        let distance = dx * dx + dy * dy
        if distance < bestDistance {
            best = rect
            bestDistance = distance
        }
    }

    private static func pack(_ windows: [Window], in bounds: CGRect,
                             gap: CGFloat) -> [Int: CGRect]? {
        var best: [Int: CGRect]?
        var bestResize = CGFloat.infinity
        var bestMovement = CGFloat.infinity
        for vertical in [false, true] {
            let oriented = vertical ? windows.map {
                Window(id: $0.id, frame: transpose($0.frame),
                       minimumSize: CGSize(width: $0.minimumSize.height, height: $0.minimumSize.width))
            } : windows
            let area = vertical ? transpose(bounds) : bounds
            let originalBounds = oriented.dropLast().reduce(oriented[0].frame) { $0.union($1.frame) }
            // Zero uses natural-width shelves; the other candidates vary the
            // member count per shelf before any shrink is selected.
            for columns in 0...oriented.count {
                var shelves: [[Window]] = []
                if columns == 0 {
                    var row: [Window] = []
                    var width: CGFloat = 0
                    let byWidth = oriented.sorted {
                        if $0.frame.width != $1.frame.width { return $0.frame.width > $1.frame.width }
                        if $0.frame.height != $1.frame.height { return $0.frame.height > $1.frame.height }
                        return $0.id < $1.id
                    }
                    for window in byWidth {
                        if !row.isEmpty && width + gap + window.frame.width > area.width {
                            shelves.append(row)
                            row = []
                            width = 0
                        }
                        width += (row.isEmpty ? 0 : gap) + window.frame.width
                        row.append(window)
                    }
                    if !row.isEmpty { shelves.append(row) }
                } else {
                    shelves = stride(from: 0, to: oriented.count, by: columns).map {
                        Array(oriented[$0..<min($0 + columns, oriented.count)])
                    }
                }
                for index in shelves.indices {
                    shelves[index].sort { $0.frame.height > $1.frame.height }
                }
                let desiredHeights = shelves.map { row in
                    row.reduce(CGFloat.zero) { max($0, $1.frame.height) }
                }
                let minimumHeights = shelves.map { row in
                    row.reduce(CGFloat.zero) {
                        max($0, min($1.frame.height, max(0, $1.minimumSize.height)))
                    }
                }
                guard let heights = shrink(desiredHeights, minimum: minimumHeights,
                                           to: area.height - CGFloat(shelves.count - 1) * gap)
                else { continue }
                var widths: [[CGFloat]] = []
                widths.reserveCapacity(shelves.count)
                var width: CGFloat = 0
                for row in shelves {
                    let gaps = CGFloat(row.count - 1) * gap
                    guard let rowWidths = shrink(
                        row.map(\.frame.width),
                        minimum: row.map { min($0.frame.width, max(0, $0.minimumSize.width)) },
                        to: area.width - gaps)
                    else { break }
                    width = max(width, rowWidths.reduce(0, +) + gaps)
                    widths.append(rowWidths)
                }
                guard widths.count == shelves.count else { continue }
                let height = heights.reduce(0, +) + CGFloat(shelves.count - 1) * gap
                let x = min(max(originalBounds.minX, area.minX), area.maxX - width)
                var y = min(max(originalBounds.minY, area.minY), area.maxY - height)
                var frames: [Int: CGRect] = [:]
                frames.reserveCapacity(oriented.count)
                var resize: CGFloat = 0
                var movement: CGFloat = 0
                for (rowIndex, row) in shelves.enumerated() {
                    var cursor = x
                    for (column, window) in row.enumerated() {
                        let frame = CGRect(x: cursor, y: y, width: widths[rowIndex][column],
                                           height: min(window.frame.height, heights[rowIndex]))
                        frames[window.id] = frame
                        resize += window.frame.width - frame.width + window.frame.height - frame.height
                        movement += abs(frame.minX - window.frame.minX) + abs(frame.minY - window.frame.minY)
                        cursor += frame.width + gap
                    }
                    y += heights[rowIndex] + gap
                }
                guard valid(frames, windows: oriented, bounds: area, gap: gap) else { continue }
                if resize < bestResize - 0.001 ||
                    (abs(resize - bestResize) <= 0.001 && movement < bestMovement) {
                    best = vertical ? frames.mapValues(transpose) : frames
                    bestResize = resize
                    bestMovement = movement
                }
            }
        }
        return best
    }

    private static func transpose(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minY, y: frame.minX, width: frame.height, height: frame.width)
    }

    private static func shrink(_ sizes: [CGFloat], minimum: [CGFloat],
                               to available: CGFloat) -> [CGFloat]? {
        guard minimum.reduce(0, +) <= available + 0.001 else { return nil }
        var excess = sizes.reduce(0, +) - available
        guard excess > 0 else { return sizes }
        var result = sizes
        let order = sizes.indices.sorted {
            let left = sizes[$0] - minimum[$0]
            let right = sizes[$1] - minimum[$1]
            return left == right ? $0 > $1 : left > right
        }
        for index in order {
            let reduction = min(excess, result[index] - minimum[index])
            result[index] -= reduction
            excess -= reduction
            if excess <= 0 { break }
        }
        return result
    }

    private static func valid(_ frames: [Int: CGRect], windows: [Window]?,
                              bounds: CGRect, gap: CGFloat, requireConnected: Bool = true) -> Bool {
        if let windows {
            guard frames.count == windows.count else { return false }
            for window in windows {
                guard let frame = frames[window.id],
                      frame.width + 0.001 >= min(window.frame.width, max(0, window.minimumSize.width)),
                      frame.height + 0.001 >= min(window.frame.height, max(0, window.minimumSize.height)) else {
                    return false
                }
            }
        }
        let rects = Array(frames.values)
        guard rects.allSatisfy({ $0.width > 0 && $0.height > 0 &&
            $0.minX >= bounds.minX - 0.001 && $0.minY >= bounds.minY - 0.001 &&
            $0.maxX <= bounds.maxX + 0.001 && $0.maxY <= bounds.maxY + 0.001 }) else { return false }
        guard rects.count > 1 else { return true }
        var connected = Set([0])
        var joins: [(Int, Int)] = []
        for i in 0..<(rects.count - 1) {
            for j in (i + 1)..<rects.count {
                let a = rects[i], b = rects[j]
                let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                let separationX = max(b.minX - a.maxX, a.minX - b.maxX)
                let separationY = max(b.minY - a.maxY, a.minY - b.maxY)
                if overlapX > 0 && separationY < gap - 0.001 { return false }
                if overlapY > 0 && separationX < gap - 0.001 { return false }
                if (overlapX > 0 && abs(separationY - gap) < 0.001) ||
                   (overlapY > 0 && abs(separationX - gap) < 0.001) {
                    joins.append((i, j))
                }
            }
        }
        if !requireConnected { return true }
        while true {
            let previous = connected.count
            for (i, j) in joins {
                if connected.contains(i) { connected.insert(j) }
                if connected.contains(j) { connected.insert(i) }
            }
            if connected.count == previous { break }
        }
        return connected.count == rects.count
    }
}
