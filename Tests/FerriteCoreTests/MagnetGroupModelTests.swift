import XCTest
@testable import FerriteCore

final class MagnetGroupModelTests: XCTestCase {
    private func member(_ bundle: String, _ slot: Int, weight: Double = 1) -> MagnetMember {
        MagnetMember(bundleID: bundle, slot: slot, weight: weight)
    }

    func testContainsFindsMemberByBundleAndSlot() {
        let group = MagnetGroup(members: [member("a", 0), member("b", 1)])
        XCTAssertTrue(group.contains(bundleID: "b", slot: 1))
        XCTAssertFalse(group.contains(bundleID: "b", slot: 0),
                       "slot is part of identity — a different window of the same app is not a member")
    }

    func testMergingGroupsUnionsMembersWithoutDuplicates() {
        var left = MagnetGroup(members: [member("a", 0), member("b", 0)])
        let right = MagnetGroup(members: [member("b", 0), member("c", 0)])
        left.merge(right)
        XCTAssertEqual(left.members.count, 3)
        XCTAssertTrue(left.contains(bundleID: "c", slot: 0))
    }

    func testMergePreservesTheHeavierWeightForASharedMember() {
        var left = MagnetGroup(members: [member("a", 0, weight: 3)])
        left.merge(MagnetGroup(members: [member("a", 0, weight: 1)]))
        XCTAssertEqual(left.members.count, 1)
        XCTAssertEqual(left.members[0].weight, 3, accuracy: 0.001,
                       "a merge must not silently demote a window the user had promoted")
    }

    func testRemovingTheSecondToLastMemberDissolvesTheGroup() {
        var group = MagnetGroup(members: [member("a", 0), member("b", 0)])
        XCTAssertTrue(group.remove(bundleID: "a", slot: 0))
        XCTAssertTrue(group.isDissolved, "a group of one is not a group")
    }

    func testAdjustWeightIsClampedToAUsableRange() {
        var group = MagnetGroup(members: [member("a", 0, weight: 1), member("b", 0)])
        for _ in 0..<20 { group.adjustWeight(bundleID: "a", slot: 0, by: 4) }
        XCTAssertLessThanOrEqual(group.members[0].weight, MagnetGroup.maximumWeight)
        for _ in 0..<40 { group.adjustWeight(bundleID: "a", slot: 0, by: 0.25) }
        XCTAssertGreaterThanOrEqual(group.members[0].weight, MagnetGroup.minimumWeight)
    }

    func testLegacyConfigurationRecordsWithoutGroupsStillDecode() throws {
        // The store is fail-soft: a decode failure returns an EMPTY store and the
        // next save overwrites the user's real data. A new non-optional field is
        // therefore a data-loss bug (BACKLOG finding 11). This is the guard.
        let legacy = """
        {"apps":{"com.apple.TextEdit":[{"slot":0,"frame":{"x":0,"y":0,"w":0.5,"h":0.5},"lastSeen":0}]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConfigurationRecords.self, from: legacy)
        XCTAssertEqual(decoded.apps.count, 1, "legacy payload must survive intact")
        XCTAssertTrue(decoded.groups.isEmpty)
    }

    func testConfigurationRecordsRoundTripWithGroups() throws {
        var records = ConfigurationRecords()
        records.groups = [MagnetGroup(members: [member("a", 0, weight: 2), member("b", 1)],
                                      resizeMode: .nudge)]
        let data = try JSONEncoder().encode(records)
        let back = try JSONDecoder().decode(ConfigurationRecords.self, from: data)
        XCTAssertEqual(back, records)
    }

    func testStandardResizeModeRoundTrips() throws {
        let group = MagnetGroup(members: [member("com.a", 0), member("com.b", 0)],
                                resizeMode: .standard)
        let data = try JSONEncoder().encode(group)
        let back = try JSONDecoder().decode(MagnetGroup.self, from: data)
        XCTAssertEqual(back.resizeMode, .standard)
    }

    func testDefaultResizeModeIsStillShrink() {
        let group = MagnetGroup(members: [member("com.a", 0), member("com.b", 0)])
        XCTAssertEqual(group.resizeMode, .shrink)
    }
}
