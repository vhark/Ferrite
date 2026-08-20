import XCTest
@testable import MacTLMCore

final class ConfigurationRecordsMutationTests: XCTestCase {
    private func record(slot: Int, title: String, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, title: title,
                     frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.5),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testSetPinPatternOnSlot() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work"), record(slot: 1, title: "Personal")],
        ])
        records.setPinPattern("Work", bundleID: "arc", slot: 0)
        XCTAssertEqual(records.apps["arc"]?[0].pinPattern, "Work")
        XCTAssertNil(records.apps["arc"]?[1].pinPattern)
    }

    func testClearPinPatternWithNil() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work", pin: "Work")],
        ])
        records.setPinPattern(nil, bundleID: "arc", slot: 0)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern)
    }

    func testSetPinPatternIgnoresUnknownAppOrSlot() {
        var records = ConfigurationRecords(apps: ["arc": [record(slot: 0, title: "Work")]])
        records.setPinPattern("X", bundleID: "nope", slot: 0)
        records.setPinPattern("X", bundleID: "arc", slot: 9)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern)
        XCTAssertNil(records.apps["nope"])
    }

    func testForgetAppRemovesEveryRecord() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work")],
            "junk": [record(slot: 0, title: "Open")],
        ])
        records.forgetApp(bundleID: "junk")
        XCTAssertNil(records.apps["junk"])
        XCTAssertEqual(records.apps.count, 1)
    }

    func testEmptyPinTreatedAsCleared() {
        var records = ConfigurationRecords(apps: ["arc": [record(slot: 0, title: "W")]])
        records.setPinPattern("   ", bundleID: "arc", slot: 0)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern,
                     "whitespace-only pins must clear, not match everything")
    }
}
