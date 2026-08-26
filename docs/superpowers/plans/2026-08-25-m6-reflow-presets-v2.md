# M6 — Reflow Presets v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two unambiguous reflow glyph rows (display + group), five new built-in presets (main-center, mirrored main-side, BSP dwindle, cascade, monocle), user-defined custom presets (fixed columns, fixed X×Y grids, parameterized main-center) pinned from a new Preferences tab, and an explode-vs-keep policy for magnet groups under display reflow.

**Architecture:** All new geometry is pure `GroupLayoutSolver` cases in `FerriteCore` (Linux-portable, property-tested). Custom presets and the group policy persist in a new `reflows.json` via `ReflowStore` (FerriteCore). The macOS layer splits `reflowDisplay` from `reflowGroup`, adds the policy (explode = real ungroup; keep = group bounding box as one tile, members remapped via a new pure `MagnetScale.remap`), rebuilds the menu with two wrapped glyph rows plus per-group rows, and adds a Reflows Preferences tab with a change hook (finding 16 corollary).

**Tech Stack:** Swift 5.9 mode, XCTest, AppKit (menu), SwiftUI (Preferences).

**Spec:** `docs/superpowers/specs/2026-08-25-reflow-presets-v2-design.md`. Findings: `docs/BACKLOG.md` (especially 16 and its corollary).

## Scope decisions, stated plainly

- **Tile order in = placement order out** for every new preset. Callers pass tiles front-to-back, so the frontmost window gets the best cell. No preset sorts by weight except where the existing ones already do (`mainSide` family, `treemap`).
- **BSP splits are even 50/50 in v1**; weighted split ratios are a recorded extension, not scoped.
- **Fixed grids are zones, not stretchy cells** (FancyZones semantics): fewer windows leave trailing cells empty; more windows cycle back through cells z-stacked. `fixedColumns` fixes only the column count — rows grow with content, and columns beyond the window count stay empty.
- **Explode is a real ungroup** (default policy): membership removed via the same path as the Groups menu's Ungroup. Never leave a group whose members are scattered.
- **Custom presets are not layouts.** They live in `reflows.json`, not `layouts.json` — a fresh store, so finding 11's decode-wipe risk does not apply.
- Line numbers below are anchors as of `1f9b5c7`; re-read the file if it has drifted.

---

### Task 1: Solver — `mainSideMirrored`

**Files:**
- Modify: `Sources/FerriteCore/GroupLayoutSolver.swift` (enum ~line 24, switch ~line 55, helpers after `mainSide` ~line 120)
- Test: `Tests/FerriteCoreTests/GroupLayoutSolverV2Tests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `Tests/FerriteCoreTests/GroupLayoutSolverV2Tests.swift`:

```swift
import XCTest
@testable import FerriteCore

final class GroupLayoutSolverV2Tests: XCTestCase {
    let bounds = CGRect(x: 100, y: 50, width: 1200, height: 800)

    func evenTiles(_ count: Int) -> [GroupLayoutSolver.Tile] {
        (0..<count).map { GroupLayoutSolver.Tile(id: $0, weight: 1) }
    }

    /// Weights descend with id, so tile 0 is heaviest — the same convention
    /// the coordinator uses (frontmost = heaviest).
    func rankedTiles(_ count: Int) -> [GroupLayoutSolver.Tile] {
        (0..<count).map { GroupLayoutSolver.Tile(id: $0, weight: Double(count - $0)) }
    }

    // MARK: - mainSideMirrored

    func testMainSideMirroredPutsHeaviestOnTheRight() {
        let result = GroupLayoutSolver.solve(tiles: rankedTiles(4),
                                             preset: .mainSideMirrored,
                                             in: bounds, gap: 0)
        XCTAssertEqual(result[0]!.width, 720, accuracy: 0.01)   // 60% of 1200
        XCTAssertEqual(result[0]!.maxX, 1300, accuracy: 0.01)   // anchored right
        XCTAssertEqual(result[0]!.height, 800, accuracy: 0.01)
        // The three side tiles stack full-width-of-side on the left.
        for id in 1...3 {
            XCTAssertEqual(result[id]!.minX, 100, accuracy: 0.01)
            XCTAssertEqual(result[id]!.width, 480, accuracy: 0.01)
            XCTAssertEqual(result[id]!.height, 800.0 / 3, accuracy: 0.01)
        }
    }

