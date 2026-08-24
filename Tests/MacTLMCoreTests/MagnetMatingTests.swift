import XCTest
@testable import MacTLMCore

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
}
