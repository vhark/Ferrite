import XCTest
@testable import FerriteCore

final class MagnetResizeTests: XCTestCase {
    // Two windows mated left|right with an 8pt gap.
    private let left = CGRect(x: 0, y: 0, width: 992, height: 1000)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
    private let floor = CGSize(width: 200, height: 200)

    func testShrinkMovesTheMatesFacingEdgeOnly() {
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000) // +200 right edge
        let result = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        let mate = result[2]
        XCTAssertNotNil(mate)
        XCTAssertEqual(mate!.minX, widened.maxX + 8, accuracy: 0.001, "shared edge stays shared")
        XCTAssertEqual(mate!.maxX, right.maxX, accuracy: 0.001, "far edge is anchored")
        XCTAssertEqual(mate!.width, right.width - 200, accuracy: 0.001)
    }

    func testNudgeTranslatesTheMateKeepingItsSize() {
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        let mate = result[2]!
        XCTAssertEqual(mate.width, right.width, accuracy: 0.001)
        XCTAssertEqual(mate.minX, right.minX + 200, accuracy: 0.001)
    }

    func testShrinkStopsAtTheMinimumSize() {
        let hugely = CGRect(x: 0, y: 0, width: 1900, height: 1000)
        let result = MagnetResize.propagate(frames: [1: hugely, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertGreaterThanOrEqual(result[2]!.width, floor.width - 0.001,
                                    "a mate must never be crushed below usability")
    }

    func testWindowsThatShareNoEdgeAreUntouched() {
        let stranger = CGRect(x: 3000, y: 0, width: 500, height: 500)
        let widened = CGRect(x: 0, y: 0, width: 1192, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: stranger],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertNil(result[2])
    }

    func testNudgeCascadesThroughAChainOfMates() {
        let middle = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let far = CGRect(x: 1508, y: 0, width: 500, height: 1000)
        let widened = CGRect(x: 0, y: 0, width: 1092, height: 1000) // +100
        let result = MagnetResize.propagate(frames: [1: widened, 2: middle, 3: far],
                                           changed: 1, previous: left,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        XCTAssertEqual(result[2]!.minX, middle.minX + 100, accuracy: 0.001)
        XCTAssertEqual(result[3]!.minX, far.minX + 100, accuracy: 0.001,
                       "a nudge travels down the chain")
    }

    func testShrinkDoesNotCascade() {
        let middle = CGRect(x: 1000, y: 0, width: 500, height: 1000)
        let far = CGRect(x: 1508, y: 0, width: 500, height: 1000)
        let widened = CGRect(x: 0, y: 0, width: 1092, height: 1000)
        let result = MagnetResize.propagate(frames: [1: widened, 2: middle, 3: far],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertNil(result[3], "shrink absorbs the delta in the immediate mate")
    }

    func testMovingAWindowWithoutResizingItPropagatesNothing() {
        let slid = left.offsetBy(dx: 5, dy: 0) // same size, both edges moved equally
        let result = MagnetResize.propagate(frames: [1: slid, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink, gap: 8, minimumSize: floor)
        XCTAssertTrue(result.isEmpty,
                      "a plain move is a mating gesture, not a resize gesture")
    }

    func testPropagationTerminatesOnACycle() {
        // Three windows each adjacent to the next, last adjacent back to the first.
        let a = CGRect(x: 0, y: 0, width: 492, height: 500)
        let b = CGRect(x: 500, y: 0, width: 492, height: 500)
        let c = CGRect(x: 0, y: 508, width: 492, height: 492)
        let grown = CGRect(x: 0, y: 0, width: 592, height: 500)
        let result = MagnetResize.propagate(frames: [1: grown, 2: b, 3: c],
                                           changed: 1, previous: a,
                                           mode: .nudge, gap: 8, minimumSize: floor)
        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThanOrEqual(result.count, 2)
    }
}
