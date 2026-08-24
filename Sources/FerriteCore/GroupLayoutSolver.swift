import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Maps weighted tiles onto non-overlapping rects inside a bounding box.
///
/// Pure geometry: no window, display or AppKit types. The macOS layer decides
/// which windows form a group and what their weights are; this decides where
/// they go, so the same solver serves a future Linux port unchanged.
public enum GroupLayoutSolver {
    /// One member of the group. `weight` drives area in weighted presets and is
    /// ignored by the even ones. Must be > 0.
    public struct Tile: Equatable {
        public let id: Int
        public let weight: Double

        public init(id: Int, weight: Double) {
            self.id = id
            self.weight = max(weight, .leastNonzeroMagnitude)
        }
    }

    public enum Preset: Equatable {
        case columns
        case rows
        case grid
        case mainSide
        case symmetric
        case treemap(bias: TreemapBias)

        /// The presets that ignore weights — used by exhaustive tests.
        public static let allBasicCases: [Preset] = [.columns, .rows, .grid,
                                                     .mainSide, .symmetric]
    }

    public enum TreemapBias: Equatable {
        case center
        case left
        case right
    }

    /// Solved frames keyed by tile id. `gap` is the total spacing between
    /// neighbours; each tile is inset by half of it, so the group's outer edge
    /// still touches `bounds`. Tiles smaller than `minimumSize` are grown last.
    public static func solve(tiles: [Tile], preset: Preset,
                            in bounds: CGRect, gap: CGFloat,
                            minimumSize: CGSize = .zero) -> [Int: CGRect] {
        guard !tiles.isEmpty, bounds.width > 0, bounds.height > 0 else { return [:] }
        guard tiles.count > 1 else {
            return clamp([tiles[0].id: applyGap(bounds, gap: gap, bounds: bounds)],
                         to: minimumSize, bounds: bounds)
        }
        let raw: [Int: CGRect]
        switch preset {
        case .columns:
            raw = strips(tiles, in: bounds, vertical: true)
        case .rows:
            raw = strips(tiles, in: bounds, vertical: false)
        case .grid:
            raw = grid(tiles, in: bounds)
        case .mainSide:
            raw = mainSide(tiles, in: bounds)
        case .symmetric:
            // PRD §3.3: symmetric is the treemap's equal-weights case.
            raw = partition(tiles.map { Tile(id: $0.id, weight: 1) }, in: bounds)
        case .treemap(let bias):
            raw = treemap(tiles, in: bounds, bias: bias)
        }
        return clamp(raw.mapValues { applyGap($0, gap: gap, bounds: bounds) },
                     to: minimumSize, bounds: bounds)
    }

    // MARK: - Even presets

