import XCTest
@testable import FerriteCore

/// `.standard` mode: a resize moves nothing but the window being resized.
final class MagnetResizeStandardTests: XCTestCase {
    // Two windows sharing a vertical edge with the standard 8pt gap.
    private let left = CGRect(x: 0, y: 0, width: 500, height: 400)
    private let right = CGRect(x: 508, y: 0, width: 500, height: 400)
    /// Left window's right edge dragged 100pt further right.
    private let widened = CGRect(x: 0, y: 0, width: 600, height: 400)

    func testStandardModeMovesNoMates() {
        let moves = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .standard)
        XCTAssertTrue(moves.isEmpty)
    }

    /// Redundant by construction with the two-window case — the early guard
    /// returns before adjacency is ever swept — but kept: it pins the contract
    /// against the nudge chain it contrasts with, and would carry its own
    /// weight if `.standard` ever became a per-mate decision.
    func testStandardModeMovesNothingEvenInAChain() {
        // Three in a row: nudge would push both, standard pushes neither.
        let third = CGRect(x: 1016, y: 0, width: 500, height: 400)
        let moves = MagnetResize.propagate(frames: [1: widened, 2: right, 3: third],
                                           changed: 1, previous: left,
                                           mode: .standard)
        XCTAssertTrue(moves.isEmpty)
    }

    // Guards: the new switch arm must not change the siblings' behavior.
    func testShrinkStillResizesTheMate() throws {
        let moves = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .shrink)
        XCTAssertEqual(moves.count, 1)
        let mate = try XCTUnwrap(moves[2])
        XCTAssertLessThan(mate.width, right.width)   // resized, far edge anchored
        XCTAssertEqual(mate.maxX, right.maxX, accuracy: 0.01)
    }

    func testNudgeStillTranslatesTheMate() throws {
        let moves = MagnetResize.propagate(frames: [1: widened, 2: right],
                                           changed: 1, previous: left,
                                           mode: .nudge)
        let mate = try XCTUnwrap(moves[2])
        XCTAssertEqual(mate.width, right.width, accuracy: 0.01)  // size kept
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(mate.minX, right.minX + 100, accuracy: 0.01)
    }
}
