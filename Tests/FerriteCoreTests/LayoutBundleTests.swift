import XCTest
@testable import FerriteCore

final class LayoutBundleTests: XCTestCase {
    private func layout(_ name: String, display: String,
                        stage: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "Display \(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testBundlesGroupByNameSortedByName() {
        let library = LayoutLibrary(layouts: [
            layout("Zed", display: "A"),
            layout("Alpha", display: "A"),
            layout("Alpha", display: "B"),
        ])
        let bundles = library.bundles()
        XCTAssertEqual(bundles.map(\.name), ["Alpha", "Zed"])
        XCTAssertEqual(bundles[0].layouts.count, 2)
        XCTAssertEqual(bundles[1].layouts.count, 1)
    }

    func testBundleSpansMultipleDisplaysFlag() {
        let library = LayoutLibrary(layouts: [
            layout("Solo", display: "A"),
            layout("Dual", display: "A"),
            layout("Dual", display: "B"),
        ])
        let bundles = library.bundles()
        XCTAssertEqual(bundles.first { $0.name == "Dual" }?.spansMultipleDisplays, true)
        XCTAssertEqual(bundles.first { $0.name == "Solo" }?.spansMultipleDisplays, false)
    }

    func testBundleLayoutsAreOrderedByDisplayName() {
        let library = LayoutLibrary(layouts: [
            layout("Dual", display: "Z"),
            layout("Dual", display: "A"),
        ])
        let bundle = library.bundles()[0]
        XCTAssertEqual(bundle.layouts.map(\.displayID), ["A", "Z"])
    }

    func testEmptyLibraryHasNoBundles() {
        XCTAssertTrue(LayoutLibrary().bundles().isEmpty)
    }
}
