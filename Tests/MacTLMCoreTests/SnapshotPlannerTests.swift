import XCTest
@testable import MacTLMCore

final class SnapshotPlannerTests: XCTestCase {
    let laptop = SnapshotPlanner.Display(
        info: DisplayInfo(id: "LAPTOP", width: 1600, height: 1000, scale: 2.0),
        name: "Built-in", visibleArea: CGRect(x: 0, y: 25, width: 1600, height: 975))
    let external = SnapshotPlanner.Display(
        info: DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0),
        name: "UltraWide", visibleArea: CGRect(x: 1600, y: 0, width: 3440, height: 1440))

    private func window(_ bundleID: String, x: CGFloat, y: CGFloat,
                        w: CGFloat = 400, h: CGFloat = 300, z: Int,
                        title: String = "") -> SnapshotPlanner.Window {
        SnapshotPlanner.Window(bundleID: bundleID, title: title,
                               frame: CGRect(x: x, y: y, width: w, height: h), zIndex: z)
    }

    func testAssignsWindowsToDisplayContainingCenter() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 100, y: 100, z: 0),
                      window("b", x: 2000, y: 100, z: 1)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 2)
        let laptopLayout = layouts.first { $0.displayID == "LAPTOP" }!
        let extLayout = layouts.first { $0.displayID == "EXT" }!
        XCTAssertEqual(laptopLayout.entries.map(\.bundleID), ["a"])
        XCTAssertEqual(extLayout.entries.map(\.bundleID), ["b"])
    }

    func testNormalizesFramesAgainstOwnDisplay() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 400, y: 268.75, w: 400, h: 487.5, z: 0)],
            displays: [laptop], date: Date(timeIntervalSince1970: 0))
        let entry = layouts[0].entries[0]
        XCTAssertEqual(entry.frame.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.w, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.h, 0.5, accuracy: 0.001)
    }

    func testReindexesZPerDisplayPreservingOrder() {
        // Global z: b(0, ext), a(1, laptop), c(2, laptop)
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("b", x: 2000, y: 100, z: 0),
                      window("a", x: 100, y: 100, z: 1),
                      window("c", x: 200, y: 200, z: 2)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        let laptopLayout = layouts.first { $0.displayID == "LAPTOP" }!
        XCTAssertEqual(laptopLayout.entries.map(\.bundleID), ["a", "c"])
        XCTAssertEqual(laptopLayout.entries.map(\.zIndex), [0, 1],
                       "per-display z reindexed from 0 preserving global order")
    }

    func testOffscreenWindowFallsBackToNearestDisplay() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: -5000, y: -5000, z: 0)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0].displayID, "LAPTOP")
    }

    func testDisplaysWithoutWindowsProduceNoLayout() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 100, y: 100, z: 0)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 1)
    }

    func testAllLayoutsShareNameAndStageMode() {
        let layouts = SnapshotPlanner.plan(
            name: "Design + Comms", stageMode: .clearStage,
            windows: [window("a", x: 100, y: 100, z: 0),
                      window("b", x: 2000, y: 100, z: 1)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(layouts.allSatisfy { $0.name == "Design + Comms" })
        XCTAssertTrue(layouts.allSatisfy { $0.stageMode == .clearStage })
    }
}
