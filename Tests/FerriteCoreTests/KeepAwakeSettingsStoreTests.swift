import XCTest
@testable import FerriteCore

final class KeepAwakeSettingsStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("power.json")
    }

    func testMissingFileDefaultsOff() throws {
        XCTAssertFalse(KeepAwakeSettingsStore(url: try temporaryURL()).load().keepAwakeEnabled)
    }

    func testEnabledPreferenceRoundTrips() throws {
        let store = KeepAwakeSettingsStore(url: try temporaryURL())
        try store.save(KeepAwakeSettings(keepAwakeEnabled: true))
        XCTAssertTrue(store.load().keepAwakeEnabled)
    }

    func testUnreadableFileFailsOff() throws {
        let url = try temporaryURL()
        try Data("not-json".utf8).write(to: url)
        XCTAssertFalse(KeepAwakeSettingsStore(url: url).load().keepAwakeEnabled)
    }
}
