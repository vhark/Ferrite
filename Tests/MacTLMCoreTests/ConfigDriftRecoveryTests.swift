import XCTest
@testable import MacTLMCore

/// The M2a guard in `noteActivity` dropped every capture whose live config key
/// disagreed with the loaded one, on the assumption that
/// `didChangeScreenParameters` always arrives to reload the namespace. When
/// that notification is missed the tracker is stranded on a dead namespace and
/// capture stops permanently — observed live: four minutes of AX events, no
/// records, no error. These tests pin the self-healing behaviour.
final class ConfigDriftRecoveryTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!
    var driver: FakeDriver!
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975)

    /// The key the tracker's closure reports; flipping it without calling
    /// `reloadForCurrentConfiguration()` simulates the missed notification.
    var key = "cfg-A"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
        driver = FakeDriver()
        key = "cfg-A"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `saveDelay: 60` keeps the debounce out of the picture: every write these
    /// tests observe comes from an explicit flush (migration or termination).
    private func makeTracker() -> WindowTracker {
        WindowTracker(driver: driver, store: store,
                      configKey: { self.key },
                      visibleArea: { self.area },
                      excludeList: { .defaults },
                      saveDelay: 60)
    }

    private func window(_ frame: CGRect, title: String = "W") -> [DriverWindow] {
        [DriverWindow(id: 1, title: title, frame: frame)]
    }

    func testCaptureAfterUnnotifiedDriftLandsInTheNewNamespace() {
        driver.windowsByBundle["app"] = window(CGRect(x: 0, y: 25, width: 800, height: 600))
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")

        key = "cfg-B" // display configuration changed; the notification never came
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app") // flush what is in memory now

        XCTAssertFalse(tracker.recordsFor(bundleID: "app").isEmpty,
                       "the post-drift capture must not be dropped")
        XCTAssertEqual(store.load(configKey: "cfg-B").apps["app"]?.count, 1,
                       "the record must land in the live namespace")
    }

    func testDriftDoesNotPolluteTheOldNamespace() {
        driver.windowsByBundle["app"] = window(CGRect(x: 0, y: 25, width: 800, height: 975))
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")

        key = "cfg-B"
        // Post-drift geometry differs from everything cfg-A ever saw.
        driver.windowsByBundle["app"] = window(CGRect(x: 800, y: 25, width: 400, height: 487.5))
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app")

        let old = store.load(configKey: "cfg-A").apps["app"]
        XCTAssertEqual(old?.count, 1)
        XCTAssertEqual(old?[0].frame.x ?? -1, 0.0, accuracy: 0.001,
                       "cfg-A keeps its own geometry")
        XCTAssertEqual(old?[0].frame.w ?? -1, 0.5, accuracy: 0.001,
                       "post-drift geometry must not leak backwards into cfg-A")

        let new = store.load(configKey: "cfg-B").apps["app"]
        XCTAssertEqual(new?[0].frame.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(new?[0].frame.w ?? -1, 0.25, accuracy: 0.001)
    }

    func testDriftMigrationIsIdempotent() {
        driver.windowsByBundle["app"] = window(CGRect(x: 0, y: 25, width: 800, height: 600))
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")

        key = "cfg-B"
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app") // cfg-B's first write
        let keysAfterMigration = store.configKeys()

        // No further key change: these must be ordinary captures, not migrations.
        tracker.noteActivity(bundleID: "app")
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app")

        XCTAssertEqual(store.configKeys(), keysAfterMigration,
                       "a settled tracker must not spawn further namespaces")
        XCTAssertEqual(keysAfterMigration, ["cfg-A", "cfg-B"])
        XCTAssertEqual(store.load(configKey: "cfg-B").apps["app"]?.count, 1)
        XCTAssertEqual(tracker.recordsFor(bundleID: "app").count, 1)
    }

    func testExplicitReloadStillWorks() {
        driver.windowsByBundle["app"] = window(CGRect(x: 0, y: 25, width: 800, height: 600))
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")

        key = "cfg-B"
        tracker.reloadForCurrentConfiguration()

        XCTAssertEqual(store.load(configKey: "cfg-A").apps["app"]?.count, 1,
                       "the old namespace is flushed before the swap")
        XCTAssertTrue(tracker.recordsFor(bundleID: "app").isEmpty,
                      "the new namespace starts empty")
    }
}
