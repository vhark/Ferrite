# M3a — Preset Reflow Solvers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One action reflows a display's windows into a chosen preset — columns, rows, grid, main+side, symmetric, or the weighted treemap with center/left/right bias.

**Architecture:** All geometry lives in `MacTLMCore` as a pure solver (`GroupLayoutSolver`) that maps weighted tiles to rects inside a bounding box — no AppKit, fully unit-tested, and the same code a future Linux port would use. The macOS layer resolves which windows form the group, converts z-order into weights, and applies the solved rects through the existing driver.

**Tech Stack:** Swift 5.9 mode, XCTest, AppKit (menu + glyph drawing only).

## Scope decisions, stated plainly

- **No explicit magnet groups yet.** PRD §3.3 defines a group as windows the user mated by dragging. Drag-mating is M3b, so M3a operates on an **implicit display group**: every eligible window on one display (standard subrole, not minimized, app not excluded, MacTLM itself skipped). This ships the treemap without waiting for the interaction layer.
- **Weights come from z-order**, frontmost = heaviest. PRD §3.3 specifies manual rank for v1 with frecency later; z-order is the zero-setup approximation of "what I'm working on gets the most space". Manual weights land in M3b alongside real groups.
- **Which display?** The one containing the frontmost eligible window. Predictable with two monitors and needs no picker.
- **Reflow is a normal window move.** No capture suppression: after a reflow the tracker records the new frames, which is what a user expects (the reflow becomes the remembered arrangement).

