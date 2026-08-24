import XCTest
@testable import FerriteCore

final class LayoutStoreTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadMissingConfigReturnsEmpty() {
        XCTAssertEqual(store.load(configKey: "nope"), ConfigurationRecords())
    }

    func testSaveThenLoadRoundTrips() throws {
        var records = ConfigurationRecords()
        records.apps["com.apple.finder"] = [
            WindowRecord(slot: 0, titleHash: "h:Downloads",
                         frame: NormalizedFrame(x: 0.02, y: 0.20, w: 0.16, h: 0.60),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        try store.save(records, configKey: "laptop")
        XCTAssertEqual(store.load(configKey: "laptop"), records)
    }

    func testCorruptFileLoadsAsEmptyInsteadOfCrashing() throws {
        let url = directory.appendingPathComponent("bad.json")
        try Data("not json{".utf8).write(to: url)
        XCTAssertEqual(store.load(configKey: "bad"), ConfigurationRecords())
    }

    func testSavedFileIsHumanReadableJSON() throws {
        try store.save(ConfigurationRecords(), configKey: "laptop")
        let text = try String(contentsOf: directory.appendingPathComponent("laptop.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"apps\""))
    }
}
