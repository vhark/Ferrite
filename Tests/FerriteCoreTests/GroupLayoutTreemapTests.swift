import XCTest
@testable import FerriteCore

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
