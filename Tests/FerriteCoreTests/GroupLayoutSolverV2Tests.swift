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
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0]!.width, 720, accuracy: 0.01)   // 60% of 1200
        XCTAssertEqual(result[0]!.maxX, 1300, accuracy: 0.01)   // anchored right
        XCTAssertEqual(result[0]!.height, 800, accuracy: 0.01)
        // The three side tiles stack full-width-of-side on the left, in tile
        // order — pinning minY is what stops a reversed stack from passing.
        let stripHeight = 800.0 / 3
        for (offset, id) in (1...3).enumerated() {
            XCTAssertEqual(result[id]!.minX, 100, accuracy: 0.01)
            XCTAssertEqual(result[id]!.width, 480, accuracy: 0.01)
            XCTAssertEqual(result[id]!.height, stripHeight, accuracy: 0.01)
            XCTAssertEqual(result[id]!.minY, 50 + stripHeight * Double(offset),
                           accuracy: 0.01)
        }
    }

    func testMainSideMirroredIsExactMirrorOfMainSide() {
        let straight = GroupLayoutSolver.solve(tiles: rankedTiles(3),
                                               preset: .mainSide, in: bounds, gap: 0)
        let mirrored = GroupLayoutSolver.solve(tiles: rankedTiles(3),
                                               preset: .mainSideMirrored,
                                               in: bounds, gap: 0)
        XCTAssertEqual(mirrored.count, straight.count)
        for (id, rect) in straight {
            let flipped = CGRect(x: bounds.minX + bounds.maxX - rect.maxX,
                                 y: rect.minY, width: rect.width, height: rect.height)
            XCTAssertEqual(mirrored[id]!.minX, flipped.minX, accuracy: 0.01)
            XCTAssertEqual(mirrored[id]!.width, flipped.width, accuracy: 0.01)
            XCTAssertEqual(mirrored[id]!.minY, flipped.minY, accuracy: 0.01)
            XCTAssertEqual(mirrored[id]!.height, flipped.height, accuracy: 0.01)
        }
    }

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
        // the spill tiles cycle back into cells z-stacked.
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
}
