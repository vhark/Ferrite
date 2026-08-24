import XCTest
@testable import FerriteCore

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
