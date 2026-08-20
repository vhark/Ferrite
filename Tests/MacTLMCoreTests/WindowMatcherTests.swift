import XCTest
@testable import MacTLMCore

final class WindowMatcherTests: XCTestCase {
    private func record(slot: Int, title: String, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, title: title,
                     frame: NormalizedFrame(x: Double(slot) * 0.1, y: 0, w: 0.2, h: 0.9),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testOrderFallbackWhenTitlesAllChanged() {
        let records = [record(slot: 0, title: "Old A"), record(slot: 1, title: "Old B")]
        let windows = [WindowCandidate(id: 10, title: "New X", order: 0),
                       WindowCandidate(id: 11, title: "New Y", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0)
        XCTAssertEqual(result[11]?.slot, 1)
    }

    func testExactTitleMatchBeatsOrder() {
        let records = [record(slot: 0, title: "Work"), record(slot: 1, title: "Personal")]
        // Reopened in swapped order — titles must win.
        let windows = [WindowCandidate(id: 10, title: "Personal", order: 0),
                       WindowCandidate(id: 11, title: "Work", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testPinPatternBeatsExactTitle() {
        // Record 0 pins "Work"; window 11's title contains it, window 10 has the
        // exact old title of record 1. Pin claims first.
        let records = [record(slot: 0, title: "Anything", pin: "Work"),
                       record(slot: 1, title: "Work — Arc")]
        let windows = [WindowCandidate(id: 10, title: "Work — Arc", order: 0),
                       WindowCandidate(id: 11, title: "My Work Tabs", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0, "pin pattern claims the first title match")
        XCTAssertEqual(result[11]?.slot, 1, "remaining record falls through by order")
    }

    func testExtraWindowsAreLeftUnassigned() {
        let records = [record(slot: 0, title: "Only")]
        let windows = [WindowCandidate(id: 10, title: "Only", order: 0),
                       WindowCandidate(id: 11, title: "Extra", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[11])
    }

    func testFewerWindowsThanRecordsAssignsSubset() {
        let records = [record(slot: 0, title: "A"), record(slot: 1, title: "B")]
        let windows = [WindowCandidate(id: 10, title: "B", order: 0)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result.count, 1)
    }

    func testInvalidPinRegexIsIgnoredNotCrashing() {
        let records = [record(slot: 0, title: "A", pin: "([")]
        let windows = [WindowCandidate(id: 10, title: "A", order: 0)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0, "falls back to title/order matching")
    }

    func testPinnedRecordWithNoMatchingWindowFallsThrough() {
        let records = [record(slot: 0, title: "A", pin: "ZZZNOPE"),
                       record(slot: 1, title: "B")]
        let windows = [WindowCandidate(id: 10, title: "B", order: 0),
                       WindowCandidate(id: 11, title: "A", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testDuplicateIdenticalRecordsBothAssign() {
        let records = [record(slot: 0, title: "X"), record(slot: 0, title: "X")]
        let windows = [WindowCandidate(id: 10, title: "X", order: 0),
                       WindowCandidate(id: 11, title: "Y", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result.count, 2)
        XCTAssertNotNil(result[10])
        XCTAssertNotNil(result[11])
    }

    func testEmptyPinPatternIsIgnored() {
        let records = [record(slot: 0, title: "A", pin: ""),
                       record(slot: 1, title: "B")]
        let windows = [WindowCandidate(id: 10, title: "B", order: 0),
                       WindowCandidate(id: 11, title: "A", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testOrderFallbackDisabledLeavesUnmatchedWindowsAlone() {
        let records = [record(slot: 0, title: "Old A"), record(slot: 1, title: "Old B")]
        let windows = [WindowCandidate(id: 10, title: "Open", order: 0)]
        let result = WindowMatcher.assign(records: records, to: windows,
                                          allowOrderFallback: false)
        XCTAssertTrue(result.isEmpty, "no title match and no fallback -> nothing assigned")
    }

    func testOrderFallbackDisabledStillHonorsTitleAndPin() {
        let records = [record(slot: 0, title: "Work", pin: "Work"),
                       record(slot: 1, title: "Personal")]
        let windows = [WindowCandidate(id: 10, title: "Personal", order: 0),
                       WindowCandidate(id: 11, title: "Work", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows,
                                          allowOrderFallback: false)
        XCTAssertEqual(result[11]?.slot, 0)
        XCTAssertEqual(result[10]?.slot, 1)
    }
}