    func testMainSideMirroredIsExactMirrorOfMainSide() {
        let straight = GroupLayoutSolver.solve(tiles: rankedTiles(3),
                                               preset: .mainSide, in: bounds, gap: 0)
        let mirrored = GroupLayoutSolver.solve(tiles: rankedTiles(3),
                                               preset: .mainSideMirrored,
                                               in: bounds, gap: 0)
        for (id, rect) in straight {
            let flipped = CGRect(x: bounds.minX + bounds.maxX - rect.maxX,
                                 y: rect.minY, width: rect.width, height: rect.height)
            XCTAssertEqual(mirrored[id]!.minX, flipped.minX, accuracy: 0.01)
            XCTAssertEqual(mirrored[id]!.width, flipped.width, accuracy: 0.01)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GroupLayoutSolverV2Tests 2>&1 | tail -5`
Expected: compile FAILURE — `type 'GroupLayoutSolver.Preset' has no member 'mainSideMirrored'`.

- [ ] **Step 3: Implement**

In `GroupLayoutSolver.swift`, add the case and wire it (the enum gains cases in
several tasks; keep `allBasicCases` updated each time):

```swift
    public enum Preset: Equatable {
        case columns
        case rows
        case grid
        case mainSide
        case mainSideMirrored
        case symmetric
        case treemap(bias: TreemapBias)

        /// The presets that ignore weights — used by exhaustive tests.
        public static let allBasicCases: [Preset] = [.columns, .rows, .grid,
                                                     .mainSide, .mainSideMirrored,
                                                     .symmetric]
    }
```

(`allBasicCases` historically held the even presets *and* `mainSide`; keep the
existing membership plus the mirror so the exhaustive suites cover it.)

In `solve`'s switch:

```swift
        case .mainSideMirrored:
            raw = mainSideMirrored(tiles, in: bounds)
```

After `mainSide` (~line 120):

```swift
    /// `mainSide` flipped: heaviest takes 60% on the right, stack on the left.
    private static func mainSideMirrored(_ tiles: [Tile],
                                         in bounds: CGRect) -> [Int: CGRect] {
        let ordered = tiles.sorted { $0.weight > $1.weight }
        let mainWidth = bounds.width * 0.6
        var result = [ordered[0].id: CGRect(x: bounds.maxX - mainWidth,
                                            y: bounds.minY,
                                            width: mainWidth, height: bounds.height)]
        let sideBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                width: bounds.width - mainWidth, height: bounds.height)
        for (id, rect) in strips(Array(ordered.dropFirst()), in: sideBounds,
                                 vertical: false) {
            result[id] = rect
        }
        return result
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: PASS, count grows by 2. If an existing exhaustive test iterates
`allBasicCases` and asserts per-preset counts, it now covers the mirror for
free; fix any test that hardcoded the old case list.

- [ ] **Step 5: Commit**

```bash
git add Sources/FerriteCore/GroupLayoutSolver.swift Tests/FerriteCoreTests/GroupLayoutSolverV2Tests.swift
git commit -m "feat(solver): mainSideMirrored preset"
```

---

### Task 2: Solver — `mainCenter(fraction:sideCapacity:)`

**Files:**
- Modify: `Sources/FerriteCore/GroupLayoutSolver.swift`
- Test: `Tests/FerriteCoreTests/GroupLayoutSolverV2Tests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `GroupLayoutSolverV2Tests`:

```swift
    // MARK: - mainCenter

    func testMainCenterSplitsSidesEqually() {
        let result = GroupLayoutSolver.solve(
            tiles: rankedTiles(5),
            preset: .mainCenter(fraction: 0.6, sideCapacity: nil),
            in: bounds, gap: 0)
        // Heaviest centered at 60%: sides (1-0.6)/2 = 240 each.
        XCTAssertEqual(result[0]!.minX, 340, accuracy: 0.01)
        XCTAssertEqual(result[0]!.width, 720, accuracy: 0.01)
        // 2nd → left, 3rd → right, 4th → left, 5th → right (alternating).
        XCTAssertEqual(result[1]!.minX, 100, accuracy: 0.01)   // left
        XCTAssertEqual(result[2]!.minX, 1060, accuracy: 0.01)  // right
        XCTAssertEqual(result[3]!.minX, 100, accuracy: 0.01)   // left
        XCTAssertEqual(result[4]!.minX, 1060, accuracy: 0.01)  // right
        // Two tiles per side → each half the height.
        XCTAssertEqual(result[1]!.height, 400, accuracy: 0.01)
        XCTAssertEqual(result[3]!.minY, 450, accuracy: 0.01)
    }

    func testMainCenterUsersFraction() {
        // The user's 66% centre: sides are 17% each.
        let result = GroupLayoutSolver.solve(
            tiles: rankedTiles(3),
            preset: .mainCenter(fraction: 0.66, sideCapacity: 4),
            in: bounds, gap: 0)
        XCTAssertEqual(result[0]!.width, 1200 * 0.66, accuracy: 0.01)
        XCTAssertEqual(result[1]!.width, 1200 * 0.17, accuracy: 0.01)
        XCTAssertEqual(result[2]!.width, 1200 * 0.17, accuracy: 0.01)
    }

    func testMainCenterCapacityCapsAndCycles() {
        // 1 main + 6 side tiles at capacity 2: each side has 2 cells;
        // the 4 spill tiles cycle back into cells z-stacked.
        let result = GroupLayoutSolver.solve(
            tiles: rankedTiles(7),
            preset: .mainCenter(fraction: 0.6, sideCapacity: 2),
            in: bounds, gap: 0)
        // Left side gets tiles 1,3,5; two cells → tile 5 shares tile 1's cell.
        XCTAssertEqual(result[1], result[5])
        XCTAssertEqual(result[1]!.height, 400, accuracy: 0.01)
        // Right side gets tiles 2,4,6; tile 6 shares tile 2's cell.
        XCTAssertEqual(result[2], result[6])
    }

    func testMainCenterOneSideTileLeavesRightColumnEmpty() {
        let result = GroupLayoutSolver.solve(
            tiles: rankedTiles(2),
            preset: .mainCenter(fraction: 0.6, sideCapacity: nil),
            in: bounds, gap: 0)
        XCTAssertEqual(result.count, 2)
        // Main stays centered (zones are fixed), the lone side tile is
        // full-height on the left.
        XCTAssertEqual(result[0]!.minX, 340, accuracy: 0.01)
        XCTAssertEqual(result[1]!.minX, 100, accuracy: 0.01)
        XCTAssertEqual(result[1]!.height, 800, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GroupLayoutSolverV2Tests 2>&1 | tail -5`
Expected: compile FAILURE — no member `mainCenter`.

- [ ] **Step 3: Implement**

Enum case (parameterized; the built-in menu entry uses `(0.6, nil)`):

```swift
        case mainCenter(fraction: Double, sideCapacity: Int?)
```

(`mainCenter` reads weights for choosing the main tile; do NOT add it to
`allBasicCases`.)

Switch arm:

```swift
        case .mainCenter(let fraction, let sideCapacity):
            raw = mainCenter(tiles, in: bounds, fraction: fraction,
                             sideCapacity: sideCapacity)
```

Implementation, after `mainSideMirrored`:

```swift
    /// Heaviest tile centered at `fraction` of the width; the remainder splits
    /// into two equal side columns. Remaining tiles deal alternately
    /// (2nd → left, 3rd → right, …); `sideCapacity` caps each stack's cell
    /// count, spill cycles back through the cells z-stacked. Zones are fixed:
    /// the main tile stays centered even when one side is empty.
    private static func mainCenter(_ tiles: [Tile], in bounds: CGRect,
                                   fraction: Double,
                                   sideCapacity: Int?) -> [Int: CGRect] {
        let ordered = tiles.sorted { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.id < rhs.id : lhs.weight > rhs.weight
        }
        guard let main = ordered.first else { return [:] }
        let clamped = CGFloat(min(max(fraction, 0.2), 0.9))
        let mainWidth = bounds.width * clamped
        let sideWidth = (bounds.width - mainWidth) / 2
        var result = [main.id: CGRect(x: bounds.minX + sideWidth, y: bounds.minY,
                                      width: mainWidth, height: bounds.height)]
        var left: [Tile] = []
        var right: [Tile] = []
        for (index, tile) in ordered.dropFirst().enumerated() {
            if index.isMultiple(of: 2) { left.append(tile) } else { right.append(tile) }
        }
        let leftBox = CGRect(x: bounds.minX, y: bounds.minY,
                             width: sideWidth, height: bounds.height)
        let rightBox = CGRect(x: bounds.minX + sideWidth + mainWidth, y: bounds.minY,
                              width: sideWidth, height: bounds.height)
        result.merge(sideStack(left, in: leftBox, capacity: sideCapacity)) { a, _ in a }
        result.merge(sideStack(right, in: rightBox, capacity: sideCapacity)) { a, _ in a }
        return result
    }

    /// Vertical stack of at most `capacity` cells (nil = one cell per tile).
    /// Tiles beyond the cell count cycle back through the cells.
    private static func sideStack(_ tiles: [Tile], in box: CGRect,
                                  capacity: Int?) -> [Int: CGRect] {
        guard !tiles.isEmpty else { return [:] }
        let cells = max(1, min(capacity ?? tiles.count, tiles.count))
        let cellHeight = box.height / CGFloat(cells)
        var result: [Int: CGRect] = [:]
        for (index, tile) in tiles.enumerated() {
            let cell = index % cells
            result[tile.id] = CGRect(x: box.minX,
                                     y: box.minY + cellHeight * CGFloat(cell),
                                     width: box.width, height: cellHeight)
        }
        return result
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(solver): mainCenter preset with fraction and side capacity"
```

---

### Task 3: Solver — `bsp` (dwindle)

**Files:** same as Task 2.

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - bsp

    func testBspAlternatesVerticalThenHorizontal() {
        let result = GroupLayoutSolver.solve(tiles: evenTiles(4), preset: .bsp,
                                             in: bounds, gap: 0)
        // Tile 0: left half. Tile 1: top half of the right half.
        // Tile 2: left half of the remaining quarter. Tile 3: the rest.
        XCTAssertEqual(result[0]!, CGRect(x: 100, y: 50, width: 600, height: 800))
        XCTAssertEqual(result[1]!, CGRect(x: 700, y: 50, width: 600, height: 400))
        XCTAssertEqual(result[2]!, CGRect(x: 700, y: 450, width: 300, height: 400))
        XCTAssertEqual(result[3]!, CGRect(x: 1000, y: 450, width: 300, height: 400))
    }

    func testBspPlacementFollowsTileOrder() {
        // Front-to-back in = spiral order out: earlier tiles get bigger cells.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(5), preset: .bsp,
                                             in: bounds, gap: 0)
        let areas = (0..<5).map { result[$0]!.width * result[$0]!.height }
        for i in 0..<(areas.count - 2) {
            XCTAssertGreaterThanOrEqual(areas[i], areas[i + 1])
        }
        // The last two cells share the final split, so they tie.
        XCTAssertEqual(areas[3], areas[4], accuracy: 0.01)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GroupLayoutSolverV2Tests 2>&1 | tail -5`
Expected: compile FAILURE — no member `bsp`.

- [ ] **Step 3: Implement**

Enum case `case bsp` — even splits, add to `allBasicCases`. Switch arm:

```swift
        case .bsp:
            raw = bsp(tiles, in: bounds, vertical: true)
```

Implementation:

```swift
    /// Dwindle spiral: the first tile takes half of the box, the rest recurse
    /// into the other half with the split axis flipped — Hyprland's default
    /// layout. Splits are even 50/50 in v1 (weighted ratios are a recorded
    /// extension). Tile order in = spiral order out.
    private static func bsp(_ tiles: [Tile], in bounds: CGRect,
                            vertical: Bool) -> [Int: CGRect] {
        guard let first = tiles.first else { return [:] }
        guard tiles.count > 1 else { return [first.id: bounds] }
        let head: CGRect
        let tail: CGRect
        if vertical {
            let cut = bounds.width / 2
            head = CGRect(x: bounds.minX, y: bounds.minY,
                          width: cut, height: bounds.height)
            tail = CGRect(x: bounds.minX + cut, y: bounds.minY,
                          width: bounds.width - cut, height: bounds.height)
        } else {
            let cut = bounds.height / 2
            head = CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: cut)
            tail = CGRect(x: bounds.minX, y: bounds.minY + cut,
                          width: bounds.width, height: bounds.height - cut)
        }
        return bsp(Array(tiles.dropFirst()), in: tail, vertical: !vertical)
            .merging([first.id: head]) { a, _ in a }
    }
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(solver): bsp dwindle preset"
```

---

### Task 4: Solver — `cascade` and `monocle`

**Files:** same as Task 2.

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - cascade

    func testCascadeStaggersBackToFront() {
        let result = GroupLayoutSolver.solve(tiles: evenTiles(3), preset: .cascade,
                                             in: bounds, gap: 0)
        // All tiles 70% of bounds.
        for rect in result.values {
            XCTAssertEqual(rect.width, 840, accuracy: 0.01)
            XCTAssertEqual(rect.height, 560, accuracy: 0.01)
        }
        // Frontmost (id 0) sits deepest toward bottom-right; backmost at origin.
        XCTAssertEqual(result[2]!.origin, CGPoint(x: 100, y: 50))
        XCTAssertGreaterThan(result[1]!.minX, result[2]!.minX)
        XCTAssertGreaterThan(result[0]!.minX, result[1]!.minX)
        // Stagger is uniform and every tile stays inside bounds.
        let step = result[1]!.minX - result[2]!.minX
        XCTAssertEqual(result[0]!.minX - result[1]!.minX, step, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result[0]!.maxX, bounds.maxX + 0.01)
        XCTAssertLessThanOrEqual(result[0]!.maxY, bounds.maxY + 0.01)
    }

    func testCascadeStepIsCappedAt40() {
        // Two tiles in a huge box: free space / 1 would exceed 40pt — capped.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(2), preset: .cascade,
                                             in: bounds, gap: 0)
        XCTAssertEqual(result[0]!.minX - result[1]!.minX, 40, accuracy: 0.01)
    }

    // MARK: - monocle

    func testMonocleGivesEveryTileFullBounds() {
        let result = GroupLayoutSolver.solve(tiles: evenTiles(4), preset: .monocle,
                                             in: bounds, gap: 0)
        XCTAssertEqual(result.count, 4)
        for rect in result.values { XCTAssertEqual(rect, bounds) }
    }
```

- [ ] **Step 2: Run to verify failure** — compile FAILURE, no members `cascade`/`monocle`.

- [ ] **Step 3: Implement**

Enum cases `case cascade` and `case monocle` — both ignore weights; add both
to `allBasicCases` **only if** the exhaustive suite's invariants hold for them
(they intentionally overlap, so DO NOT add them; instead give them their own
assertions here). Switch arms:

```swift
        case .cascade:
            raw = cascade(tiles, in: bounds)
        case .monocle:
            raw = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, bounds) })
```

Implementation:

```swift
    /// Classic floating-Mac cascade: every tile 70% of the box, staggered
    /// diagonally. Backmost tile at the top-left, frontmost deepest toward the
    /// bottom-right (and on top once the caller writes front-to-back). The
    /// step is sized so the last tile still fits, capped at 40pt.
    private static func cascade(_ tiles: [Tile], in bounds: CGRect) -> [Int: CGRect] {
        let tileSize = CGSize(width: bounds.width * 0.7, height: bounds.height * 0.7)
        let free = CGSize(width: bounds.width - tileSize.width,
                          height: bounds.height - tileSize.height)
        let count = tiles.count
        let step: CGFloat = count > 1
            ? min(40, min(free.width, free.height) / CGFloat(count - 1))
            : 0
        var result: [Int: CGRect] = [:]
        for (index, tile) in tiles.enumerated() {
            let offset = step * CGFloat(count - 1 - index)
            result[tile.id] = CGRect(x: bounds.minX + offset, y: bounds.minY + offset,
                                     width: tileSize.width, height: tileSize.height)
        }
        return result
    }
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(solver): cascade and monocle presets"
```

---

### Task 5: Solver — `fixedColumns` and `fixedGrid`

**Files:** same as Task 2.

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - fixedColumns

    func testFixedColumnsWrapsIntoRowsWithinColumns() {
        // 4 tiles, 3 columns: w0,w1,w2 across, w3 under w0.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(4),
                                             preset: .fixedColumns(3),
                                             in: bounds, gap: 0)
        XCTAssertEqual(result[0]!.minX, 100, accuracy: 0.01)
        XCTAssertEqual(result[1]!.minX, 500, accuracy: 0.01)
        XCTAssertEqual(result[2]!.minX, 900, accuracy: 0.01)
        XCTAssertEqual(result[3]!.minX, 100, accuracy: 0.01)
        // Column 0 holds two tiles → half height each; columns 1-2 full height.
        XCTAssertEqual(result[0]!.height, 400, accuracy: 0.01)
        XCTAssertEqual(result[3]!.minY, 450, accuracy: 0.01)
        XCTAssertEqual(result[1]!.height, 800, accuracy: 0.01)
    }

    func testFixedColumnsFewerWindowsLeaveColumnsEmpty() {
        // Zones are fixed: 2 tiles in 7 columns occupy 1/7 width each.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(2),
                                             preset: .fixedColumns(7),
                                             in: bounds, gap: 0)
        XCTAssertEqual(result[0]!.width, 1200.0 / 7, accuracy: 0.01)
        XCTAssertEqual(result[1]!.minX, 100 + 1200.0 / 7, accuracy: 0.01)
    }

    // MARK: - fixedGrid

    func testFixedGridFillsRowMajorAndKeepsCellSize() {
        // The user's wall: 7 wide × 3 tall, 5 windows → 5 cells of the 21.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(5),
                                             preset: .fixedGrid(columns: 7, rows: 3),
                                             in: bounds, gap: 0)
        let cellW = 1200.0 / 7, cellH = 800.0 / 3
        for rect in result.values {
            XCTAssertEqual(rect.width, cellW, accuracy: 0.01)
            XCTAssertEqual(rect.height, cellH, accuracy: 0.01)
        }
        // Row-major: tile 4 is the 5th cell of the top row.
        XCTAssertEqual(result[4]!.minX, 100 + cellW * 4, accuracy: 0.01)
        XCTAssertEqual(result[4]!.minY, 50, accuracy: 0.01)
    }

    func testFixedGridOverflowCyclesZStacked() {
        // 5 tiles in a 2×2 grid: tile 4 reuses cell 0.
        let result = GroupLayoutSolver.solve(tiles: evenTiles(5),
                                             preset: .fixedGrid(columns: 2, rows: 2),
                                             in: bounds, gap: 0)
        XCTAssertEqual(result[4], result[0])
    }

    func testFixedGridSecondRowPlacement() {
        let result = GroupLayoutSolver.solve(tiles: evenTiles(4),
                                             preset: .fixedGrid(columns: 3, rows: 2),
                                             in: bounds, gap: 0)
        // Tile 3 starts row two.
        XCTAssertEqual(result[3]!.minX, 100, accuracy: 0.01)
        XCTAssertEqual(result[3]!.minY, 450, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run to verify failure** — compile FAILURE.

- [ ] **Step 3: Implement**

Enum cases (do not add to `allBasicCases` — parameterized cases can't be
enumerated; they get their own coverage above):

```swift
        case fixedColumns(Int)
        case fixedGrid(columns: Int, rows: Int)
```

Switch arms:

```swift
        case .fixedColumns(let count):
            raw = fixedColumns(tiles, in: bounds, count: count)
        case .fixedGrid(let columns, let rows):
            raw = fixedGrid(tiles, in: bounds, columns: columns, rows: rows)
```

Implementation:

```swift
    /// `count` fixed-width column zones. Tiles fill left-to-right and wrap
    /// into new rows within their column (tile i → column i % count); a
    /// column splits its height evenly among its own tiles. Columns beyond
    /// the tile count stay empty — zones are fixed, never stretched.
    private static func fixedColumns(_ tiles: [Tile], in bounds: CGRect,
                                     count: Int) -> [Int: CGRect] {
        let columns = max(1, count)
        let columnWidth = bounds.width / CGFloat(columns)
        var perColumn: [[Tile]] = Array(repeating: [], count: columns)
        for (index, tile) in tiles.enumerated() {
            perColumn[index % columns].append(tile)
        }
        var result: [Int: CGRect] = [:]
        for (column, columnTiles) in perColumn.enumerated() where !columnTiles.isEmpty {
            let rowHeight = bounds.height / CGFloat(columnTiles.count)
            for (row, tile) in columnTiles.enumerated() {
                result[tile.id] = CGRect(
                    x: bounds.minX + columnWidth * CGFloat(column),
                    y: bounds.minY + rowHeight * CGFloat(row),
                    width: columnWidth, height: rowHeight)
            }
        }
        return result
    }

    /// Fixed `columns × rows` zones (FancyZones semantics). Tiles fill cells
    /// row-major front-to-back; fewer tiles leave trailing cells empty, more
    /// tiles cycle back through the cells z-stacked. Cells never stretch.
    private static func fixedGrid(_ tiles: [Tile], in bounds: CGRect,
                                  columns: Int, rows: Int) -> [Int: CGRect] {
        let cols = max(1, columns)
        let rws = max(1, rows)
        let cellWidth = bounds.width / CGFloat(cols)
        let cellHeight = bounds.height / CGFloat(rws)
        let cellCount = cols * rws
        var result: [Int: CGRect] = [:]
        for (index, tile) in tiles.enumerated() {
            let cell = index % cellCount
            result[tile.id] = CGRect(
                x: bounds.minX + cellWidth * CGFloat(cell % cols),
                y: bounds.minY + cellHeight * CGFloat(cell / cols),
                width: cellWidth, height: cellHeight)
        }
        return result
    }
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(solver): fixedColumns and fixedGrid zone presets"
```

---

### Task 6: `Preset` Codable

**Files:**
- Modify: `Sources/FerriteCore/GroupLayoutSolver.swift` (enum declarations)
- Test: `Tests/FerriteCoreTests/PresetCodableTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FerriteCore

final class PresetCodableTests: XCTestCase {
    func testEveryPresetRoundTrips() throws {
        let presets: [GroupLayoutSolver.Preset] = [
            .columns, .rows, .grid, .mainSide, .mainSideMirrored, .symmetric,
            .treemap(bias: .center), .treemap(bias: .left), .treemap(bias: .right),
            .mainCenter(fraction: 0.66, sideCapacity: 4),
            .mainCenter(fraction: 0.6, sideCapacity: nil),
            .bsp, .cascade, .monocle,
            .fixedColumns(7), .fixedGrid(columns: 7, rows: 3),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for preset in presets {
            let data = try encoder.encode(preset)
            let back = try decoder.decode(GroupLayoutSolver.Preset.self, from: data)
            XCTAssertEqual(back, preset)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile FAILURE: `Preset` does not conform to `Codable`.

- [ ] **Step 3: Implement**

Swift synthesizes Codable for enums with associated values; conformance is
declaration-only:

```swift
    public enum Preset: Equatable, Codable {
```

```swift
    public enum TreemapBias: Equatable, Codable {
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(solver): Preset and TreemapBias are Codable"
```

---

### Task 7: `MagnetScale.remap` (keep-groups geometry)

**Files:**
- Modify: `Sources/FerriteCore/MagnetScale.swift`
- Test: `Tests/FerriteCoreTests/MagnetScaleRemapTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FerriteCore

final class MagnetScaleRemapTests: XCTestCase {
    func testRemapPreservesProportions() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let target = CGRect(x: 2000, y: 100, width: 500, height: 1000)
        let frames = [
            1: CGRect(x: 0, y: 0, width: 500, height: 500),
            2: CGRect(x: 500, y: 0, width: 500, height: 250),
        ]
        let result = MagnetScale.remap(frames: frames, from: source, to: target)
        XCTAssertEqual(result[1]!, CGRect(x: 2000, y: 100, width: 250, height: 1000))
        XCTAssertEqual(result[2]!, CGRect(x: 2250, y: 100, width: 250, height: 500))
    }

    func testRemapDegenerateSourceReturnsFramesUnchanged() {
        let frames = [1: CGRect(x: 5, y: 5, width: 10, height: 10)]
        let result = MagnetScale.remap(frames: frames,
                                       from: CGRect(x: 0, y: 0, width: 0, height: 10),
                                       to: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, frames)
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile FAILURE: no member `remap`.

- [ ] **Step 3: Implement**

Add to `MagnetScale` (after `settle`):

```swift
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
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): MagnetScale.remap for group-as-tile reflow"
```

---

### Task 8: `ReflowStore` — custom presets + group policy

**Files:**
- Create: `Sources/FerriteCore/ReflowStore.swift`
- Test: `Tests/FerriteCoreTests/ReflowStoreTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FerriteCore

final class ReflowStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflows-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testEmptyDefaultExplodesGroups() {
        let settings = ReflowStore(url: url).load()
        XCTAssertTrue(settings.customPresets.isEmpty)
        XCTAssertFalse(settings.keepGroupsOnDisplayReflow)
    }

    func testRoundTrip() throws {
        let store = ReflowStore(url: url)
        var settings = ReflowSettings()
        settings.customPresets = [
            CustomReflowPreset(name: "Wall 7×3",
                               preset: .fixedGrid(columns: 7, rows: 3)),
            CustomReflowPreset(name: "Big centre",
                               preset: .mainCenter(fraction: 0.66, sideCapacity: 4)),
        ]
        settings.keepGroupsOnDisplayReflow = true
        try store.save(settings)
        let back = store.load()
        XCTAssertEqual(back, settings)
    }

    func testUnknownFutureKeysAreTolerated() throws {
        // A payload written by a future Ferrite must not wipe the file
        // (finding 11's lesson, applied from day one).
        let json = """
        {"customPresets": [], "keepGroupsOnDisplayReflow": true,
         "someFutureKnob": 42}
        """
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertTrue(ReflowStore(url: url).load().keepGroupsOnDisplayReflow)
    }

    func testMissingKeysDecodeToDefaults() throws {
        try "{}".data(using: .utf8)!.write(to: url)
        let settings = ReflowStore(url: url).load()
        XCTAssertTrue(settings.customPresets.isEmpty)
        XCTAssertFalse(settings.keepGroupsOnDisplayReflow)
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile FAILURE.

- [ ] **Step 3: Implement**

Create `Sources/FerriteCore/ReflowStore.swift`:

```swift
import Foundation

/// A user-defined reflow preset pinned to the menu's glyph rows.
public struct CustomReflowPreset: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var preset: GroupLayoutSolver.Preset

    public init(id: UUID = UUID(), name: String,
                preset: GroupLayoutSolver.Preset) {
        self.id = id
        self.name = name
        self.preset = preset
    }
}

/// Everything reflow-related that persists: pinned custom presets and the
/// display-reflow group policy. Lives in reflows.json next to layouts.json —
/// sync-friendly like the rest of the App Support directory.
public struct ReflowSettings: Codable, Equatable {
    public var customPresets: [CustomReflowPreset]
    /// Display reflow policy: false (default) explodes magnet groups —
    /// members reflow individually and membership is dissolved; true keeps
    /// each intact group as one tile.
    public var keepGroupsOnDisplayReflow: Bool

    public init(customPresets: [CustomReflowPreset] = [],
                keepGroupsOnDisplayReflow: Bool = false) {
        self.customPresets = customPresets
        self.keepGroupsOnDisplayReflow = keepGroupsOnDisplayReflow
    }

    enum CodingKeys: String, CodingKey {
        case customPresets, keepGroupsOnDisplayReflow
    }

    /// Absent-tolerant: every field decodes to its default when missing, so
    /// adding fields later can never wipe a real file (finding 11).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customPresets = try container.decodeIfPresent(
            [CustomReflowPreset].self, forKey: .customPresets) ?? []
        keepGroupsOnDisplayReflow = try container.decodeIfPresent(
            Bool.self, forKey: .keepGroupsOnDisplayReflow) ?? false
    }
}

/// JSON persistence for reflow settings. Same posture as LayoutLibraryStore:
/// fail-soft load, atomic deterministic save.
public final class ReflowStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> ReflowSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(ReflowSettings.self, from: data)
        else { return ReflowSettings() }
        return settings
    }

    public func save(_ settings: ReflowSettings) throws {
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): ReflowStore - custom presets and display-reflow group policy"
```

---

### Task 9: `PresetGlyph` — new cases

**Files:**
- Modify: `Sources/Ferrite/PresetGlyph.swift`

No unit tests (AppKit drawing, verified live); the compiler enforces switch
exhaustiveness, which is the real guard here.

- [ ] **Step 1: Per-preset tile counts**

Replace the constant `tileCount` (line 15) with a function, and use it in
`draw` (line 38):

```swift
    /// Five tiles for count-adaptive presets (the smallest count that tells
    /// them all apart). Fixed-zone presets draw their true cell count so the
    /// glyph depicts the exact division; cascade shows three staggered tiles;
    /// monocle shows one.
    private static func tileCount(for preset: GroupLayoutSolver.Preset) -> Int {
        switch preset {
        case .fixedColumns(let count): return max(1, count)
        case .fixedGrid(let columns, let rows): return max(1, columns * rows)
        case .cascade: return 3
        case .monocle: return 1
        case .columns, .rows, .grid, .mainSide, .mainSideMirrored,
             .symmetric, .treemap, .mainCenter, .bsp:
            return 5
        }
    }
```

In `draw`, replace both uses of the old constant:

```swift
        let count = tileCount(for: preset)
        let tiles = (0..<count).map { index in
            GroupLayoutSolver.Tile(id: index,
                                   weight: readsWeights(preset)
                                       ? Double(count - index) : 1)
        }
```

- [ ] **Step 2: `readsWeights` gains the new cases**

```swift
    private static func readsWeights(_ preset: GroupLayoutSolver.Preset) -> Bool {
        switch preset {
        case .treemap, .mainSide, .mainSideMirrored, .mainCenter: return true
        case .columns, .rows, .grid, .symmetric, .bsp, .cascade, .monocle,
             .fixedColumns, .fixedGrid:
            return false
        }
    }
```

- [ ] **Step 3: Monocle double border**

At the end of `draw`, distinguish the lone full tile from a one-window glyph:

```swift
        if case .monocle = preset {
            // A single full tile reads as "one window"; the inner stroke says
            // "every window, stacked".
            let inner = box.insetBy(dx: 3, dy: 3)
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1
            path.stroke()
        }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` — if any switch over `Preset` elsewhere fails to
compile, that file belongs to a later task; note it and stub nothing.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(glyphs): per-preset tile counts, weights map, monocle border"
```

---

### Task 10: Coordinator + `DisplayGroupReflow` — explicit targets and group policy

**Files:**
- Modify: `Sources/Ferrite/PersistenceCoordinator.swift` (init ~line 73, `reflowDisplay` ~line 204, hooks ~line 43)
- Modify: `Sources/Ferrite/DisplayGroupReflow.swift`

No unit surface (AX layer); verified live in Task 13. The steps below are the
complete code changes.

- [ ] **Step 1: Coordinator owns a `ReflowStore` and a change hook**

In `PersistenceCoordinator`, next to `layoutLibraryStore` construction
(init, ~line 73):

```swift
        reflowStore = ReflowStore(
            url: supportDir.appendingPathComponent("reflows.json"))
```

Property declarations (near `layoutLibraryStore`'s):

```swift
    private let reflowStore: ReflowStore
```

Hook, next to `onLayoutLibraryChanged` (~line 43):

```swift
    /// Fires after any reflow-settings write (custom presets, group policy),
    /// so the menu and an open Reflows tab re-read — same lesson as
    /// onLayoutLibraryChanged (finding 16 corollary).
    var onReflowSettingsChanged: (() -> Void)?
```

Accessors (near `loadBundles`):

```swift
    func reflowSettings() -> ReflowSettings {
        reflowStore.load()
    }

    func updateReflowSettings(_ mutate: (inout ReflowSettings) -> Void) {
        var settings = reflowStore.load()
        mutate(&settings)
        try? reflowStore.save(settings)
        onReflowSettingsChanged?()
    }
```

- [ ] **Step 2: Split `reflowDisplay` / add `reflowGroup`**

Replace the existing `reflowDisplay` (~line 204):

```swift
    /// Reflows every eligible window on the active display into `preset`.
    /// Magnet groups follow the stored policy: exploded (dissolved, members
    /// placed individually — default) or kept as one tile each. A reflow is a
    /// normal window move: the tracker records the new frames afterwards.
    func reflowDisplay(_ preset: GroupLayoutSolver.Preset) {
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs,
                                        coordinator: self)
        let keep = reflowStore.load().keepGroupsOnDisplayReflow
        let moved = reflow.applyToDisplay(preset, keepGroups: keep)
        if !keep {
            dissolveGroupsTouchedByDisplayReflow()
        }
        NSLog("Ferrite: display reflow %@ moved %d windows (%@ groups)",
              String(describing: preset), moved, keep ? "kept" : "exploded")
    }

    /// Reflows exactly one group inside its own bounding box.
    func reflowGroup(_ preset: GroupLayoutSolver.Preset, groupID: UUID) {
        guard let group = tracker.magnetGroups.first(where: { $0.id == groupID })
        else { return }
        let live = liveMembers(of: group)
        guard live.count > 1 else { return }
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs,
                                        coordinator: self)
        let moved = reflow.apply(preset, to: group, live: live)
        lastGroupPreset[group.id] = preset
        NSLog("Ferrite: group reflow %@ moved %d windows",
              String(describing: preset), moved)
    }

    /// Explode policy: any group with ≥2 open windows on the reflowed display
    /// was just scattered — remove its membership entirely (same semantics as
    /// the Groups menu's Ungroup). Never leave a group whose members no
    /// longer touch.
    private func dissolveGroupsTouchedByDisplayReflow() {
        let groups = tracker.magnetGroups
        let active = groups.filter { liveMembers(of: $0).count > 1 }
        guard !active.isEmpty else { return }
        tracker.setMagnetGroups(groups.filter { candidate in
            !active.contains { $0.id == candidate.id }
        })
    }
```

`liveMembers(of:)` — if the coordinator doesn't already expose one (the
Groups menu resolves members somewhere near `magnetGroupSummaries`, ~line
371), extract the existing member-resolution into:

```swift
    /// The group's members that currently have a window open, resolved to
    /// live windows, front-to-back.
    private func liveMembers(of group: MagnetGroup) -> [LiveMember] { … existing resolution code, moved, not rewritten … }
```

(That body already exists inline where `apply(_:to:live:)` gets its `live`
argument today; move it, do not duplicate it — one identity path, finding 20.)

Also update the old `outcome.group` bookkeeping: `lastGroupPreset` is now set
only in `reflowGroup`; display reflow never sets it.

- [ ] **Step 3: `DisplayGroupReflow` loses the frontmost-group override**

In `DisplayGroupReflow.swift`:

- Delete the dispatching `apply(_:gap:minimumSize:)` (lines 29-40) and the
  `Outcome` struct — callers now choose explicitly.
- Make `applyToDisplay` internal (drop `private`) with the new signature and
  keep-groups support:

```swift
    /// Reflows the active display. `keepGroups: false` treats every eligible
    /// window as its own tile (the caller dissolves memberships afterwards);
    /// `true` collapses each intact group to one tile — the solver places its
    /// bounding box and the mated formation remaps into the assigned cell.
    /// Returns the number of windows written.
    @discardableResult
    func applyToDisplay(_ preset: GroupLayoutSolver.Preset,
                        keepGroups: Bool,
                        gap: CGFloat = 8,
                        minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Int {
        guard let display = targetDisplay() else { return 0 }
        let members = eligibleWindows(on: display)
        guard members.count > 1 else { return 0 }

        guard keepGroups else {
            return placeIndividually(members, preset: preset, on: display,
                                     gap: gap, minimumSize: minimumSize)
        }

        // Collapse each intact group (≥2 eligible windows on this display)
        // into one tile; everything else stays an individual tile.
        var tiles: [GroupLayoutSolver.Tile] = []
        var groupFrames: [Int: [Int: CGRect]] = [:]   // tile id → member frames
        var groupBoxes: [Int: CGRect] = [:]           // tile id → bounding box
        var windows: [Int: DriverWindow] = [:]        // solo tile id → window
        var memberWindows: [Int: [Int: DriverWindow]] = [:]
        var nextID = 0
        var consumed = Set<Int>()                     // member indices in groups

        for group in coordinator.magnetGroups() {
            let indices = members.indices.filter { index in
                group.contains(bundleID: members[index].bundleID,
                               slot: members[index].slot)
            }
            guard indices.count > 1 else { continue }
            var frames: [Int: CGRect] = [:]
            var wins: [Int: DriverWindow] = [:]
            for (memberOrdinal, index) in indices.enumerated() {
                frames[memberOrdinal] = members[index].frame
                wins[memberOrdinal] = members[index].window
                consumed.insert(index)
            }
            let box = frames.values.reduce(frames.values.first!) { $0.union($1) }
            tiles.append(GroupLayoutSolver.Tile(
                id: nextID, weight: Double(members.count - indices.min()!)))
            groupFrames[nextID] = frames
            groupBoxes[nextID] = box
            memberWindows[nextID] = wins
            nextID += 1
        }
        for index in members.indices where !consumed.contains(index) {
            tiles.append(GroupLayoutSolver.Tile(
                id: nextID, weight: Double(members.count - index)))
            windows[nextID] = members[index].window
            nextID += 1
        }

        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                             in: display.visibleArea, gap: gap,
                                             minimumSize: minimumSize)
        var written = 0
        for (id, cell) in solved {
            if let frames = groupFrames[id], let box = groupBoxes[id],
               let wins = memberWindows[id] {
                let mapped = MagnetScale.remap(frames: frames, from: box, to: cell)
                for (ordinal, rect) in mapped {
                    guard let window = wins[ordinal] else { continue }
                    write(rect, to: window)
                    written += 1
                }
            } else if let window = windows[id] {
                write(cell, to: window)
                written += 1
            }
        }
        return written
    }
```

`placeIndividually` is the existing `applyToDisplay` body renamed — same
tile construction (z-order weights), same solve-and-write loop. Adjust the
exact member/tile field names to the current `Member` struct (lines 103-106)
when editing; the struct carries window + frame + identity today.

`eligibleWindows(on:)` members must expose `bundleID`/`slot` for the group
match; if the current `Member` struct lacks them, add them from the identity
resolution that already happens during enumeration (lines 124-150).

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3`
Expected: FAILURE only in `StatusMenuController.swift` (its `reflowPreset`
still calls the old API) — that is Task 11. Everything else compiles.

- [ ] **Step 5: Commit**

```bash
git add Sources/Ferrite/PersistenceCoordinator.swift Sources/Ferrite/DisplayGroupReflow.swift
git commit -m "feat: explicit display/group reflow targets with explode-or-keep group policy"
```

---

### Task 11: Menu — two glyph rows, wrapping, policy toggle, per-group rows

**Files:**
- Modify: `Sources/Ferrite/StatusMenuController.swift`

- [ ] **Step 1: Preset list — built-ins in spec order, then customs**

Replace `reflowPresets` (lines 112-123):

```swift
    /// Built-ins in spec order; customs from Preferences append after.
    private static let builtinPresets: [(preset: GroupLayoutSolver.Preset,
                                        title: String)] = [
        (.columns, "Columns"),
        (.rows, "Rows"),
        (.grid, "Grid"),
        (.symmetric, "Symmetric — equal areas"),
        (.mainSide, "Main + side"),
        (.mainSideMirrored, "Main + side — main on the right"),
        (.mainCenter(fraction: 0.6, sideCapacity: nil), "Main in the centre"),
        (.bsp, "Split spiral"),
        (.treemap(bias: .center), "Treemap — heaviest in the centre"),
        (.treemap(bias: .left), "Treemap — heaviest on the left"),
        (.treemap(bias: .right), "Treemap — heaviest on the right"),
        (.cascade, "Cascade"),
        (.monocle, "Monocle — all full size"),
    ]

    /// Rebuilt per menu open: built-ins plus the user's pinned customs.
    private var menuPresets: [(preset: GroupLayoutSolver.Preset, title: String)] = []

    private func rebuildMenuPresets() {
        menuPresets = Self.builtinPresets
            + coordinator.reflowSettings().customPresets.map { ($0.preset, $0.name) }
    }
```

- [ ] **Step 2: Glyph rows wrap at 8, parameterized by target**

Replace `presetRow()` (lines 127-153). The reflow target rides in the
button's cell via `identifier`; the tag stays the preset index:

```swift
    private enum ReflowTarget {
        static let display = NSUserInterfaceItemIdentifier("reflow-display")
        static func group(_ id: UUID) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("reflow-group-\(id.uuidString)")
        }
    }

    /// Glyph button rows for one reflow target, wrapped at 8 per line.
    private func presetRows(target: NSUserInterfaceItemIdentifier) -> NSMenuItem {
        let buttons = menuPresets.indices.map { index -> NSButton in
            let entry = menuPresets[index]
            let button = NSButton(image: PresetGlyph.image(for: entry.preset),
                                  target: self, action: #selector(reflowPreset(_:)))
            button.tag = index
            button.identifier = target
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = entry.title
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(
                equalToConstant: PresetGlyph.size.width + 4).isActive = true
            button.heightAnchor.constraint(
                equalToConstant: PresetGlyph.size.height + 4).isActive = true
            return button
        }
        let lines = stride(from: 0, to: buttons.count, by: 8).map { start in
            let line = NSStackView(
                views: Array(buttons[start..<min(start + 8, buttons.count)]))
            line.orientation = .horizontal
            line.spacing = 2
            return line
        }
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 4, right: 12)
        column.frame = NSRect(origin: .zero, size: column.fittingSize)
        let item = NSMenuItem()
        item.view = column
        return item
    }
```

Preserve any existing button styling lines from the current `presetRow()`
(lines 133-142) not repeated here — this is a restructure, not a restyle.

- [ ] **Step 3: Menu construction — two sections + policy toggle**

Replace lines 29-36 of `menuNeedsUpdate`:

```swift
        rebuildMenuPresets()
        let groups = coordinator.magnetGroupSummaries()

        // PRD §4: reflow sits at the top. Two explicit targets — the display
        // row is always there; the group row appears when the frontmost
        // window is in an active group. No more flipping header.
        menu.addItem(sectionHeader("Reflow this display"))
        menu.addItem(presetRows(target: ReflowTarget.display))
        let keep = coordinator.reflowSettings().keepGroupsOnDisplayReflow
        let keepItem = actionItem("Keep magnet groups together",
                                  #selector(toggleKeepGroups))
        keepItem.indentationLevel = 1
        keepItem.state = keep ? .on : .off
        menu.addItem(keepItem)

        if let frontGroup = groups.first(where: { $0.isActive }) {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Reflow this group"))
            menu.addItem(presetRows(target: ReflowTarget.group(frontGroup.id)))
        }
        menu.addItem(.separator())
```

(`GroupSummary.isActive` today means "owns the frontmost window" — verify at
~line 359 and keep that meaning; if it means merely "has ≥2 open windows",
use the summary field that identifies the frontmost-owning group instead.)

- [ ] **Step 4: Per-group glyph rows in the Groups submenu**

In `groupItem(_:)` (line 163), after the `Ungroup` item (line 188):

```swift
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Reflow"))
        submenu.addItem(presetRows(target: ReflowTarget.group(group.id)))
```

- [ ] **Step 5: Action routes by target**

Replace `reflowPreset` (lines 252-257) and add the toggle:

```swift
    @objc private func reflowPreset(_ sender: NSButton) {
        guard menuPresets.indices.contains(sender.tag) else { return }
        let preset = menuPresets[sender.tag].preset
        if let raw = sender.identifier?.rawValue,
           raw.hasPrefix("reflow-group-"),
           let id = UUID(uuidString: String(raw.dropFirst("reflow-group-".count))) {
            coordinator.reflowGroup(preset, groupID: id)
        } else {
            coordinator.reflowDisplay(preset)
        }
        // A button inside a menu item's view does not dismiss the menu itself.
        statusItem.menu?.cancelTracking()
    }

    @objc private func toggleKeepGroups() {
        coordinator.updateReflowSettings {
            $0.keepGroupsOnDisplayReflow.toggle()
        }
    }
```

- [ ] **Step 6: Build and full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed" | tail -1`
Expected: build complete, tests PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(menu): display and group reflow rows, wrapped glyphs, keep-groups toggle"
```

---

### Task 12: Preferences — Reflows tab

**Files:**
- Create: `Sources/Ferrite/ReflowsPreferencesView.swift`
- Modify: `Sources/Ferrite/PreferencesWindowController.swift`

- [ ] **Step 1: View + model**

Create `Sources/Ferrite/ReflowsPreferencesView.swift`:

```swift
import SwiftUI
import FerriteCore

/// Custom reflow presets (pinned to the menu's glyph rows) and the
/// display-reflow group policy. The glyph preview is the solver's own answer
/// (PresetGlyph), so what you see is exactly what clicking it will do.
struct ReflowsPreferencesView: View {
    @ObservedObject var model: ReflowsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keep magnet groups together when reflowing a display",
                   isOn: Binding(
                       get: { model.keepGroups },
                       set: { model.setKeepGroups($0) }))
            Text("Off (default): a display reflow places every window "
                 + "individually and dissolves its magnet groups. "
                 + "On: each group is placed as one tile and keeps its shape.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Custom presets").font(.headline)
                Spacer()
                Button("Add") { model.addPreset() }
            }
            if model.presets.isEmpty {
                Text("Custom presets appear as extra glyphs in the menu's "
                     + "reflow rows — a fixed column count, an exact grid, "
                     + "or a main-centre split with your own proportions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(model.presets) { preset in
                    CustomPresetRow(entry: preset, model: model)
                }
                .onDelete { model.removePresets(at: $0) }
            }
        }
        .padding(4)
    }
}

