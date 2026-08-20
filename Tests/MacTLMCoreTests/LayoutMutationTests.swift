import XCTest
@testable import MacTLMCore

final class LayoutMutationTests: XCTestCase {
    private func layout(_ name: String, display: String,
                        stage: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testRenameBundleRenamesEveryDisplaysLayout() {
        var library = LayoutLibrary(layouts: [
            layout("Old", display: "A"), layout("Old", display: "B"),
            layout("Other", display: "A"),
        ])
        library.renameBundle(from: "Old", to: "New")
        XCTAssertEqual(Set(library.layouts.map(\.name)), ["New", "Other"])
        XCTAssertEqual(library.layouts.filter { $0.name == "New" }.count, 2)
    }

    func testRenameToExistingNameMergesByReplacingCollisions() {
        var library = LayoutLibrary(layouts: [
            layout("Keep", display: "A"), layout("Rename", display: "A"),
        ])
        library.renameBundle(from: "Rename", to: "Keep")
        XCTAssertEqual(library.layouts.count, 1,
                       "same (name, displayID) collapses, newest wins")
        XCTAssertEqual(library.layouts[0].name, "Keep")
    }

    func testDeleteBundleRemovesEveryDisplaysLayout() {
        var library = LayoutLibrary(layouts: [
            layout("Gone", display: "A"), layout("Gone", display: "B"),
            layout("Stay", display: "A"),
        ])
        library.deleteBundle(named: "Gone")
        XCTAssertEqual(library.layouts.map(\.name), ["Stay"])
    }

    func testSetStageModeAppliesToWholeBundle() {
        var library = LayoutLibrary(layouts: [
            layout("W", display: "A"), layout("W", display: "B"),
        ])
        library.setStageMode(.clearStage, forBundleNamed: "W")
        XCTAssertTrue(library.layouts.allSatisfy { $0.stageMode == .clearStage })
    }
}
