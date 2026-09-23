import XCTest
@testable import FerriteCore

final class DisplayReflowOrderTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 50, width: 1200, height: 900)

    private func frames(_ order: inout DisplayReflowOrder, _ ids: [Int],
                        preset: GroupLayoutSolver.Preset = .columns,
                        display: String = "desk", keepGroups: Bool = false,
                        membersByTile: [Int: Set<Int>] = [:]) -> [Int: CGRect] {
        let tiles = ids.enumerated().map {
            GroupLayoutSolver.Tile(id: $0.element, weight: Double(ids.count - $0.offset))
        }
        let ordered = order.orderedTiles(tiles, preset: preset, displayID: display,
                                         keepGroups: keepGroups, membersByTile: membersByTile)
        return GroupLayoutSolver.solve(tiles: ordered, preset: preset, in: bounds, gap: 8)
    }

    func testColumnsAndRowsToggleTheOriginalOrderDespiteFocusChanges() {
        for preset in [GroupLayoutSolver.Preset.columns, .rows] {
            var order = DisplayReflowOrder()
            let first = frames(&order, [1, 2, 3, 4], preset: preset)
            let reversed = frames(&order, [3, 1, 4, 2], preset: preset)
            for id in 1...4 {
                XCTAssertEqual(reversed[id], first[5 - id], "\(preset): window \(id)")
            }
            XCTAssertEqual(frames(&order, [2, 4, 1, 3], preset: preset), first)
        }
    }

    func testDifferentPresetStartsFreshAndComplexPresetsDoNotCycle() {
        var order = DisplayReflowOrder()
        _ = frames(&order, [1, 2, 3])
        _ = frames(&order, [1, 2, 3])
        for preset in [GroupLayoutSolver.Preset.grid, .fixedColumns(3), .bsp,
                       .mainCenter(fraction: 0.6, sideCapacity: nil), .cascade, .monocle] {
            let first = frames(&order, [2, 3, 1], preset: preset)
            XCTAssertEqual(frames(&order, [2, 3, 1], preset: preset), first)
        }
        var fresh = DisplayReflowOrder()
        XCTAssertEqual(frames(&order, [3, 1, 2]), frames(&fresh, [3, 1, 2]))
        XCTAssertEqual(frames(&order, [2, 1, 3], preset: .rows),
                       frames(&fresh, [2, 1, 3], preset: .rows))
    }

    func testWindowReplacementRestartsEvenWhenCountIsUnchanged() {
        var order = DisplayReflowOrder()
        _ = frames(&order, [1, 2, 3])
        var fresh = DisplayReflowOrder()
        let restarted = frames(&order, [4, 2, 1])
        XCTAssertEqual(restarted, frames(&fresh, [4, 2, 1]))
        let reversed = frames(&order, [1, 4, 2])
        XCTAssertEqual(reversed[1], restarted[4])
        XCTAssertEqual(reversed[4], restarted[1])
    }

    func testDisplaysCycleIndependentlyAndResetOnlyTheirOwnHistory() {
        var order = DisplayReflowOrder()
        let desk = frames(&order, [1, 2, 3])
        let laptop = frames(&order, [4, 5], display: "laptop")
        XCTAssertEqual(frames(&order, [3, 1, 2])[1], desk[3])
        order.reset(displayID: "desk")
        XCTAssertEqual(frames(&order, [5, 4], display: "laptop")[4], laptop[5])
        var fresh = DisplayReflowOrder()
        XCTAssertEqual(frames(&order, [2, 3, 1]), frames(&fresh, [2, 3, 1]))
    }

    func testKeptGroupsReverseAsTilesDespiteChangingFrontmostRepresentative() {
        var order = DisplayReflowOrder()
        let first = frames(&order, [5, 4, 3], keepGroups: true,
                           membersByTile: [4: [4, 2]])
        let reversed = frames(&order, [2, 3, 5], keepGroups: true,
                              membersByTile: [2: [2, 4]])
        XCTAssertEqual(reversed[3], first[5])
        XCTAssertEqual(reversed[2], first[4])
        XCTAssertEqual(reversed[5], first[3])
        let third = frames(&order, [3, 2, 5], keepGroups: true,
                          membersByTile: [2: [4, 2]])
        XCTAssertEqual(third[5], first[5])
        XCTAssertEqual(third[2], first[4])
        XCTAssertEqual(third[3], first[3])
    }

    func testGroupMembershipAndPolicyChangesRestartTheCycle() {
        var order = DisplayReflowOrder()
        _ = frames(&order, [1, 3, 4], keepGroups: true, membersByTile: [1: [1, 2]])
        var fresh = DisplayReflowOrder()
        XCTAssertEqual(frames(&order, [4, 1, 3], keepGroups: true,
                              membersByTile: [1: [1, 5]]),
                       frames(&fresh, [4, 1, 3], keepGroups: true,
                              membersByTile: [1: [1, 5]]))
        _ = frames(&order, [1, 2, 3], keepGroups: false)
        fresh = DisplayReflowOrder()
        XCTAssertEqual(frames(&order, [2, 3, 1], keepGroups: true),
                       frames(&fresh, [2, 3, 1], keepGroups: true))
    }

    func testEmptyOrSingleTileDoesNotRetainACycle() {
        for remaining in [[], [1]] {
            var order = DisplayReflowOrder()
            _ = frames(&order, [1, 2, 3])
            _ = frames(&order, remaining)
            var fresh = DisplayReflowOrder()
            XCTAssertEqual(frames(&order, [2, 3, 1]), frames(&fresh, [2, 3, 1]))
        }
    }
}
