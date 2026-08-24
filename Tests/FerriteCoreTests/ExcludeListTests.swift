import XCTest
@testable import FerriteCore

final class ExcludeListTests: XCTestCase {
    // Renamed from testDefaultsExcludeKnownHostileApps: the defaults no longer
    // encode Rectangle's inherited list. `--probe-frame com.adobe.illustrator`
    // (2026-08-21) requested (40, 50, 5841, 2130) and read back exactly that —
    // Illustrator ACCEPTS AX frame changes, so it is managed like any other app.
    // After Effects and MATLAB were not running to probe, so they stay excluded.
    func testDefaultsExcludeOnlyUnverifiedHostileApps() {
        XCTAssertTrue(ExcludeList.defaults.isExcluded("com.adobe.AfterEffects"))
        XCTAssertTrue(ExcludeList.defaults.isExcluded("com.mathworks.matlab"))
        XCTAssertFalse(ExcludeList.defaults.isExcluded("com.adobe.illustrator"))
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
