import XCTest
@testable import MacTLMCore

final class ExcludeListTests: XCTestCase {
    func testDefaultsExcludeKnownHostileApps() {
        XCTAssertTrue(ExcludeList.defaults.isExcluded("com.adobe.illustrator"))
        XCTAssertFalse(ExcludeList.defaults.isExcluded("com.apple.TextEdit"))
    }

    func testLoadMissingFileYieldsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        XCTAssertEqual(ExcludeList.load(from: url), ExcludeList.defaults)
    }

    func testSaveLoadRoundTripWithUserAddition() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var list = ExcludeList.defaults
        list.bundleIDs.insert("com.example.fighty")
        try list.save(to: url)
        XCTAssertEqual(ExcludeList.load(from: url), list)
    }
}
