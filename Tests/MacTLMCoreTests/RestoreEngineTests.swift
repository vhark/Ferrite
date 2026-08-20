import XCTest
@testable import MacTLMCore

final class FakeDriver: WindowDriving {
    var windowsByBundle: [String: [DriverWindow]] = [:]
    var setFrameCalls: [(id: Int, frame: CGRect)] = []
    /// When set, every setFrame result is clamped to this height (app minimum).
    var clampHeightTo: CGFloat?

    func windows(ofBundleID bundleID: String) -> [DriverWindow] {
        windowsByBundle[bundleID] ?? []
    }

    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect {
        setFrameCalls.append((window.id, frame))
        var achieved = frame
        if let clamp = clampHeightTo { achieved.size.height = min(achieved.height, clamp) }
        return achieved
    }
}

final class RestoreEngineTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975)

    private func record(slot: Int, title: String, frame: NormalizedFrame) -> WindowRecord {
        WindowRecord(slot: slot, title: title, frame: frame,
                     pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testRestoresTwoWindowsToTheirFrames() {
        let driver = FakeDriver()
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
            DriverWindow(id: 2, title: "Personal", frame: CGRect(x: 400, y: 25, width: 300, height: 300)),
        ]
        let records = [
            record(slot: 0, title: "Work", frame: NormalizedFrame(x: 0.0, y: 0.0, w: 0.25, h: 0.9)),
            record(slot: 1, title: "Personal", frame: NormalizedFrame(x: 0.5, y: 0.0, w: 0.25, h: 0.9)),
        ]
        let placed = RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "arc", visibleArea: area)
        XCTAssertEqual(placed, 2)
        XCTAssertEqual(driver.setFrameCalls.count, 2)
        let workCall = driver.setFrameCalls.first { $0.id == 1 }!
        XCTAssertEqual(workCall.frame.width, 400, accuracy: 0.001)   // 0.25 * 1600
        XCTAssertEqual(workCall.frame.height, 877.5, accuracy: 0.001) // 0.9 * 975
    }

    func testClampedFrameGetsExactlyOneRetryThenAcceptance() {
        let driver = FakeDriver()
        driver.clampHeightTo = 500
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "W",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9))]
        RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(driver.setFrameCalls.count, 2, "one attempt + one retry, never a loop")
    }

    func testWithinToleranceDoesNotRetry() {
        let driver = FakeDriver()
        driver.clampHeightTo = 876.5 // target height 877.5, within 2.0 tolerance
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "W",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9))]
        RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(driver.setFrameCalls.count, 1, "clamp within tolerance is accepted without retry")
    }

    func testRetryResendsOriginalTarget() {
        let driver = FakeDriver()
        driver.clampHeightTo = 500
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "W",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9))]
        RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(driver.setFrameCalls.count, 2)
        XCTAssertEqual(driver.setFrameCalls[1].frame, driver.setFrameCalls[0].frame,
                       "retry resends the original target, not the clamped result")
    }

    func testNoRecordsMeansNoDriverCalls() {
        let driver = FakeDriver()
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: .zero),
        ]
        let placed = RestoreEngine(driver: driver)
            .restore(records: [], bundleID: "app", visibleArea: area)
        XCTAssertEqual(placed, 0)
        XCTAssertTrue(driver.setFrameCalls.isEmpty)
    }

    func testFewerWindowsThanRecordsSkipsUnmatchedTransientWindow() {
        let driver = FakeDriver()
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "Open", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "alpha.txt",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9)),
                       record(slot: 1, title: "beta.txt",
                              frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9))]
        let placed = RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(placed, 0)
        XCTAssertTrue(driver.setFrameCalls.isEmpty, "transient window must not be placed")
    }

    func testFewerWindowsButTitleMatchStillPlaces() {
        let driver = FakeDriver()
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "beta.txt", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "alpha.txt",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9)),
                       record(slot: 1, title: "beta.txt",
                              frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9))]
        let placed = RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(placed, 1)
        XCTAssertEqual(driver.setFrameCalls.count, 1)
    }
}
