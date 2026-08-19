import XCTest
@testable import MacTLMCore

final class LayoutLibraryStoreTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func sampleLayout() -> MonitorLayout {
        MonitorLayout(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            name: "Design + Comms",
            displayID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            displayName: "Built-in Retina Display",
            displayMetrics: DisplayInfo(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                                        width: 1600, height: 1000, scale: 2.0),
            stageMode: .leaveOthers,
            entries: [
                LayoutEntry(bundleID: "company.thebrowser.Browser", title: "Work",
                            frame: NormalizedFrame(x: 0.22, y: 0.05, w: 0.25, h: 0.90),
                            zIndex: 1, pinPattern: nil, optional: false),
                LayoutEntry(bundleID: "sh.paseo.desktop", title: "Paseo",
                            frame: NormalizedFrame(x: 0.48, y: 0.20, w: 0.25, h: 0.60),
                            zIndex: 0, pinPattern: nil, optional: true),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLoadMissingFileReturnsEmptyLibrary() {
        XCTAssertEqual(LayoutLibraryStore(url: url).load(), LayoutLibrary())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = LayoutLibraryStore(url: url)
        let library = LayoutLibrary(layouts: [sampleLayout()])
        try store.save(library)
        XCTAssertEqual(store.load(), library)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        try Data("nope{".utf8).write(to: url)
        XCTAssertEqual(LayoutLibraryStore(url: url).load(), LayoutLibrary())
    }
}
