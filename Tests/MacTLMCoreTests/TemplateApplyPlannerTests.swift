import XCTest
@testable import MacTLMCore

final class TemplateApplyPlannerTests: XCTestCase {
    let capturedMetrics = DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0)
    let sameTarget = TemplateApplyPlanner.Target(
        info: DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0),
        visibleArea: CGRect(x: 0, y: 0, width: 3440, height: 1415))
    let laptopTarget = TemplateApplyPlanner.Target(
        info: DisplayInfo(id: "LAPTOP", width: 1600, height: 1000, scale: 2.0),
        visibleArea: CGRect(x: 0, y: 25, width: 1600, height: 975))

    private func layout(entries: [LayoutEntry],
                        stageMode: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: "T", displayID: "EXT", displayName: "UltraWide",
                      displayMetrics: capturedMetrics, stageMode: stageMode,
                      entries: entries, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, optional: Bool = false,
                       z: Int = 0, title: String = "") -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, title: title,
                    frame: NormalizedFrame(x: 0.25, y: 0.0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: optional)
    }

    func testPartitionsRunningVsMissing() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("running.app"), entry("missing.app", z: 1)]),
            runningBundleIDs: ["running.app"], excludedBundleIDs: [],
            target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["missing.app"])
        XCTAssertEqual(Set(plan.placements.map(\.bundleID)), ["running.app", "missing.app"])
    }

    func testComputesTargetRects() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("a")]),
            runningBundleIDs: ["a"], excludedBundleIDs: [], target: sameTarget)
        let rect = plan.placements[0].targetRect
        XCTAssertEqual(rect.minX, 860, accuracy: 0.001)   // 0.25 * 3440
        XCTAssertEqual(rect.width, 1720, accuracy: 0.001) // 0.5 * 3440
        XCTAssertEqual(rect.height, 1273.5, accuracy: 0.001) // 0.9 * 1415
    }

    func testExcludedAppsAreLaunchedButNotPlaced() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("com.adobe.illustrator")]),
            runningBundleIDs: [], excludedBundleIDs: ["com.adobe.illustrator"],
            target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["com.adobe.illustrator"])
        XCTAssertTrue(plan.placements.isEmpty, "excluded apps launch-only (PRD §9)")
    }

    func testOptionalEntriesSkippedWhenAdaptingToSmallerDisplay() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("keep"), entry("skipme", optional: true, z: 1)]),
            runningBundleIDs: [], excludedBundleIDs: [], target: laptopTarget)
        XCTAssertTrue(plan.adapted)
        XCTAssertEqual(plan.placements.map(\.bundleID), ["keep"])
        XCTAssertEqual(plan.appsToLaunch, ["keep"], "skipped optionals aren't launched either")
    }

    func testOptionalEntriesKeptOnSameDisplay() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("keep"), entry("opt", optional: true, z: 1)]),
            runningBundleIDs: ["keep", "opt"], excludedBundleIDs: [], target: sameTarget)
        XCTAssertFalse(plan.adapted)
        XCTAssertEqual(plan.placements.count, 2)
    }

    func testLaunchListIsDeduplicatedAndOrdered() {
        // Two windows of the same missing app → one launch.
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("multi"), entry("multi", z: 1)]),
            runningBundleIDs: [], excludedBundleIDs: [], target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["multi"])
        XCTAssertEqual(plan.placements.count, 2)
    }

    func testMatchingRecordsCarrySlotTitlePin() {
        let entries = [
            LayoutEntry(bundleID: "arc", title: "Work",
                        frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                        zIndex: 0, pinPattern: "Work", optional: false),
            LayoutEntry(bundleID: "arc", title: "Personal",
                        frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9),
                        zIndex: 1, pinPattern: nil, optional: false),
        ]
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: entries),
            runningBundleIDs: ["arc"], excludedBundleIDs: [], target: sameTarget)
        let records = plan.matchingRecords(forBundleID: "arc")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].slot, 0)
        XCTAssertEqual(records[0].title, "Work")
        XCTAssertEqual(records[0].pinPattern, "Work")
        XCTAssertEqual(records[1].title, "Personal")
    }
}