**Deliberately excluded from M3a:** drag-to-mate, shared-edge resize, per-window manual weights, Tier-2 structural reflow of saved layouts on foreign displays (PRD §3.3's last bullet — it needs real groups first).

**Spec:** PRD §3.3 (preset reflows, treemap bias, symmetric-as-equal-weights) and §4 (menu glyph row). Findings: `docs/BACKLOG.md`.

---

### Task 1: Solver core — columns, rows, grid, gaps

**Files:**
- Create: `Sources/MacTLMCore/GroupLayoutSolver.swift`
- Create: `Tests/MacTLMCoreTests/GroupLayoutSolverBasicTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/GroupLayoutSolverBasicTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class GroupLayoutSolverBasicTests: XCTestCase {
    let bounds = CGRect(x: 100, y: 50, width: 1200, height: 800)

    private func tiles(_ count: Int) -> [GroupLayoutSolver.Tile] {
        (0..<count).map { GroupLayoutSolver.Tile(id: $0, weight: 1) }
    }

    func testColumnsSplitsWidthEvenly() {
        let result = GroupLayoutSolver.solve(tiles: tiles(3), preset: .columns,
                                            in: bounds, gap: 0)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]!.minX, 100, accuracy: 0.01)
        XCTAssertEqual(result[0]!.width, 400, accuracy: 0.01)
        XCTAssertEqual(result[1]!.minX, 500, accuracy: 0.01)
        XCTAssertEqual(result[2]!.maxX, 1300, accuracy: 0.01)
        XCTAssertTrue(result.values.allSatisfy { $0.height == 800 })
    }

    func testRowsSplitsHeightEvenly() {
        let result = GroupLayoutSolver.solve(tiles: tiles(4), preset: .rows,
                                            in: bounds, gap: 0)
        XCTAssertTrue(result.values.allSatisfy { abs($0.width - 1200) < 0.01 })
        XCTAssertEqual(result[0]!.height, 200, accuracy: 0.01)
        XCTAssertEqual(result[3]!.maxY, 850, accuracy: 0.01)
    }

    func testGridUsesCeilSqrtColumns() {
        // 5 tiles -> 3 columns x 2 rows, last row short.
        let result = GroupLayoutSolver.solve(tiles: tiles(5), preset: .grid,
                                            in: bounds, gap: 0)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0]!.width, 400, accuracy: 0.01)
        XCTAssertEqual(result[0]!.height, 400, accuracy: 0.01)
        XCTAssertEqual(result[4]!.minY, 450, accuracy: 0.01)
    }

    func testSingleTileFillsBounds() {
        let result = GroupLayoutSolver.solve(tiles: tiles(1), preset: .grid,
                                            in: bounds, gap: 0)
        XCTAssertEqual(result[0]!, bounds)
    }

    func testEmptyTilesYieldsEmptyResult() {
        XCTAssertTrue(GroupLayoutSolver.solve(tiles: [], preset: .grid,
                                              in: bounds, gap: 0).isEmpty)
    }

    func testGapShrinksTilesWithoutLeavingBounds() {
        let result = GroupLayoutSolver.solve(tiles: tiles(2), preset: .columns,
                                            in: bounds, gap: 20)
        XCTAssertTrue(result.values.allSatisfy { bounds.insetBy(dx: -0.01, dy: -0.01).contains($0) })
        XCTAssertEqual(result[0]!.width, 580, accuracy: 0.01) // 600 - 20
        // No overlap once gapped.
        XCTAssertLessThanOrEqual(result[0]!.maxX, result[1]!.minX + 0.01)
    }

    func testAllPresetsStayInsideBoundsAndNeverOverlap() {
        for preset in GroupLayoutSolver.Preset.allBasicCases {
            for count in 1...7 {
                let result = GroupLayoutSolver.solve(tiles: tiles(count),
                                                     preset: preset,
                                                     in: bounds, gap: 4)
                XCTAssertEqual(result.count, count, "\(preset) with \(count)")
                for rect in result.values {
                    XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                                  "\(preset)/\(count): \(rect) escaped bounds")
                    XCTAssertGreaterThan(rect.width, 0)
                    XCTAssertGreaterThan(rect.height, 0)
                }
                let rects = Array(result.values)
                for i in rects.indices {
                    for j in (i + 1)..<rects.count {
                        let overlap = rects[i].intersection(rects[j])
                        XCTAssertTrue(overlap.isNull || overlap.width < 0.5
                                      || overlap.height < 0.5,
                                      "\(preset)/\(count): overlap \(overlap)")
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'GroupLayoutSolver' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/GroupLayoutSolver.swift`:
```swift
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
    /// still touches `bounds`.
    public static func solve(tiles: [Tile], preset: Preset,
                            in bounds: CGRect, gap: CGFloat) -> [Int: CGRect] {
        guard !tiles.isEmpty, bounds.width > 0, bounds.height > 0 else { return [:] }
        guard tiles.count > 1 else { return [tiles[0].id: applyGap(bounds, gap: gap,
                                                                  bounds: bounds)] }
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
        return raw.mapValues { applyGap($0, gap: gap, bounds: bounds) }
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

    // MARK: - Gap

    private static func applyGap(_ rect: CGRect, gap: CGFloat,
                                bounds: CGRect) -> CGRect {
        guard gap > 0 else { return rect }
        let inset = gap / 2
        let gapped = rect.insetBy(dx: inset, dy: inset)
        guard gapped.width > 1, gapped.height > 1 else { return rect }
        return gapped
    }
}
```
`partition` and `treemap` arrive in Task 3; until then the `symmetric` and `treemap` cases will not compile. To keep Task 1 self-contained, add temporary stubs that `fatalError("implemented in Task 3")` **and exclude `.symmetric` from `allBasicCases` until Task 3 lands** — then restore it. Report which order you chose.

- [ ] **Step 4: Run `swift test`** — PASS (7 new; 143 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/GroupLayoutSolver.swift Tests/MacTLMCoreTests/GroupLayoutSolverBasicTests.swift
git commit -m "feat: group layout solver with columns, rows, grid and main+side"
```

---

### Task 2: Weighted binary partition

The engine underneath both `symmetric` and `treemap`: recursively split the box along its longer axis in proportion to weight. Exact area proportionality falls out, which makes the treemap testable by arithmetic rather than by eye.

**Files:**
- Modify: `Sources/MacTLMCore/GroupLayoutSolver.swift`
- Create: `Tests/MacTLMCoreTests/GroupLayoutPartitionTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/GroupLayoutPartitionTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class GroupLayoutPartitionTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func testAreaIsProportionalToWeight() {
        let tiles = [GroupLayoutSolver.Tile(id: 1, weight: 6),
                     GroupLayoutSolver.Tile(id: 2, weight: 3),
                     GroupLayoutSolver.Tile(id: 3, weight: 1)]
        let result = GroupLayoutSolver.solve(tiles: tiles, preset: .symmetric,
                                            in: bounds, gap: 0)
        // .symmetric equalises weights, so all three areas match.
        let areas = result.values.map { $0.width * $0.height }
        XCTAssertEqual(areas.max()! / areas.min()!, 1, accuracy: 0.01)
    }

    func testTreemapAreaTracksWeightShare() {
        let tiles = [GroupLayoutSolver.Tile(id: 1, weight: 8),
                     GroupLayoutSolver.Tile(id: 2, weight: 4),
                     GroupLayoutSolver.Tile(id: 3, weight: 2),
                     GroupLayoutSolver.Tile(id: 4, weight: 2)]
        let result = GroupLayoutSolver.solve(tiles: tiles, preset: .treemap(bias: .left),
                                            in: bounds, gap: 0)
        let total = bounds.width * bounds.height
        let totalWeight = 16.0
        for tile in tiles {
            let area = Double(result[tile.id]!.width * result[tile.id]!.height)
            XCTAssertEqual(area / Double(total), tile.weight / totalWeight,
                           accuracy: 0.02, "tile \(tile.id) area share")
        }
    }

    func testWeightMonotonicity() {
        let tiles = (1...6).map { GroupLayoutSolver.Tile(id: $0, weight: Double($0)) }
        let result = GroupLayoutSolver.solve(tiles: tiles,
                                            preset: .treemap(bias: .center),
                                            in: bounds, gap: 0)
        let areas = tiles.map { ($0.weight, result[$0.id]!.width * result[$0.id]!.height) }
        for (lighter, heavier) in zip(areas, areas.dropFirst()) {
            XCTAssertLessThanOrEqual(lighter.1, heavier.1 + 1,
                                     "heavier tile must not get less area")
        }
    }

    func testPartitionFillsBoundsExactlyWithoutGap() {
        let tiles = (1...5).map { GroupLayoutSolver.Tile(id: $0, weight: Double($0)) }
        let result = GroupLayoutSolver.solve(tiles: tiles, preset: .symmetric,
                                            in: bounds, gap: 0)
        let summed = result.values.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(summed, Double(bounds.width * bounds.height), accuracy: 1.0)
    }

    func testDeterministic() {
        let tiles = (1...5).map { GroupLayoutSolver.Tile(id: $0, weight: Double(6 - $0)) }
        let a = GroupLayoutSolver.solve(tiles: tiles, preset: .treemap(bias: .center),
                                       in: bounds, gap: 2)
        let b = GroupLayoutSolver.solve(tiles: tiles, preset: .treemap(bias: .center),
                                        in: bounds, gap: 2)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL (missing `partition`, or the Task 1 stub's `fatalError`).

- [ ] **Step 3: Implement**

Add to `GroupLayoutSolver`:
```swift
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
```
Remove the Task 1 stub for `.symmetric` and restore it to `allBasicCases`.

- [ ] **Step 4: Run `swift test`** — PASS (5 new; 148 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/GroupLayoutSolver.swift Tests/MacTLMCoreTests/GroupLayoutPartitionTests.swift
git commit -m "feat: weight-proportional binary partition behind symmetric preset"
```

---

### Task 3: Weighted treemap with center/left/right bias

**Files:**
- Modify: `Sources/MacTLMCore/GroupLayoutSolver.swift`
- Create: `Tests/MacTLMCoreTests/GroupLayoutTreemapTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/GroupLayoutTreemapTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class GroupLayoutTreemapTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 3000, height: 1000)

    private var weighted: [GroupLayoutSolver.Tile] {
        [GroupLayoutSolver.Tile(id: 1, weight: 8),   // heaviest
         GroupLayoutSolver.Tile(id: 2, weight: 4),
         GroupLayoutSolver.Tile(id: 3, weight: 3),
         GroupLayoutSolver.Tile(id: 4, weight: 2),
         GroupLayoutSolver.Tile(id: 5, weight: 1)]
    }

    func testLeftBiasPutsHeaviestAgainstTheLeftEdge() {
        let result = GroupLayoutSolver.solve(tiles: weighted,
                                            preset: .treemap(bias: .left),
                                            in: bounds, gap: 0)
        XCTAssertEqual(result[1]!.minX, bounds.minX, accuracy: 0.5)
        XCTAssertEqual(result[1]!.height, bounds.height, accuracy: 0.5,
                       "the biased tile spans the full height as a band")
    }

    func testRightBiasPutsHeaviestAgainstTheRightEdge() {
        let result = GroupLayoutSolver.solve(tiles: weighted,
                                            preset: .treemap(bias: .right),
                                            in: bounds, gap: 0)
        XCTAssertEqual(result[1]!.maxX, bounds.maxX, accuracy: 0.5)
    }

    func testCentreBiasPutsHeaviestInTheMiddleWithNeighboursOnBothSides() {
        let result = GroupLayoutSolver.solve(tiles: weighted,
                                            preset: .treemap(bias: .center),
                                            in: bounds, gap: 0)
        let heaviest = result[1]!
        XCTAssertGreaterThan(heaviest.minX, bounds.minX + 1, "something is to its left")
        XCTAssertLessThan(heaviest.maxX, bounds.maxX - 1, "something is to its right")
        let leftOfCentre = result.filter { $0.key != 1 && $0.value.midX < heaviest.midX }
        let rightOfCentre = result.filter { $0.key != 1 && $0.value.midX > heaviest.midX }
        XCTAssertFalse(leftOfCentre.isEmpty)
        XCTAssertFalse(rightOfCentre.isEmpty)
    }

    func testHeaviestKeepsItsAreaShareUnderEveryBias() {
        for bias in [GroupLayoutSolver.TreemapBias.center, .left, .right] {
            let result = GroupLayoutSolver.solve(tiles: weighted,
                                                 preset: .treemap(bias: bias),
                                                 in: bounds, gap: 0)
            let area = Double(result[1]!.width * result[1]!.height)
            let share = area / Double(bounds.width * bounds.height)
            XCTAssertEqual(share, 8.0 / 18.0, accuracy: 0.03, "bias \(bias)")
        }
    }

    func testTreemapNeverOverlapsOrEscapes() {
        for bias in [GroupLayoutSolver.TreemapBias.center, .left, .right] {
            for count in 1...8 {
                let tiles = (1...count).map {
                    GroupLayoutSolver.Tile(id: $0, weight: Double(count - $0 + 1))
                }
                let result = GroupLayoutSolver.solve(tiles: tiles,
                                                     preset: .treemap(bias: bias),
                                                     in: bounds, gap: 3)
                XCTAssertEqual(result.count, count)
                let rects = Array(result.values)
                for rect in rects {
                    XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
                }
                for i in rects.indices {
                    for j in (i + 1)..<rects.count {
                        let overlap = rects[i].intersection(rects[j])
                        XCTAssertTrue(overlap.isNull || overlap.width < 0.5
                                      || overlap.height < 0.5,
                                      "bias \(bias), count \(count): \(overlap)")
                    }
                }
            }
        }
    }

    func testTwoTilesCentreBiasDegradesGracefully() {
        // With only one non-heaviest tile there is nothing to put on the other
        // side; the result must still be valid, non-overlapping and complete.
        let tiles = [GroupLayoutSolver.Tile(id: 1, weight: 3),
                     GroupLayoutSolver.Tile(id: 2, weight: 1)]
        let result = GroupLayoutSolver.solve(tiles: tiles,
                                            preset: .treemap(bias: .center),
                                            in: bounds, gap: 0)
        XCTAssertEqual(result.count, 2)
        let overlap = result[1]!.intersection(result[2]!)
        XCTAssertTrue(overlap.isNull || overlap.width < 0.5)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL (no `treemap`).

- [ ] **Step 3: Implement**

Add to `GroupLayoutSolver`:
```swift
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
```
Note the `.center` two-tile case: `rightTiles` is empty, so the band sits at `minX + sideWidth` — flush right, with the single light tile on its left. `testTwoTilesCentreBiasDegradesGracefully` only requires validity, not centring, because centring is impossible with one neighbour.

- [ ] **Step 4: Run `swift test`** — PASS (6 new; 154 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/GroupLayoutSolver.swift Tests/MacTLMCoreTests/GroupLayoutTreemapTests.swift
git commit -m "feat: weighted treemap preset with centre, left and right bias"
```

---

### Task 4: Minimum-size clamping

PRD §8 lists "treemap solver produces unusable slivers" as a risk with "app-minimum clamps" as the mitigation.

**Files:**
- Modify: `Sources/MacTLMCore/GroupLayoutSolver.swift`
- Create: `Tests/MacTLMCoreTests/GroupLayoutMinimumSizeTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/GroupLayoutMinimumSizeTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class GroupLayoutMinimumSizeTests: XCTestCase {
    func testSliversAreGrownToTheMinimum() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 400)
        // One dominant tile plus several near-zero ones would produce slivers.
        var tiles = [GroupLayoutSolver.Tile(id: 0, weight: 100)]
        tiles += (1...5).map { GroupLayoutSolver.Tile(id: $0, weight: 0.2) }
        let result = GroupLayoutSolver.solve(tiles: tiles,
                                            preset: .treemap(bias: .left),
                                            in: bounds, gap: 0,
                                            minimumSize: CGSize(width: 120, height: 90))
        for (id, rect) in result {
            XCTAssertGreaterThanOrEqual(rect.width, 119.5, "tile \(id) too narrow")
            XCTAssertGreaterThanOrEqual(rect.height, 89.5, "tile \(id) too short")
        }
    }

    func testClampNeverPushesATileOutsideBounds() {
        let bounds = CGRect(x: 500, y: 300, width: 800, height: 600)
        let tiles = (0...6).map { GroupLayoutSolver.Tile(id: $0, weight: Double($0 + 1)) }
        let result = GroupLayoutSolver.solve(tiles: tiles, preset: .grid,
                                            in: bounds, gap: 0,
                                            minimumSize: CGSize(width: 300, height: 250))
        for rect in result.values {
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.5)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.5)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.5)
        }
    }

    func testMinimumLargerThanBoundsYieldsBoundsSizedTiles() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        let tiles = [GroupLayoutSolver.Tile(id: 1, weight: 1),
                     GroupLayoutSolver.Tile(id: 2, weight: 1)]
        let result = GroupLayoutSolver.solve(tiles: tiles, preset: .columns,
                                            in: bounds, gap: 0,
                                            minimumSize: CGSize(width: 400, height: 400))
        for rect in result.values {
            XCTAssertEqual(rect.width, 200, accuracy: 0.5)
            XCTAssertEqual(rect.height, 150, accuracy: 0.5)
        }
    }

    func testZeroMinimumIsUnchangedFromTheDefaultPath() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let tiles = (1...4).map { GroupLayoutSolver.Tile(id: $0, weight: Double($0)) }
        let withZero = GroupLayoutSolver.solve(tiles: tiles, preset: .grid,
                                              in: bounds, gap: 6,
                                              minimumSize: .zero)
        let withDefault = GroupLayoutSolver.solve(tiles: tiles, preset: .grid,
                                                 in: bounds, gap: 6)
        XCTAssertEqual(withZero, withDefault)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `solve` has no `minimumSize` parameter.

- [ ] **Step 3: Implement**

Give `solve` a defaulted parameter `minimumSize: CGSize = .zero` and apply a post-pass:
```swift
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
```
Call it last in `solve`, after the gap pass.

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 158 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/GroupLayoutSolver.swift Tests/MacTLMCoreTests/GroupLayoutMinimumSizeTests.swift
git commit -m "feat: clamp solved tiles to a minimum usable size"
```

---

### Task 5: Resolve the display group and apply a preset

**Files:**
- Create: `Sources/MacTLM/DisplayGroupReflow.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`

- [ ] **Step 1: Implement the resolver and applier**

`Sources/MacTLM/DisplayGroupReflow.swift`:
```swift
import AppKit
import MacTLMCore

/// Reflows the windows of one display into a preset.
///
/// M3a has no explicit magnet groups yet (those arrive with drag-mating in
/// M3b), so the group is every eligible window on the display holding the
/// frontmost window: standard subrole, not minimized, app not excluded, and
/// never MacTLM itself. Weights come from stacking order — frontmost is
/// heaviest — so the treemap needs no manual setup.
struct DisplayGroupReflow {
    let driver: MacWindowDriver
    let excludedBundleIDs: Set<String>

    /// Applies `preset` and returns the number of windows moved.
    @discardableResult
    func apply(_ preset: GroupLayoutSolver.Preset,
               gap: CGFloat = 8,
               minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Int {
        guard let display = targetDisplay() else { return 0 }
        let members = eligibleWindows(on: display)
        guard members.count > 1 else { return 0 }

        // Frontmost (lowest z index) is heaviest.
        let tiles = members.enumerated().map { index, member in
            GroupLayoutSolver.Tile(id: member.window.id,
                                   weight: Double(members.count - index))
        }
        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                            in: display.visibleArea, gap: gap,
                                            minimumSize: minimumSize)
        var moved = 0
        // Apply back-to-front so the frontmost window ends up on top.
        for member in members.reversed() {
            guard let target = solved[member.window.id] else { continue }
            let achieved = driver.setFrame(target, of: member.window)
            if !achieved.approximatelyEquals(target, tolerance: RestoreEngine.tolerance) {
                _ = driver.setFrame(target, of: member.window)
            }
            moved += 1
        }
        return moved
    }

    private struct Member {
        let window: DriverWindow
        let bundleID: String
    }

    /// The display containing the frontmost eligible window, else the main one.
    private func targetDisplay() -> SnapshotPlanner.Display? {
        let displays = ScreenGeometry.allDisplays
        guard !displays.isEmpty else { return nil }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !excludedBundleIDs.contains(frontmost),
           let window = driver.windows(ofBundleID: frontmost).first,
           let owning = displays.first(where: {
               $0.visibleArea.contains(CGPoint(x: window.frame.midX,
                                               y: window.frame.midY))
           }) {
            return owning
        }
        return displays.first
    }

    /// Front-to-back eligible windows whose centre lies on `display`.
    private func eligibleWindows(on display: SnapshotPlanner.Display) -> [Member] {
        var members: [Member] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !excludedBundleIDs.contains(bundleID),
                  seen.insert(bundleID).inserted else { continue }
            for window in driver.windows(ofBundleID: bundleID) {
                let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
                guard display.visibleArea.contains(centre) else { continue }
                members.append(Member(window: window, bundleID: bundleID))
            }
        }
        // Order by global stacking so weights follow what the user is using.
        let order = ZOrderMatcher.zIndices(
            axWindows: members.map {
                ZOrderMatcher.AXRef(id: $0.window.id, pid: 0, frame: $0.window.frame)
            },
            cgFrontToBack: ZOrderCapture.frontToBack())
        return members.sorted {
            (order[$0.window.id] ?? .max) < (order[$1.window.id] ?? .max)
        }
    }
}
```
Compile note: `ZOrderMatcher.AXRef` needs a pid to match CG entries. `DriverWindow` does not carry one, so passing `pid: 0` will match nothing and every window falls back to input order. Either extend `DriverWindow` with `pid` (preferred — it is already available in `MacWindowDriver.windows`) or drop the z-order sort and document that weights follow enumeration order. **Choose the pid route and report it.**

- [ ] **Step 2: Expose it on the coordinator**

```swift
    func reflowDisplay(_ preset: GroupLayoutSolver.Preset) {
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs)
        let moved = reflow.apply(preset)
        NSLog("MacTLM: reflow %@ moved %d windows", String(describing: preset), moved)
    }
