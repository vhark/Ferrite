import XCTest
@testable import MacTLMCore

final class LegacyTitlePurgeTests: XCTestCase {
    func testLoadingALegacyLibraryRewritesItWithoutTitles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"layouts":[{"createdAt":"2026-08-19T00:00:00Z","displayID":"A",
        "displayMetrics":{"height":1000,"id":"A","scale":2,"width":1600},
        "displayName":"DA","entries":[{"bundleID":"b","frame":{"h":1,"w":1,"x":0,"y":0},
        "optional":false,"title":"Private Page","zIndex":0}],
        "id":"AAAAAAAA-0000-0000-0000-000000000001","name":"W",
        "stageMode":"leaveOthers"}]}
        """
        try Data(legacy.utf8).write(to: url)
        let store = LayoutLibraryStore(url: url)
        _ = store.loadPurgingLegacyTitles()
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Private Page"),
                       "loading must scrub legacy plaintext from disk")
        XCTAssertTrue(onDisk.contains("bundleID"), "the layout itself survives")
    }
}
