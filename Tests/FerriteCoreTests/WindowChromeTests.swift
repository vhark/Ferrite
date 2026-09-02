import XCTest
@testable import FerriteCore

final class WindowChromeTests: XCTestCase {
    // CG space: this window's top edge is y = 50.
    private let frame = CGRect(x: 100, y: 50, width: 800, height: 600)

    func testTitleBarIsTheTopBand() {
        let bar = WindowChrome.titleBar(of: frame)
        XCTAssertEqual(bar.minY, 50, accuracy: 0.01)
        XCTAssertEqual(bar.height, WindowChrome.titleBarHeight, accuracy: 0.01)
        XCTAssertEqual(bar.minX, 100, accuracy: 0.01)
        XCTAssertEqual(bar.width, 800, accuracy: 0.01)
    }

    func testPointJustInsideTheTopBandHits() {
        XCTAssertTrue(WindowChrome.isInTitleBar(CGPoint(x: 500, y: 60), of: frame))
    }

    func testPointBelowTheBandMisses() {
        // 20pt below the band: the window's content, not its chrome.
        XCTAssertFalse(WindowChrome.isInTitleBar(CGPoint(x: 500, y: 98), of: frame))
    }

    func testPointAboveTheWindowMisses() {
        XCTAssertFalse(WindowChrome.isInTitleBar(CGPoint(x: 500, y: 40), of: frame))
    }

    func testPointOutsideHorizontallyMisses() {
        XCTAssertFalse(WindowChrome.isInTitleBar(CGPoint(x: 950, y: 60), of: frame))
    }

    func testBandNeverExceedsAShortWindow() {
        let squat = CGRect(x: 0, y: 0, width: 400, height: 12)
        XCTAssertEqual(WindowChrome.titleBar(of: squat).height, 12, accuracy: 0.01)
    }
}