private struct CustomPresetRow: View {
    let entry: CustomReflowPreset
    @ObservedObject var model: ReflowsPreferencesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: PresetGlyph.image(for: entry.preset))
            TextField("Name", text: Binding(
                get: { entry.name },
                set: { model.rename(entry.id, to: $0) }))
                .frame(width: 140)
            kindPicker
            parameterControls
            Spacer()
            Button(role: .destructive) { model.remove(entry.id) }
                label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private var kindPicker: some View {
        Picker("", selection: Binding(
            get: { PresetKind(entry.preset) },
            set: { model.setKind($0, for: entry.id) })) {
            Text("Columns").tag(PresetKind.columns)
            Text("Grid").tag(PresetKind.grid)
            Text("Main centre").tag(PresetKind.mainCenter)
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private var parameterControls: some View {
        switch entry.preset {
        case .fixedColumns(let count):
            Stepper("\(count) wide", value: Binding(
                get: { count },
                set: { model.update(entry.id, preset: .fixedColumns($0)) }),
                in: 1...12)
        case .fixedGrid(let columns, let rows):
            Stepper("\(columns) wide", value: Binding(
                get: { columns },
                set: { model.update(entry.id,
                                    preset: .fixedGrid(columns: $0, rows: rows)) }),
                in: 1...12)
            Stepper("\(rows) tall", value: Binding(
                get: { rows },
                set: { model.update(entry.id,
                                    preset: .fixedGrid(columns: columns, rows: $0)) }),
                in: 1...8)
        case .mainCenter(let fraction, let sideCapacity):
            Stepper("centre \(Int(fraction * 100))%", value: Binding(
                get: { Int(fraction * 100) },
                set: { model.update(entry.id, preset: .mainCenter(
                    fraction: Double($0) / 100, sideCapacity: sideCapacity)) }),
                in: 20...90, step: 2)
            Stepper("\(sideCapacity ?? 0 == 0 ? "∞" : String(sideCapacity!)) per side",
                    value: Binding(
                get: { sideCapacity ?? 0 },
                set: { model.update(entry.id, preset: .mainCenter(
                    fraction: fraction, sideCapacity: $0 == 0 ? nil : $0)) }),
                in: 0...8)
        default:
            EmptyView()
        }
    }
}

/// The three editable kinds; switching kinds swaps sensible defaults in.
enum PresetKind: Hashable {
    case columns, grid, mainCenter

    init(_ preset: GroupLayoutSolver.Preset) {
        switch preset {
        case .fixedColumns: self = .columns
        case .fixedGrid: self = .grid
        default: self = .mainCenter
        }
    }

    var defaultPreset: GroupLayoutSolver.Preset {
        switch self {
        case .columns: return .fixedColumns(3)
        case .grid: return .fixedGrid(columns: 3, rows: 2)
        case .mainCenter: return .mainCenter(fraction: 0.66, sideCapacity: 4)
        }
    }
}

/// Bridges the coordinator's ReflowStore to SwiftUI.
final class ReflowsPreferencesModel: ObservableObject {
    @Published var presets: [CustomReflowPreset] = []
    @Published var keepGroups = false
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        // Every store write (menu toggle included) reloads this model —
        // finding 16 corollary: cached windows freeze without a hook.
        coordinator.onReflowSettingsChanged = { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        let settings = coordinator.reflowSettings()
        presets = settings.customPresets
        keepGroups = settings.keepGroupsOnDisplayReflow
    }

    func setKeepGroups(_ on: Bool) {
        coordinator.updateReflowSettings { $0.keepGroupsOnDisplayReflow = on }
    }

    func addPreset() {
        coordinator.updateReflowSettings {
            $0.customPresets.append(CustomReflowPreset(
                name: "Custom \($0.customPresets.count + 1)",
                preset: .fixedGrid(columns: 3, rows: 2)))
        }
    }

    func remove(_ id: UUID) {
        coordinator.updateReflowSettings {
            $0.customPresets.removeAll { $0.id == id }
        }
    }

    func removePresets(at offsets: IndexSet) {
        coordinator.updateReflowSettings {
            $0.customPresets.remove(atOffsets: offsets)
        }
    }

    func rename(_ id: UUID, to name: String) {
        coordinator.updateReflowSettings {
            guard let index = $0.customPresets.firstIndex(where: { $0.id == id })
            else { return }
            $0.customPresets[index].name = name
        }
    }

    func update(_ id: UUID, preset: GroupLayoutSolver.Preset) {
        coordinator.updateReflowSettings {
            guard let index = $0.customPresets.firstIndex(where: { $0.id == id })
            else { return }
            $0.customPresets[index].preset = preset
        }
    }

    func setKind(_ kind: PresetKind, for id: UUID) {
        update(id, preset: kind.defaultPreset)
    }
}
```

- [ ] **Step 2: Wire the tab**

In `PreferencesWindowController`: add a retained `reflowsModel` (same pattern
as `layoutsModel`, lines 8-9 and 27-30), reload it in the re-show branch
(line 21 area), and add the tab in `PreferencesRootView`:

```swift
            ReflowsPreferencesView(model: reflowsModel)
                .tabItem { Text("Reflows") }
```

(`PreferencesRootView` gains a third `@ObservedObject`; thread it through the
`NSHostingController` init the same way the other two models are.)

- [ ] **Step 3: Build and full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed" | tail -1`
Expected: build complete, tests PASS.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(prefs): Reflows tab - custom presets editor and group policy"
```

---

### Task 13: Docs, install, live acceptance

**Files:**
- Modify: `docs/GUIDE.md` (menu table ~line 40, reflow section, troubleshooting)
- Modify: `docs/BACKLOG.md` (shipped table + acceptance note after the live run)
- Modify: `docs/HANDOFF.md` (state line)

- [ ] **Step 1: GUIDE updates**

- Menu table: replace the single reflow row's description with the two-row
  structure, the keep-groups toggle, and per-group submenu rows.
- Reflow presets section: document the five new built-ins (one line each,
  matching the spec table's semantics), custom presets (three kinds, where
  to define them, that glyphs are solver-drawn), fixed-zone semantics
  (empty cells stay empty; overflow z-stacks), and the explode-vs-keep
  policy with its default.
- Preferences section: describe the Reflows tab.

- [ ] **Step 2: BACKLOG + HANDOFF**

- Move the M6 "Next" bullet into the shipped table as `v0.12.0-m6` **after**
  live acceptance passes (Step 4) — not before.
- HANDOFF state line: mention M6 shipped.

- [ ] **Step 3: Install**

```bash
./scripts/install.sh
```

Expected: daemon restarts on the new build; Accessibility grant survives
(stable identity, finding 9).

- [ ] **Step 4: Live acceptance protocol (user at the machine)**

1. **Two rows.** Open the menu with no group: only "Reflow this display" +
   wrapped glyph lines + the Keep-toggle. Mate two windows, focus one, reopen:
   "Reflow this group" row appears with the same glyphs.
2. **New built-ins on the display row:** main-centre puts the frontmost
   window in the middle; mirrored main-side anchors right; bsp spirals;
   cascade staggers with the frontmost on top; monocle maximizes everything.
3. **Custom preset end-to-end:** Preferences → Reflows → Add → Grid 7×3 →
   glyph appears in both menu rows; clicking it on the ultrawide produces
   21 fixed cells with empties where windows run out. Then the user's
   main-centre 66%/4-per-side variant.
4. **Explode (default):** with a 2-window group on the display, click a
   display glyph → all windows reflow, the Groups menu no longer lists the
   group.
5. **Keep:** toggle "Keep magnet groups together" (checkmark flips; the
   Reflows tab toggle follows — hook check), reflow the display → the group
   occupies one cell with its formation intact and still appears in Groups.
6. **Group row + submenu row** both reflow only the group, inside its own
   bounding box; `lastGroupPreset` reapply (Grow frontmost) still works after.
7. Record results (and any live-found defects, fixed and re-verified) in
   BACKLOG per convention; complete Step 2's shipped-table move.

- [ ] **Step 5: Tag and push**

```bash
git add -A && git commit -m "docs: M6 shipped - reflow presets v2 live-verified"
git tag v0.12.0-m6
git push origin main v0.12.0-m6
```

---

## Self-review notes (kept honest)

- **Spec coverage:** built-ins (Tasks 1-4), customs (Task 5, 8, 12), Codable
  (6), remap (7), policy + explode-dissolve (10), two rows + wrapping +
  toggle + per-group rows (11), Reflows tab + hook (12), glyphs (9), docs +
  live protocol (13). Ordering invariant asserted in Tasks 3-5 tests.
- **Anchors drift:** line numbers are from `1f9b5c7`; every task re-reads its
  file before editing.
- **Task 10/11 carry the only real uncertainty** (exact `Member`/
  `GroupSummary` field names); both tasks say to resolve against the live
  struct rather than invent fields, and finding 20 (one identity path)
  governs the member-resolution move.
