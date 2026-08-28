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
}
