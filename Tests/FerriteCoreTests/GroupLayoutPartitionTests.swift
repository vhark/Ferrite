import XCTest
@testable import FerriteCore

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
