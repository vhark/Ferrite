import XCTest
@testable import FerriteCore

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
