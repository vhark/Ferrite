import XCTest
@testable import FerriteCore

final class MagnetSettingsStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnets-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testAbsentFileYieldsTheMatingDefault() {
        let settings = MagnetSettingsStore(url: url).load()
        XCTAssertEqual(settings.mateReach, MagnetMating.defaultThreshold,
                       "first run must behave exactly like the built-in default")
    }

    func testRoundTrip() throws {
        let store = MagnetSettingsStore(url: url)
        var settings = MagnetSettings()
        settings.mateReach = 48
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testMissingKeyDecodesToTheDefaultNotZero() throws {
        // Finding 11: a fail-soft store that decodes emptiness writes that
        // emptiness back. A 0 reach here would silently disable mating.
        try "{}".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(MagnetSettingsStore(url: url).load().mateReach,
                       MagnetMating.defaultThreshold)
    }

    func testUnknownFutureKeysAreTolerated() throws {
        let json = """
        {"mateReach": 40, "someFutureKnob": 42}
        """
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(MagnetSettingsStore(url: url).load().mateReach, 40)
    }

    func testAnUnusableSmallReachIsClampedUp() throws {
        try #"{"mateReach": 0}"#.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(MagnetSettingsStore(url: url).load().mateReach,
                       MagnetSettings.minimumMateReach,
                       "a zero reach would disable mating with no way back")
        var written = MagnetSettings()
        written.mateReach = -20
        XCTAssertEqual(written.mateReach, MagnetSettings.minimumMateReach)
    }

    func testAnAbsurdReachIsClampedDown() throws {
        try #"{"mateReach": 9999}"#.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(MagnetSettingsStore(url: url).load().mateReach,
                       MagnetSettings.maximumMateReach,
                       "mating across the whole display is not a setting")
        var written = MagnetSettings()
        written.mateReach = 9999
        XCTAssertEqual(written.mateReach, MagnetSettings.maximumMateReach)
    }

    func testLegacySettingsDisableScalingWithoutLosingCustomReach() throws {
        try #"{"mateReach": 76}"#.data(using: .utf8)!.write(to: url)
        let store = MagnetSettingsStore(url: url)
        let settings = store.load()
        XCTAssertEqual(settings.mateReach, 76)
        try store.save(settings)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["scaleGroupsOnResize"] as? Bool, false)
    }

    func testExplicitScalingChoiceSurvivesReachEditsAndReload() throws {
        for enabled in [true, false] {
            try """
            {"mateReach": 48, "scaleGroupsOnResize": \(enabled)}
            """.data(using: .utf8)!.write(to: url)
            let store = MagnetSettingsStore(url: url)
            var settings = store.load()
            settings.mateReach = 64
            try store.save(settings)
            let reloaded = store.load()
            XCTAssertEqual(reloaded.mateReach, 64)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(reloaded)) as? [String: Any])
            XCTAssertEqual(saved["scaleGroupsOnResize"] as? Bool, enabled)
        }
    }

    func testAutomaticClusteringChoiceSurvivesUnrelatedEdits() throws {
        for enabled in [true, false] {
            try """
            {"mateReach": 48, "autoClusterSameApp": \(enabled)}
            """.data(using: .utf8)!.write(to: url)
            let store = MagnetSettingsStore(url: url)
            var settings = store.load()
            settings.mateReach = 64
            try store.save(settings)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(saved["autoClusterSameApp"] as? Bool, enabled)
            XCTAssertEqual(store.load().mateReach, 64)
        }
    }

    func testLegacySettingsDoNotEnableAutomaticWindowMovement() throws {
        try #"{"mateReach": 76, "scaleGroupsOnResize": true}"#
            .data(using: .utf8)!.write(to: url)
        let store = MagnetSettingsStore(url: url)
        try store.save(store.load())
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["autoClusterSameApp"] as? Bool, false)
        XCTAssertEqual(saved["mateReach"] as? Double, 76)
        XCTAssertEqual(saved["scaleGroupsOnResize"] as? Bool, true)
    }
}
