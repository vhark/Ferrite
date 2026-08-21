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
        // After Effects, not Illustrator: Illustrator left `ExcludeList.defaults`
        // on 2026-08-21 once `--probe-frame` showed it accepts AX frame changes.
        driver.windowsByBundle["com.adobe.AfterEffects"] = [
            DriverWindow(id: 1, title: "Comp", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "com.adobe.AfterEffects")
        XCTAssertTrue(tracker.recordsFor(bundleID: "com.adobe.AfterEffects").isEmpty)
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
            WindowRecord(slot: 0, titleHash: testHash("Old"),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "test-config")
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    /// The pin stays on its own record and that record follows the window whose
    /// title matches, whatever the z-order. Asserted through the frames, not
    /// array positions: capture merges, so a record's slot is its identity and
    /// no longer shuffles to match the enumeration order.
    func testPinFollowsWindowWhenZOrderChanges() {
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, titleHash: testHash("Work — Arc"),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 0)),
            WindowRecord(slot: 1, titleHash: testHash("Personal"),
                         frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "test-config")
        // "Work — Arc" is now behind "Personal".
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 10, title: "Personal", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
            DriverWindow(id: 11, title: "Work — Arc", frame: CGRect(x: 400, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        let records = tracker.recordsFor(bundleID: "arc")
        XCTAssertEqual(records.count, 2)
        let pinned = records.first { $0.pinPattern == "Work" }
        XCTAssertEqual(pinned?.slot, 0, "the pin never migrates to another slot")
        XCTAssertEqual(pinned?.frame.x ?? -1, 0.25, accuracy: 0.001,
                       "the pinned record captured the window titled 'Work — Arc'")
        let unpinned = records.first { $0.pinPattern == nil }
        XCTAssertEqual(unpinned?.frame.x ?? -1, 0.0, accuracy: 0.001,
                       "the frontmost window went to its own record, not the pinned one")
    }

    func testUnmatchedPinFallsBackToSlot() {
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, titleHash: testHash("Old"),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "test-config")
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 10, title: "Untitled", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    func testReloadFlushesOldNamespaceBeforeSwap() {
        var key = "cfg-A"
        let tracker = WindowTracker(driver: driver, store: store,
                                    configKey: { key },
                                    visibleArea: { self.area },
                                    excludeList: { .defaults },
                                    saveDelay: 60)
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        tracker.noteActivity(bundleID: "app")
        key = "cfg-B"
        tracker.reloadForCurrentConfiguration()
        XCTAssertEqual(store.load(configKey: "cfg-A").apps["app"]?.count, 1)
        XCTAssertTrue(tracker.recordsFor(bundleID: "app").isEmpty)
    }

    func testActivityDuringConfigDriftMigratesInsteadOfDropping() {
        var key = "cfg-A"
        let tracker = WindowTracker(driver: driver, store: store,
                                    configKey: { key },
                                    visibleArea: { self.area },
                                    excludeList: { .defaults },
                                    saveDelay: 60)
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        var drifts: [(String, String)] = []
        tracker.onConfigurationDrift = { drifts.append(($0, $1)) }
        key = "cfg-B" // display changed; reload hasn't run yet
        tracker.noteActivity(bundleID: "app")
        XCTAssertEqual(tracker.recordsFor(bundleID: "app").count, 1,
                       "a capture during config drift must migrate, not vanish")
        XCTAssertEqual(drifts.count, 1, "the repair is reported, never silent")
        XCTAssertEqual(drifts.first?.0, "cfg-A")
        XCTAssertEqual(drifts.first?.1, "cfg-B")
    }

    func testSetPinPatternPersistsImmediately() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(saveDelay: 60) // debounce far in the future
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Work", bundleID: "arc", slot: 0)
        // Immediate flush, not waiting on the debounce.
        XCTAssertEqual(store.load(configKey: "test-config")
            .apps["arc"]?[0].pinPattern, "Work")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    func testPinSurvivesTheNextCapture() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Work", bundleID: "arc", slot: 0)
        // A later capture must not wipe the pin the user just set.
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    func testForgetAppClearsMemoryAndDisk() {
        driver.windowsByBundle["junk"] = [
            DriverWindow(id: 1, title: "Open", frame: CGRect(x: 0, y: 25, width: 400, height: 300)),
        ]
        let tracker = makeTracker(saveDelay: 60)
        tracker.noteActivity(bundleID: "junk")
        tracker.forgetApp(bundleID: "junk")
        XCTAssertTrue(tracker.recordsFor(bundleID: "junk").isEmpty)
        XCTAssertNil(store.load(configKey: "test-config").apps["junk"])
    }

    func testRememberedBundleIDsReflectsForget() {
        driver.windowsByBundle["a"] = [
            DriverWindow(id: 1, title: "A", frame: CGRect(x: 0, y: 25, width: 400, height: 300)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "a")
        XCTAssertEqual(tracker.rememberedBundleIDs, ["a"])
        tracker.forgetApp(bundleID: "a")
        XCTAssertTrue(tracker.rememberedBundleIDs.isEmpty)
    }
}