    private static func strips(_ tiles: [Tile], in bounds: CGRect,
                              vertical: Bool) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        let span = (vertical ? bounds.width : bounds.height) / CGFloat(tiles.count)
        for (index, tile) in tiles.enumerated() {
            let offset = span * CGFloat(index)
            result[tile.id] = vertical
                ? CGRect(x: bounds.minX + offset, y: bounds.minY,
                         width: span, height: bounds.height)
                : CGRect(x: bounds.minX, y: bounds.minY + offset,
                         width: bounds.width, height: span)
        }
        return result
    }

    private static func grid(_ tiles: [Tile], in bounds: CGRect) -> [Int: CGRect] {
        let columns = Int(ceil(Double(tiles.count).squareRoot()))
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        var result: [Int: CGRect] = [:]
        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            result[tile.id] = CGRect(x: bounds.minX + cellWidth * CGFloat(column),
                                     y: bounds.minY + cellHeight * CGFloat(row),
                                     width: cellWidth, height: cellHeight)
        }
        return result
    }

    /// Heaviest tile takes 60% on the left; the rest stack down the right.
    private static func mainSide(_ tiles: [Tile], in bounds: CGRect) -> [Int: CGRect] {
        let ordered = tiles.sorted { $0.weight > $1.weight }
        let mainWidth = bounds.width * 0.6
        var result = [ordered[0].id: CGRect(x: bounds.minX, y: bounds.minY,
                                            width: mainWidth, height: bounds.height)]
        let sideBounds = CGRect(x: bounds.minX + mainWidth, y: bounds.minY,
                                width: bounds.width - mainWidth, height: bounds.height)
        for (id, rect) in strips(Array(ordered.dropFirst()), in: sideBounds,
                                 vertical: false) {
            result[id] = rect
        }
        return result
    }

    // MARK: - Weighted presets (Task 2 / Task 3)

    /// Recursively splits `bounds` along its longer axis, giving each side a
    /// share equal to its weight. Because every split is proportional, a tile's
    /// final area is its weight share of the whole box — which is what makes
    /// the treemap verifiable by arithmetic.
    private static func partition(_ tiles: [Tile], in bounds: CGRect) -> [Int: CGRect] {
        guard tiles.count > 1 else {
            return tiles.isEmpty ? [:] : [tiles[0].id: bounds]
        }
        let ordered = tiles.sorted { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.id < rhs.id : lhs.weight > rhs.weight
        }
        let total = ordered.reduce(0.0) { $0 + $1.weight }
        // Greedy prefix closest to half the weight, always leaving both sides
        // non-empty so the recursion terminates.
        var accumulated = 0.0
        var splitIndex = 1
        for (index, tile) in ordered.enumerated() {
            accumulated += tile.weight
            if accumulated >= total / 2 {
                splitIndex = min(max(index + 1, 1), ordered.count - 1)
                break
            }
        }
        let head = Array(ordered[..<splitIndex])
        let tail = Array(ordered[splitIndex...])
        let headWeight = head.reduce(0.0) { $0 + $1.weight }
        let fraction = CGFloat(headWeight / total)

        let headBounds: CGRect
        let tailBounds: CGRect
        if bounds.width >= bounds.height {
            let cut = bounds.width * fraction
            headBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                width: cut, height: bounds.height)
            tailBounds = CGRect(x: bounds.minX + cut, y: bounds.minY,
                                width: bounds.width - cut, height: bounds.height)
        } else {
            let cut = bounds.height * fraction
            headBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                width: bounds.width, height: cut)
            tailBounds = CGRect(x: bounds.minX, y: bounds.minY + cut,
                                width: bounds.width, height: bounds.height - cut)
        }
        return partition(head, in: headBounds)
            .merging(partition(tail, in: tailBounds)) { first, _ in first }
    }

    /// The heaviest tile becomes a full-height band anchored per `bias`; the
    /// remaining tiles are dealt alternately into the leftover space so the
    /// two sides stay close in weight, then partitioned within it.
    private static func treemap(_ tiles: [Tile], in bounds: CGRect,
                               bias: TreemapBias) -> [Int: CGRect] {
        let ordered = tiles.sorted { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.id < rhs.id : lhs.weight > rhs.weight
        }
        guard let heaviest = ordered.first else { return [:] }
        let rest = Array(ordered.dropFirst())
        guard !rest.isEmpty else { return [heaviest.id: bounds] }

        let total = ordered.reduce(0.0) { $0 + $1.weight }
        let bandWidth = bounds.width * CGFloat(heaviest.weight / total)

        switch bias {
        case .left:
            let band = CGRect(x: bounds.minX, y: bounds.minY,
                              width: bandWidth, height: bounds.height)
            let remainder = CGRect(x: band.maxX, y: bounds.minY,
                                   width: bounds.width - bandWidth,
                                   height: bounds.height)
            return partition(rest, in: remainder)
                .merging([heaviest.id: band]) { first, _ in first }
        case .right:
            let band = CGRect(x: bounds.maxX - bandWidth, y: bounds.minY,
                              width: bandWidth, height: bounds.height)
            let remainder = CGRect(x: bounds.minX, y: bounds.minY,
                                   width: bounds.width - bandWidth,
                                   height: bounds.height)
            return partition(rest, in: remainder)
                .merging([heaviest.id: band]) { first, _ in first }
        case .center:
            // Deal heaviest-first alternately so both sides carry similar weight.
            var leftTiles: [Tile] = []
            var rightTiles: [Tile] = []
            for (index, tile) in rest.enumerated() {
                if index.isMultiple(of: 2) { leftTiles.append(tile) }
                else { rightTiles.append(tile) }
            }
            let leftWeight = leftTiles.reduce(0.0) { $0 + $1.weight }
            let rightWeight = rightTiles.reduce(0.0) { $0 + $1.weight }
            let sideWidth = bounds.width - bandWidth
            let leftShare = (leftWeight + rightWeight) > 0
                ? CGFloat(leftWeight / (leftWeight + rightWeight)) : 0.5
            let leftWidth = sideWidth * leftShare
            var result: [Int: CGRect] = [:]
            if !leftTiles.isEmpty {
                result.merge(partition(leftTiles,
                                       in: CGRect(x: bounds.minX, y: bounds.minY,
                                                  width: leftWidth,
                                                  height: bounds.height))) { a, _ in a }
            }
            result[heaviest.id] = CGRect(x: bounds.minX + leftWidth, y: bounds.minY,
                                         width: bandWidth, height: bounds.height)
            if !rightTiles.isEmpty {
                result.merge(partition(rightTiles,
                                       in: CGRect(x: bounds.minX + leftWidth + bandWidth,
                                                  y: bounds.minY,
                                                  width: sideWidth - leftWidth,
                                                  height: bounds.height))) { a, _ in a }
            }
            return result
        }
    }

    // MARK: - Gap

    private static func applyGap(_ rect: CGRect, gap: CGFloat,
                                bounds: CGRect) -> CGRect {
        guard gap > 0 else { return rect }
        let inset = gap / 2
        let gapped = rect.insetBy(dx: inset, dy: inset)
        guard gapped.width > 1, gapped.height > 1 else { return rect }
        return gapped
    }

    // MARK: - Minimum size

    /// Grows any tile below `minimumSize`, keeping it inside `bounds`.
    /// Overlap is accepted here: an unusably thin window is worse than two
    /// windows sharing pixels (PRD §8's stated mitigation).
    private static func clamp(_ rects: [Int: CGRect], to minimumSize: CGSize,
                             bounds: CGRect) -> [Int: CGRect] {
        guard minimumSize.width > 0 || minimumSize.height > 0 else { return rects }
        return rects.mapValues { rect in
            let width = min(max(rect.width, minimumSize.width), bounds.width)
            let height = min(max(rect.height, minimumSize.height), bounds.height)
            var adjusted = CGRect(x: rect.minX, y: rect.minY,
                                  width: width, height: height)
            if adjusted.maxX > bounds.maxX { adjusted.origin.x = bounds.maxX - width }
            if adjusted.maxY > bounds.maxY { adjusted.origin.y = bounds.maxY - height }
            adjusted.origin.x = max(adjusted.origin.x, bounds.minX)
            adjusted.origin.y = max(adjusted.origin.y, bounds.minY)
            return adjusted
        }
    }
}
