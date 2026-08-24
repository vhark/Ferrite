import XCTest
@testable import FerriteCore

final class GroupReflowPlannerTests: XCTestCase {
    private func window(_ id: Int, _ bundle: String, _ slot: Int, _ frame: CGRect)
        -> GroupReflowPlanner.LiveWindow {
        GroupReflowPlanner.LiveWindow(id: id, bundleID: bundle, slot: slot, frame: frame)
    }

    func testBoundsAreTheGroupsBoundingBox() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 500, height: 400)),
                   window(2, "b", 0, CGRect(x: 508, y: 0, width: 500, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertEqual(plan?.bounds, CGRect(x: 0, y: 0, width: 1008, height: 400))
    }

    func testWeightsComeFromMemberRanks() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0, weight: 3),
                                          MagnetMember(bundleID: "b", slot: 0, weight: 1)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400)),
                   window(2, "b", 0, CGRect(x: 408, y: 0, width: 400, height: 400))],
            // NOT .symmetric: M3a deliberately equalises weights there (PRD §3.3),
            // so only a weight-honouring preset can show member ranks arriving.
            preset: .treemap(bias: .center), gap: 0, minimumSize: .zero)
        let frames = plan!.frames
        XCTAssertGreaterThan(frames[1]!.width, frames[2]!.width * 2,
                             "a weight-3 member must get roughly three times the area")
    }

    func testMembersWithNoLiveWindowAreSkipped() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "gone", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400)),
                   window(2, "b", 0, CGRect(x: 408, y: 0, width: 400, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertEqual(plan?.frames.count, 2)
    }

    func testAGroupWithOneLiveWindowHasNothingToReflow() {
        let group = MagnetGroup(members: [MagnetMember(bundleID: "a", slot: 0),
                                          MagnetMember(bundleID: "b", slot: 0)])
        let plan = GroupReflowPlanner.plan(
            group: group,
            live: [window(1, "a", 0, CGRect(x: 0, y: 0, width: 400, height: 400))],
            preset: .columns, gap: 8, minimumSize: .zero)
        XCTAssertNil(plan)
    }

    func testFramesStayInsideTheBoundingBox() {
        let group = MagnetGroup(members: (0..<4).map {
            MagnetMember(bundleID: "a", slot: $0, weight: Double($0 + 1))
        })
        let live = (0..<4).map {
            window($0 + 1, "a", $0,
                   CGRect(x: CGFloat($0) * 400, y: 0, width: 392, height: 800))
        }
        let plan = GroupReflowPlanner.plan(group: group, live: live,
                                           preset: .treemap(bias: .center),
                                           gap: 8, minimumSize: .zero)!
        for frame in plan.frames.values {
            XCTAssertTrue(plan.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(frame) escaped \(plan.bounds)")
        }
    }
}
