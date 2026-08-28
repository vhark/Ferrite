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
