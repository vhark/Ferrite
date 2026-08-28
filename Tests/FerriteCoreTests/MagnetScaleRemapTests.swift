import XCTest
@testable import FerriteCore

final class MagnetScaleRemapTests: XCTestCase {
    func testRemapPreservesProportions() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let target = CGRect(x: 2000, y: 100, width: 500, height: 1000)
        let frames = [
            1: CGRect(x: 0, y: 0, width: 500, height: 500),
            2: CGRect(x: 500, y: 0, width: 500, height: 250),
        ]
        let result = MagnetScale.remap(frames: frames, from: source, to: target)
        XCTAssertEqual(result[1]!, CGRect(x: 2000, y: 100, width: 250, height: 1000))
        XCTAssertEqual(result[2]!, CGRect(x: 2250, y: 100, width: 250, height: 500))
    }

    func testRemapDegenerateSourceReturnsFramesUnchanged() {
        let frames = [1: CGRect(x: 5, y: 5, width: 10, height: 10)]
        let result = MagnetScale.remap(frames: frames,
                                       from: CGRect(x: 0, y: 0, width: 0, height: 10),
                                       to: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, frames)
    }
}
