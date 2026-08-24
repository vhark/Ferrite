import XCTest
@testable import FerriteCore

final class LayoutBundleConnectionTests: XCTestCase {
    private func layout(_ display: String) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: "W", displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: .leaveOthers, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSplitsConnectedFromDisconnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A"), layout("B")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["A"])
        XCTAssertEqual(split.connected.map(\.displayID), ["A"])
        XCTAssertEqual(split.disconnected.map(\.displayID), ["B"])
    }

    func testAllConnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A"), layout("B")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["A", "B"])
        XCTAssertEqual(split.connected.count, 2)
        XCTAssertTrue(split.disconnected.isEmpty)
        XCTAssertTrue(bundle.isFullyConnected(connectedDisplayIDs: ["A", "B"]))
    }

    func testNoneConnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["Z"])
        XCTAssertTrue(split.connected.isEmpty)
        XCTAssertEqual(split.disconnected.count, 1)
        XCTAssertFalse(bundle.isFullyConnected(connectedDisplayIDs: ["Z"]))
    }

    func testPreservesLayoutOrderWithinEachGroup() {
        let bundle = LayoutBundle(name: "W",
                                  layouts: [layout("A"), layout("B"), layout("C")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["C", "A"])
        XCTAssertEqual(split.connected.map(\.displayID), ["A", "C"],
                       "bundle layout order is preserved, not reordered by the set")
    }
}
