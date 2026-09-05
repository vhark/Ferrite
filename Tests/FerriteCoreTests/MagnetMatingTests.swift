import XCTest
@testable import FerriteCore

final class MagnetMatingTests: XCTestCase {
    private let mate = CGRect(x: 1000, y: 100, width: 600, height: 800)

    func testDroppingJustLeftOfAWindowMatesItsRightEdge() {
        // dragged.maxX = 990, mate.minX = 1000 → 10pt apart, inside threshold
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)], gap: 8)
        XCTAssertEqual(candidate?.mateID, 1)
        XCTAssertEqual(candidate?.edge, .right)
        XCTAssertEqual(candidate?.snapped.maxX ?? 0, mate.minX - 8, accuracy: 0.001,
                       "the dragged window must sit flush minus the gap")
        XCTAssertEqual(candidate?.snapped.width ?? 0, dragged.width, accuracy: 0.001,
                       "mating moves a window, it does not resize it")
    }

    func testDroppingFarAwayDoesNotMate() {
        let dragged = CGRect(x: 100, y: 100, width: 500, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]))
    }

    func testEdgesThatBarelyOverlapDoNotMate() {
        // Vertically adjacent by only 20pt of an 800pt-tall mate.
        let dragged = CGRect(x: 490, y: 880, width: 500, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]),
                     "a corner graze is not a mate")
    }

    func testMatingAlsoAlignsTheNearPerpendicularEdge() {
        // Tops 12pt out of true → snap them level.
        let dragged = CGRect(x: 490, y: 112, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)])
        XCTAssertEqual(candidate?.snapped.minY ?? -1, mate.minY, accuracy: 0.001)
    }

    func testMatingLeavesAFarPerpendicularEdgeAlone() {
        let dragged = CGRect(x: 490, y: 400, width: 500, height: 300)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)])
        XCTAssertEqual(candidate?.snapped.minY ?? -1, 400, accuracy: 0.001,
                       "deliberate offsets must survive; only near-misses get straightened")
    }

    func testVerticalMatingSnapsBelow() {
        let dragged = CGRect(x: 1000, y: 915, width: 600, height: 400)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)], gap: 8)
        XCTAssertEqual(candidate?.edge, .top, "the dragged window's TOP edge is what mates")
        XCTAssertEqual(candidate?.snapped.minY ?? 0, mate.maxY + 8, accuracy: 0.001)
    }

    func testNearestCandidateWins() {
        let near = CGRect(x: 1000, y: 100, width: 300, height: 800)
        let far = CGRect(x: 1018, y: 100, width: 300, height: 800)
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged,
                                              others: [(2, far), (1, near)])
        XCTAssertEqual(candidate?.mateID, 1)
    }

    func testSnappingIsIdempotent() {
        let dragged = CGRect(x: 490, y: 100, width: 500, height: 800)
        guard let first = MagnetMating.candidate(dragged: dragged, others: [(1, mate)]) else {
            return XCTFail("expected a mate")
        }
        let second = MagnetMating.candidate(dragged: first.snapped, others: [(1, mate)])
        XCTAssertEqual(second?.snapped ?? .zero, first.snapped,
                       "re-mating an already-mated window must not drift it")
    }

    // MARK: - Regressions from the 2026-08-24 live trace

    func testAWellAlignedPairMatesWithinTheReachAndNotBeyondIt() {
        // The whole history in one test: 24pt was tighter than a hand can aim
        // on a 7680px display, 64pt was the first measured fix, 32pt is the
        // current default — and the reach is now user-configurable, so what
        // this pins is the RELATIONSHIP between reach and mating, not a magic
        // number. Essentially perfect overlap either way; only distance moves.
        let within = CGRect(x: 470, y: 100, width: 510, height: 800)
        XCTAssertNotNil(MagnetMating.candidate(dragged: within, others: [(1, mate)]),
                        "20pt apart and level: unmistakably a mate")
        let beyond = CGRect(x: 450, y: 100, width: 510, height: 800)
        let reach = MagnetMating.evaluate(dragged: beyond, others: [(1, mate)])
            .first { $0.edge == .right }
        XCTAssertEqual(reach?.distance ?? -1, 40, accuracy: 0.001,
                       "fixture guard: this must stay a 40pt reach")
        XCTAssertNil(MagnetMating.candidate(dragged: beyond, others: [(1, mate)]),
                     "40pt is past the 32pt default, so it must not mate")
    }

    func testACustomReachMovesTheMatingBoundary() {
        // A pair 40pt apart with essentially perfect overlap: beyond the 32pt
        // default, within a 64pt reach. The knob, not the geometry, decides.
        let dragged = CGRect(x: 450, y: 100, width: 510, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]))
        XCTAssertNotNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)],
                                               threshold: 64))
    }

    func testACornerGrazeIsStillRejectedWithinTheReach() {
        // Distance alone must not authorise a mate: overlap is what stops
        // accidents, which is why the reach is safe to tune at all. 20pt
        // apart, so inside any plausible reach setting.
        let dragged = CGRect(x: 490, y: 880, width: 500, height: 800)
        XCTAssertNil(MagnetMating.candidate(dragged: dragged, others: [(1, mate)]))
    }

    func testAlignmentUsesItsOwnTighterThreshold() {
        // 40pt off level: near enough to mate, too far to restyle. Before these
        // were separate numbers, loosening the reach also silently straightened
        // offsets the user had chosen.
        let dragged = CGRect(x: 490, y: 140, width: 500, height: 800)
        let candidate = MagnetMating.candidate(dragged: dragged, others: [(1, mate)])
        XCTAssertEqual(candidate?.snapped.minY ?? -1, 140, accuracy: 0.001,
                       "a 40pt vertical offset must survive mating")
    }

    func testEvaluateNamesTheRequirementThatFailed() {
        let graze = CGRect(x: 490, y: 880, width: 500, height: 800)
        let nearest = MagnetMating.evaluate(dragged: graze, others: [(1, mate)])
        let top = nearest.first { $0.edge == .top }
        XCTAssertNotNil(top)
        XCTAssertTrue(top!.passesDistance, "20pt apart is within reach")
        XCTAssertFalse(top!.passesOverlap, "and overlap is what rejects it")
    }
}
