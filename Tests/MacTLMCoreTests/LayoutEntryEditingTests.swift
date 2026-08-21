import XCTest
@testable import MacTLMCore

final class LayoutEntryEditingTests: XCTestCase {
    private func entry(_ bundleID: String, z: Int, optional: Bool = false) -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, titleHash: testHash("\(bundleID) window"),
                    frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: optional)
    }

    private func library(entries: [LayoutEntry]) -> LayoutLibrary {
        LayoutLibrary(layouts: [
            MonitorLayout(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                          name: "W", displayID: "A", displayName: "DA",
                          displayMetrics: DisplayInfo(id: "A", width: 1600,
                                                      height: 1000, scale: 2.0),
                          stageMode: .leaveOthers, entries: entries,
                          createdAt: Date(timeIntervalSince1970: 0)),
        ])
    }

    func testRemoveEntryDropsItAndReindexesZ() {
        var lib = library(entries: [entry("a", z: 0), entry("b", z: 1), entry("c", z: 2)])
        let id = lib.layouts[0].id
        lib.removeEntry(atIndex: 1, fromLayoutID: id)
        XCTAssertEqual(lib.layouts[0].entries.map(\.bundleID), ["a", "c"])
        XCTAssertEqual(lib.layouts[0].entries.map(\.zIndex), [0, 1],
                       "z reindexed contiguously so stacking stays well-ordered")
    }

    func testRemoveEntryIgnoresBadIndexOrID() {
        var lib = library(entries: [entry("a", z: 0)])
        lib.removeEntry(atIndex: 5, fromLayoutID: lib.layouts[0].id)
        lib.removeEntry(atIndex: 0, fromLayoutID: UUID())
        XCTAssertEqual(lib.layouts[0].entries.count, 1)
    }

    func testSetEntryOptional() {
        var lib = library(entries: [entry("a", z: 0), entry("b", z: 1)])
        let id = lib.layouts[0].id
        lib.setEntryOptional(true, atIndex: 1, inLayoutID: id)
        XCTAssertFalse(lib.layouts[0].entries[0].optional)
        XCTAssertTrue(lib.layouts[0].entries[1].optional)
    }

    func testRemovingLastEntryLeavesAnEmptyLayoutNotACrash() {
        var lib = library(entries: [entry("a", z: 0)])
        lib.removeEntry(atIndex: 0, fromLayoutID: lib.layouts[0].id)
        XCTAssertTrue(lib.layouts[0].entries.isEmpty)
        XCTAssertEqual(lib.layouts.count, 1)
    }
}
