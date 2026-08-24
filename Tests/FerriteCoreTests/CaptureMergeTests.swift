import XCTest
@testable import FerriteCore

/// Capture merges into what is already remembered; it never replaces it.
///
/// The live failure this pins: two TextEdit documents were captured at distinct
/// positions, TextEdit was quit, then *beta alone* was reopened. The settle
/// restored beta, that placement triggered activity, and capture rebuilt the
/// app's records from the one window that happened to be open — destroying
/// alpha's remembered frame. When alpha opened moments later there were two
/// windows against two records again, so the order fallback was allowed and
/// alpha was dragged onto beta's frame.
///
/// Any app whose windows appear more than a settle apart hits this, as does any
/// user reopening documents one at a time.
final class CaptureMergeTests: XCTestCase {
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

    private func makeTracker(saveDelay: TimeInterval = 60) -> WindowTracker {
        WindowTracker(driver: driver, store: store,
                      configKey: { "test-config" },
                      visibleArea: { self.area },
                      excludeList: { .defaults },
                      saveDelay: saveDelay)
    }

    private func alpha(x: CGFloat = 100) -> DriverWindow {
        DriverWindow(id: 1, title: "alpha.txt",
                     frame: CGRect(x: x, y: 25, width: 400, height: 300))
    }

    private func beta(x: CGFloat = 800) -> DriverWindow {
        DriverWindow(id: 2, title: "beta.txt",
                     frame: CGRect(x: x, y: 25, width: 400, height: 300))
    }

    private func record(_ records: [WindowRecord], slot: Int) -> WindowRecord? {
        records.first { $0.slot == slot }
    }

    // MARK: - The live failure

    func testCaptureKeepsRecordsForWindowsThatAreNotOpen() {
        driver.windowsByBundle["editor"] = [alpha(), beta()]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")
        let before = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(before.count, 2)
        let betaSlot = before.first { $0.titleHash == testHash("beta.txt") }?.slot
        let betaFrame = before.first { $0.titleHash == testHash("beta.txt") }?.frame

        // beta is closed; only alpha is open when the next activity arrives.
        driver.windowsByBundle["editor"] = [alpha()]
        tracker.noteActivity(bundleID: "editor")

        let after = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(after.count, 2,
                       "a window that is merely not open must keep its record")
        XCTAssertEqual(betaSlot.flatMap { record(after, slot: $0) }?.frame, betaFrame,
                       "beta's remembered frame must be untouched by a capture it missed")
    }

    // MARK: - Matched records

    func testCaptureUpdatesTheMatchedRecordInPlace() {
        driver.windowsByBundle["editor"] = [alpha(x: 100)]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")
        XCTAssertEqual(tracker.recordsFor(bundleID: "editor").first?.slot, 0)

        // Same window (same identity hash), dragged elsewhere.
        driver.windowsByBundle["editor"] = [alpha(x: 1200)]
        tracker.noteActivity(bundleID: "editor")

        let records = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(records.count, 1, "the same window must not spawn a second record")
        XCTAssertEqual(records[0].slot, 0, "the slot is stable across captures")
        XCTAssertEqual(records[0].frame.x, 0.75, accuracy: 0.001, "the frame is updated")
    }

    func testCaptureAppendsNewWindowsWithFreshSlots() {
        driver.windowsByBundle["editor"] = [alpha()]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")

        driver.windowsByBundle["editor"] = [alpha(), beta()]
        tracker.noteActivity(bundleID: "editor")

        let records = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.slot)).count, 2, "slots are distinct")
        XCTAssertEqual(records.first { $0.titleHash == testHash("alpha.txt") }?.slot, 0,
                       "the already-known window keeps its slot")
        XCTAssertEqual(records.first { $0.titleHash == testHash("beta.txt") }?.slot, 1,
                       "the newcomer takes the next free slot")
    }

    func testCapturePreservesPinsAcrossMerge() {
        driver.windowsByBundle["editor"] = [alpha()]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")
        tracker.setPinPattern("alpha", bundleID: "editor", slot: 0)

        driver.windowsByBundle["editor"] = [alpha(), beta()]
        tracker.noteActivity(bundleID: "editor")

        let records = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(record(records, slot: 0)?.pinPattern, "alpha",
                       "the merge must carry the pin the user set")
        XCTAssertNil(record(records, slot: 1)?.pinPattern)
    }

    // MARK: - Bounded growth

    /// Sixteen records, `lastSeen` staggered so slot 0 is the oldest, none of
    /// them matching the window the driver will report.
    private func seedSixteen(pinningOldest: Bool) {
        var seeded = ConfigurationRecords()
        seeded.apps["editor"] = (0..<16).map { index in
            WindowRecord(slot: index,
                         titleHash: testHash("doc-\(index)"),
                         frame: NormalizedFrame(x: 0.1, y: 0, w: 0.25, h: 0.5),
                         // A pattern no live title matches: the pinned record
                         // must survive on the pin alone, not by being matched.
                         pinPattern: (pinningOldest && index == 0) ? "no-such-window" : nil,
                         lastSeen: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        try? store.save(seeded, configKey: "test-config")
        driver.windowsByBundle["editor"] = [
            DriverWindow(id: 99, title: "seventeenth",
                         frame: CGRect(x: 800, y: 25, width: 400, height: 300)),
        ]
    }

    func testCaptureCapsRecordsAtSixteenEvictingOldest() {
        seedSixteen(pinningOldest: false)
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")

        let records = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(records.count, 16, "records per app are capped")
        XCTAssertNil(records.first { $0.titleHash == testHash("doc-0") },
                     "the oldest unmatched, unpinned record is evicted")
        XCTAssertNotNil(records.first { $0.titleHash == testHash("doc-1") },
                        "only the overflow is evicted")
        XCTAssertNotNil(records.first { $0.titleHash == testHash("seventeenth") },
                        "the window that is open right now is never the one dropped")
    }

    func testCaptureNeverEvictsAPinnedRecord() {
        seedSixteen(pinningOldest: true)
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")

        let records = tracker.recordsFor(bundleID: "editor")
        XCTAssertEqual(records.count, 16)
        XCTAssertNotNil(records.first { $0.titleHash == testHash("doc-0") },
                        "a pinned record is never evicted, however stale")
        XCTAssertNil(records.first { $0.titleHash == testHash("doc-1") },
                     "the next-oldest unpinned record goes instead")
        XCTAssertNotNil(records.first { $0.titleHash == testHash("seventeenth") })
    }

    // MARK: - Close-all

    func testEmptySnapshotStillKeepsEverything() {
        driver.windowsByBundle["editor"] = [alpha(), beta()]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "editor")
        let before = tracker.recordsFor(bundleID: "editor").sorted { $0.slot < $1.slot }

        driver.windowsByBundle["editor"] = [] // every window closed, pre-quit
        tracker.noteActivity(bundleID: "editor")

        let after = tracker.recordsFor(bundleID: "editor").sorted { $0.slot < $1.slot }
        XCTAssertEqual(after, before, "an empty snapshot changes nothing at all")
    }
}
