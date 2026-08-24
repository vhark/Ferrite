import XCTest
@testable import FerriteCore

final class LayoutArchiveTests: XCTestCase {
    private func layout(_ name: String, display: String = "A") -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: .leaveOthers, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testLegacyJSONWithoutArchiveKeyStillDecodes() throws {
        // Exactly the shape written before this task existed.
        let json = """
        {"layouts":[{"createdAt":"2026-08-19T00:00:00Z","displayID":"A",
        "displayMetrics":{"height":1000,"id":"A","scale":2,"width":1600},
        "displayName":"DA","entries":[],"id":"AAAAAAAA-0000-0000-0000-000000000001",
        "name":"Design&Comms","stageMode":"leaveOthers"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(LayoutLibrary.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(library.layouts.count, 1, "legacy file must not decode as empty")
        XCTAssertTrue(library.archivedBundleNames.isEmpty)
    }

    func testArchiveHidesFromActiveButKeepsLayout() {
        var library = LayoutLibrary(layouts: [layout("Work"), layout("Play")])
        library.archiveBundle(named: "Play")
        XCTAssertEqual(library.activeBundles().map(\.name), ["Work"])
        XCTAssertEqual(library.archivedBundles().map(\.name), ["Play"])
        XCTAssertEqual(library.layouts.count, 2, "archiving must not drop layouts")
    }

    func testRestoreBringsItBack() {
        var library = LayoutLibrary(layouts: [layout("Play")])
        library.archiveBundle(named: "Play")
        library.restoreBundle(named: "Play")
        XCTAssertEqual(library.activeBundles().map(\.name), ["Play"])
        XCTAssertTrue(library.archivedBundleNames.isEmpty)
    }

    func testDeleteBundleRemovesLayoutsAndArchiveEntry() {
        var library = LayoutLibrary(layouts: [layout("Play", display: "A"),
                                              layout("Play", display: "B")])
        library.archiveBundle(named: "Play")
        library.deleteBundle(named: "Play")
        XCTAssertTrue(library.layouts.isEmpty)
        XCTAssertTrue(library.archivedBundleNames.isEmpty,
                      "no orphan archive entry left behind")
    }

    func testSavingOverAnArchivedNameReactivatesIt() {
        var library = LayoutLibrary(layouts: [layout("Work")])
        library.archiveBundle(named: "Work")
        library.upsert([layout("Work")])
        XCTAssertEqual(library.activeBundles().map(\.name), ["Work"],
                       "re-saving an archived name brings it back")
    }

    func testArchiveRoundTripsThroughJSON() throws {
        var library = LayoutLibrary(layouts: [layout("Work")])
        library.archiveBundle(named: "Work")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LayoutLibrary.self,
                                         from: try encoder.encode(library))
        XCTAssertEqual(decoded.archivedBundleNames, ["Work"])
    }
}