```

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 158 tests; bundle built. Do not launch the app.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: reflow a display's windows into a solver preset"
```

---

### Task 6: Preset glyph row in the menu

PRD §4 item 1: a Rectangle-style row of shaded miniatures at the top of the menu.

**Files:**
- Create: `Sources/MacTLM/PresetGlyph.swift`
- Modify: `Sources/MacTLM/StatusMenuController.swift`

- [ ] **Step 1: Draw the glyphs**

`Sources/MacTLM/PresetGlyph.swift` — an `NSImage` per preset, drawn programmatically (no asset catalog): a rounded rect background with pale tiles showing the arrangement, the weighted tile filled in the accent colour. Size 44×30, `isTemplate = false` so the accent shows. One function:
```swift
static func image(for preset: GroupLayoutSolver.Preset) -> NSImage
```
Reuse `GroupLayoutSolver.solve` with 5 unit-ish tiles inside a 44×30 box to draw each glyph, so the icon is literally what the preset does. Weighted presets pass descending weights; even ones pass equal weights.

- [ ] **Step 2: Add the row to the menu**

In `menuNeedsUpdate`, above the Workspaces section: a disabled header `"Reflow this display"`, then a single custom row whose `view` is an `NSStackView` of small `NSButton`s — one per preset in this order: treemap centre, treemap left, treemap right, symmetric, columns, rows, grid, main+side. Each button carries the glyph image, a tooltip naming the preset, and a target/action calling `coordinator.reflowDisplay(_:)` then `menu.cancelTracking()`.

