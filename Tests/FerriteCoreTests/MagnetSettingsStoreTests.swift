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
}
