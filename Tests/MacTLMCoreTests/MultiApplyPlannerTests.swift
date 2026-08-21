import XCTest
@testable import MacTLMCore

final class MultiApplyPlannerTests: XCTestCase {
    private func target(_ id: String, x: CGFloat) -> TemplateApplyPlanner.Target {
        TemplateApplyPlanner.Target(
            info: DisplayInfo(id: id, width: 1600, height: 1000, scale: 2.0),
            visibleArea: CGRect(x: x, y: 25, width: 1600, height: 975))
    }

    private func layout(_ name: String, display: String, stage: StageMode,
                        entries: [LayoutEntry]) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: entries,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, z: Int) -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, titleHash: nil,
                    frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: false)
    }

    func testMergesItemsPerDisplay() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("a", z: 0)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("b", z: 0)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items[0].visibleArea.minX, 0)
        XCTAssertEqual(plan.items[1].visibleArea.minX, 1600)
        XCTAssertEqual(plan.memberBundleIDs, ["a", "b"])
    }

    func testStackingOrderMergedBackmostFirstAcrossDisplays() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("front", z: 0), entry("deep", z: 9)]),
                 target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("middle", z: 3)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.appStackingOrder, ["deep", "middle", "front"])
    }

    func testLaunchListDedupedAcrossDisplaysBackmostFirst() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("shared", z: 1)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("shared", z: 7), entry("solo", z: 2)]),
                 target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.appsToLaunch, ["shared", "solo"],
                       "shared app launches once, ranked by its backmost window")
    }

    func testAnyClearStageMakesTheWholeOperationClearStage() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("a", z: 0)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .clearStage,
                        entries: [entry("b", z: 0)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.stageMode, .clearStage)
    }

    func testRunningAppsAreNotLaunchedButStillStacked() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("running", z: 0)]), target("A", x: 0)),
            ],
            runningBundleIDs: ["running"], excludedBundleIDs: [])
        XCTAssertTrue(plan.appsToLaunch.isEmpty)
        XCTAssertEqual(plan.appStackingOrder, ["running"])
    }

    func testSingleRequestMatchesSingleLayoutPlan() {
        let single = layout("W", display: "A", stage: .leaveOthers,
                            entries: [entry("a", z: 0), entry("b", z: 1)])
        let multi = MultiApplyPlanner.plan(requests: [(single, target("A", x: 0))],
                                           runningBundleIDs: [], excludedBundleIDs: [])
        let direct = TemplateApplyPlanner.plan(layout: single, runningBundleIDs: [],
                                               excludedBundleIDs: [],
                                               target: target("A", x: 0))
        XCTAssertEqual(multi.appStackingOrder, direct.appStackingOrder)
        XCTAssertEqual(multi.appsToLaunch, direct.appsToLaunch)
        XCTAssertEqual(multi.items[0].plan.placements, direct.placements)
    }
}