Constraint: buttons inside a menu item view need `menu.cancelTracking()` to dismiss the menu after a click, and the row's view must be sized (`NSMenuItem.view` does not auto-size). Give the stack an explicit frame.

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh` — clean; 158 tests. Do not launch.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: preset glyph row for display reflow"
```

---

### Task 7: Live acceptance (user at keyboard)

- [ ] **Step 1:** `./scripts/install.sh`; confirm the menu now opens with a "Reflow this display" glyph row.
- [ ] **Step 2:** On the ultrawide, click **columns** — every eligible window becomes an equal vertical strip. Illustrator (excluded) must NOT move.
- [ ] **Step 3:** Click **grid**, then **rows** — arrangements change accordingly and nothing escapes the display.
- [ ] **Step 4 (the feature you designed):** click **treemap centre**. The frontmost window should take the largest central band, with the rest arranged either side by decreasing size. Then **treemap left** and **treemap right** and confirm the heaviest band moves to that edge.
- [ ] **Step 5:** Focus a *different* window and click treemap centre again — the newly focused window should now be the large central one, since weights follow stacking order.
- [ ] **Step 6:** Move the mouse/focus to the laptop display and reflow — only that display's windows move.
- [ ] **Step 7:** Confirm reflow interacts sanely with persistence: after a reflow, wait 3s, then check `configurations/*.json` recorded the new frames (a reflow is a normal move and should be remembered).
- [ ] **Step 8:** Tag:
```bash
git tag -a v0.6.0-m3a -m "M3a: preset reflow solvers with weighted treemap"
```

---

## Plan self-review notes

- **Spec coverage:** PRD §3.3's preset list ✓ (columns, rows, grid, main+side, symmetric, treemap with three biases), symmetric-as-equal-weights ✓ (Task 2 implements it via the same partition), glyph row ✓ (Task 6). Deferred with reasons stated above: drag-to-mate, shared-edge resize, manual weights, Tier-2 structural reflow.
- **Why a binary partition rather than textbook squarified treemap:** every split is weight-proportional, so a tile's area is exactly its weight share — which turns "is the treemap right?" into arithmetic assertions instead of eyeballing. Aspect ratios are decent because each split takes the longer axis. If tiles come out too elongated in practice, swapping in squarified is a Task-2-local change with the same tests.
- **Property tests, not example tests, for the risky parts:** bounds containment, non-overlap, area-share, weight monotonicity and determinism are asserted across preset × tile-count matrices, which is what catches sliver and off-by-one bugs.
- **Known M3a limitations to record in `docs/BACKLOG.md` at Task 7:** the implicit group means a reflow moves *every* eligible window on the display, including ones the user thinks of as floating; `.center` bias cannot centre with only two tiles; weights are z-order so reflow output changes as focus changes; clamping may overlap tiles when a minimum cannot fit.
