import XCTest
@testable import FerriteCore

/// End-to-end pin persistence: a real `LayoutStore` on disk and real
/// `WindowTracker` instances, with the driver faked only for window
/// enumeration. These cover the seams the unit tests skip — a *fresh* tracker
/// re-reading the file, and pin edits that land while the display
/// configuration has moved on.
final class PinPersistenceIntegrationTests: XCTestCase {
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

    private func makeTracker(configKey: @escaping () -> String,
                             saveDelay: TimeInterval = 60) -> WindowTracker {
        WindowTracker(driver: driver, store: store,
                      configKey: configKey,
                      visibleArea: { self.area },
                      excludeList: { .defaults },
                      saveDelay: saveDelay)
    }

    // MARK: - Step 1: does a pin survive to the next launch?

    func testPinSetThroughATrackerIsVisibleToTheNextLaunch() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Titan Notes",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let first = makeTracker(configKey: { "cfg-A" })
        first.noteActivity(bundleID: "arc")
        first.setPinPattern("Titan", bundleID: "arc", slot: 0)

        // Next launch: a brand-new tracker over the same directory and key.
        let second = makeTracker(configKey: { "cfg-A" })
        XCTAssertEqual(second.recordsFor(bundleID: "arc").first?.pinPattern, "Titan",
                       "a pin set in one launch must be there in the next")
    }

    /// The purge-on-load rewrite runs before the fresh tracker hands records
    /// back; it must not drop the pin along with the legacy title key.
    func testPinSurvivesTheLegacyTitlePurgeOnTheNextLaunch() throws {
        let legacy = """
        {"apps":{"arc":[{"frame":{"h":0.9,"w":0.25,"x":0,"y":0},
        "lastSeen":"2026-08-19T00:00:00Z","pinPattern":"Titan",
        "slot":0,"title":"Titan Notes"}]}}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("cfg-A.json"))
        let tracker = makeTracker(configKey: { "cfg-A" })
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc").first?.pinPattern, "Titan")
        let onDisk = try String(contentsOf: directory.appendingPathComponent("cfg-A.json"),
                                encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Titan Notes"), "the plaintext title is scrubbed")
        XCTAssertTrue(onDisk.contains("\"pinPattern\" : \"Titan\""), "the pin is not")
    }

    // MARK: - Suspect (a): array index passed where a slot is expected

    /// Slots are only contiguous by accident. With records at slots 0 and 2, an
    /// edit addressed by array index (1) would hit the wrong record or nothing
    /// at all; addressed by slot (2) it hits the right one.
    func testPinAddressesSlotNumbersNotArrayIndices() {
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, titleHash: testHash("First"),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0)),
            WindowRecord(slot: 2, titleHash: testHash("Third"),
                         frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "cfg-A")
        let tracker = makeTracker(configKey: { "cfg-A" })

        tracker.setPinPattern("Titan", bundleID: "arc", slot: 2)
        let records = tracker.recordsFor(bundleID: "arc")
        XCTAssertNil(records[0].pinPattern, "slot 0 is untouched")
        XCTAssertEqual(records[1].pinPattern, "Titan", "the record with slot == 2 is pinned")

        // The index-vs-slot mistake is observable: slot 1 does not exist.
        tracker.setPinPattern("Wrong", bundleID: "arc", slot: 1)
        XCTAssertFalse(tracker.recordsFor(bundleID: "arc").contains {
            $0.pinPattern == "Wrong"
        }, "an edit for a slot that does not exist must not land on another slot")
    }

    // MARK: - Suspect (b): the display configuration moved under the edit

    /// The live failure: the Apps tab lists records from the namespace that was
    /// loaded when it opened, the display configuration changes, the tracker
    /// swaps to a namespace with no record for that slot, and the pin edit
    /// arrives afterwards. It must not evaporate.
    func testPinEditAfterADisplayChangeIsNotSilentlyDropped() {
        var key = "cfg-A"
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Titan Notes",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(configKey: { key })
        tracker.noteActivity(bundleID: "arc")
        tracker.noteTermination(bundleID: "arc") // flush the record into cfg-A

        key = "cfg-B" // second display arrives
        tracker.reloadForCurrentConfiguration()

        // The user submits the pin they typed against the cfg-A row.
        tracker.setPinPattern("Titan", bundleID: "arc", slot: 0)

        XCTAssertEqual(store.load(configKey: "cfg-A").apps["arc"]?.first?.pinPattern,
                       "Titan", "the pin must reach the namespace that holds the record")
    }

    /// The same edit, from the other direction: the tracker still holds the old
    /// namespace while the display has already changed. The pin belongs to the
    /// records the user was looking at, and must survive the swap that follows.
    func testPinEditDuringConfigDriftSurvivesTheFollowingReload() {
        var key = "cfg-A"
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Titan Notes",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(configKey: { key })
        tracker.noteActivity(bundleID: "arc")

        key = "cfg-B" // display changed; the reload notification has not run yet
        tracker.setPinPattern("Titan", bundleID: "arc", slot: 0)
        tracker.reloadForCurrentConfiguration()

        XCTAssertEqual(store.load(configKey: "cfg-A").apps["arc"]?.first?.pinPattern,
                       "Titan", "the pin is not lost to the namespace swap")
    }

    /// A pin is a statement about an app's window, not about a monitor layout,
    /// so setting one must not depend on which display happens to be attached.
    func testPinAppliesToEveryNamespaceHoldingThatSlot() {
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, titleHash: testHash("Titan Notes"),
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "cfg-A")
        try? store.save(seeded, configKey: "cfg-B")
        let tracker = makeTracker(configKey: { "cfg-A" })

        tracker.setPinPattern("Titan", bundleID: "arc", slot: 0)

        XCTAssertEqual(store.load(configKey: "cfg-A").apps["arc"]?.first?.pinPattern, "Titan")
        XCTAssertEqual(store.load(configKey: "cfg-B").apps["arc"]?.first?.pinPattern, "Titan",
                       "the other display configuration gets the pin too")

        tracker.setPinPattern(nil, bundleID: "arc", slot: 0)
        XCTAssertNil(store.load(configKey: "cfg-B").apps["arc"]?.first?.pinPattern,
                     "clearing a pin clears it everywhere as well")
    }

    // MARK: - Suspect (c): capture over a renamed window after the hash rename

    /// Pin carry-over keys off the *live* title, which the driver still
    /// reports; hashed identities at rest must not have broken it.
    func testPinCarriesOverWhenTheWindowTitleChangesEntirely() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Titan Notes",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(configKey: { "cfg-A" }, saveDelay: 0.01)
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Titan", bundleID: "arc", slot: 0)

        // Same window, unrecognisable title: the slot fallback has to carry it.
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Untitled",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc").first?.pinPattern, "Titan")

        // And the identity hash on disk tracks the new title, never the text.
        tracker.noteTermination(bundleID: "arc")
        let saved = store.load(configKey: "cfg-A").apps["arc"]
        XCTAssertEqual(saved?.first?.titleHash, testHash("Untitled"))
        XCTAssertEqual(saved?.first?.pinPattern, "Titan")
    }

    /// A second window appearing must not shove the pin onto the newcomer just
    /// because the pinned window's title stopped matching.
    func testPinStaysOnItsSlotWhenAnotherWindowAppears() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Titan Notes",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(configKey: { "cfg-A" }, saveDelay: 0.01)
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Titan", bundleID: "arc", slot: 0)

        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Renamed",
                         frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
            DriverWindow(id: 2, title: "Second",
                         frame: CGRect(x: 400, y: 25, width: 400, height: 900)),
        ]
        tracker.noteActivity(bundleID: "arc")
        let records = tracker.recordsFor(bundleID: "arc")
        XCTAssertEqual(records[0].pinPattern, "Titan")
        XCTAssertNil(records[1].pinPattern)
    }
}
