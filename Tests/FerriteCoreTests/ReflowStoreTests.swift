import XCTest
@testable import FerriteCore

final class ReflowStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflows-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testEmptyDefaultExplodesGroups() {
        let settings = ReflowStore(url: url).load()
        XCTAssertTrue(settings.customPresets.isEmpty)
        XCTAssertFalse(settings.keepGroupsOnDisplayReflow)
    }

    func testRoundTrip() throws {
        let store = ReflowStore(url: url)
        var settings = ReflowSettings()
        settings.customPresets = [
            CustomReflowPreset(name: "Wall 7×3",
                               preset: .fixedGrid(columns: 7, rows: 3)),
            CustomReflowPreset(name: "Big centre",
                               preset: .mainCenter(fraction: 0.66, sideCapacity: 4)),
        ]
        settings.keepGroupsOnDisplayReflow = true
        try store.save(settings)
        let back = store.load()
        XCTAssertEqual(back, settings)
    }

    func testUnknownFutureKeysAreTolerated() throws {
        // A payload written by a future Ferrite must not wipe the file
        // (finding 11's lesson, applied from day one).
        let json = """
        {"customPresets": [], "keepGroupsOnDisplayReflow": true,
         "someFutureKnob": 42}
        """
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertTrue(ReflowStore(url: url).load().keepGroupsOnDisplayReflow)
    }

    func testMissingKeysDecodeToDefaults() throws {
        try "{}".data(using: .utf8)!.write(to: url)
        let settings = ReflowStore(url: url).load()
        XCTAssertTrue(settings.customPresets.isEmpty)
        XCTAssertFalse(settings.keepGroupsOnDisplayReflow)
    }
}
