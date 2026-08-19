import XCTest
@testable import MacTLMCore

final class WindowTrackerTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!
    var driver: FakeDriver!
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
        driver = FakeDriver()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTracker(saveDelay: TimeInterval = 0.05) -> WindowTracker {
        WindowTracker(driver: driver, store: store,
                      configKey: { "test-config" },
                      visibleArea: { self.area },
                      excludeList: { .defaults },
                      saveDelay: saveDelay)
    }

    func testActivityCapturesWindowFrames() {
        driver.windowsByBundle["com.apple.TextEdit"] = [
            DriverWindow(id: 1, title: "Doc",
                         frame: CGRect(x: 400, y: 122.5, width: 400, height: 487.5)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "com.apple.TextEdit")
        let records = tracker.recordsFor(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].frame.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.y, 0.1, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.w, 0.25, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.h, 0.5, accuracy: 0.001)
    }

    func testExcludedAppIsIgnored() {
        driver.windowsByBundle["com.adobe.illustrator"] = [
            DriverWindow(id: 1, title: "Art", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "com.adobe.illustrator")
        XCTAssertTrue(tracker.recordsFor(bundleID: "com.adobe.illustrator").isEmpty)
    }

    func testEmptySnapshotKeepsLastKnownRecords() {
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")
        driver.windowsByBundle["app"] = [] // all windows closed pre-quit
        tracker.noteActivity(bundleID: "app")
        XCTAssertEqual(tracker.recordsFor(bundleID: "app").count, 1)
    }

    func testTerminationFlushesToDiskImmediately() {
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker(saveDelay: 60) // debounce far in the future
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app")
        let loaded = store.load(configKey: "test-config")
        XCTAssertEqual(loaded.apps["app"]?.count, 1)
    }

    func testCapturePreservesExistingPinPatterns() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Renamed", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, title: "Old",
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "test-config")
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }
}
