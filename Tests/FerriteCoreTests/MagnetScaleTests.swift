import XCTest
@testable import FerriteCore

final class MagnetScaleTests: XCTestCase {
    // Two windows mated left|right with an 8pt gap; bbox (0,0,2000,1000).
    private let left = CGRect(x: 0, y: 0, width: 992, height: 1000)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
    private let floor = CGSize(width: 200, height: 200)

    // MARK: - Classification

    func testSharedEdgeIsNotOuter() {
        let outer = MagnetScale.outerEdges(of: left, among: [right])
        XCTAssertEqual(outer, [.left, .top, .bottom],
                       "the right edge has a flush mate and must not classify as outer")
    }

    func testCornerGrazeStaysOuter() {
        // Mate only 20pt of vertical overlap left... none: fully below.
        let below = CGRect(x: 1000, y: 1008, width: 1000, height: 500)
        let outer = MagnetScale.outerEdges(of: left, among: [below])
        XCTAssertTrue(outer.contains(.right),
                      "no perpendicular overlap means no shared edge")
    }

    func testFlushDetectionTolerates12pt() {
        let slightlyOff = CGRect(x: 1010, y: 0, width: 990, height: 1000) // 18pt gap ≈ 8+10
        let outer = MagnetScale.outerEdges(of: left, among: [slightlyOff])
        XCTAssertFalse(outer.contains(.right),
                       "within gap+tolerance is still flush")
    }

    // MARK: - Adjacency (membership decisions ride the same geometry)

    func testFlushNeighboursAreAdjacent() {
        XCTAssertTrue(MagnetScale.isAdjacent(left, to: right),
                      "an 8pt-gap mate is adjacent on any edge")
    }

    func testDistantWindowsAreNotAdjacent() {
        let far = CGRect(x: 3000, y: 0, width: 500, height: 500)
        XCTAssertFalse(MagnetScale.isAdjacent(left, to: far))
    }

    func testCornerGrazeIsNotAdjacent() {
        // Diagonal neighbour: near in both axes but zero perpendicular overlap.
        let diagonal = CGRect(x: 1000, y: 1008, width: 500, height: 500)
        XCTAssertFalse(MagnetScale.isAdjacent(left, to: diagonal),
                       "touching corners is not being mated")
    }

    // MARK: - Settle

    func testDraggedWindowKeepsOnlyItsProportionalShare() {
        // User drags the right window's right edge +500 → macOS gave it all 500.
        let release = CGRect(x: 1000, y: 0, width: 1500, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        // bbox 2000 → 2500, fx = 1.25
        XCTAssertEqual(result[2]!.width, 1250, accuracy: 0.5,
                       "the dragged window's share is proportional, not the full delta")
        XCTAssertEqual(result[1]!.width, 1240, accuracy: 0.5)
        XCTAssertEqual(result[1]!.minX, 0, accuracy: 0.5, "far side of the group is anchored")
        XCTAssertEqual(result[2]!.maxX, 2500, accuracy: 0.5, "dragged edge lands where the user put it")
    }

    func testGapScalesProportionally() {
        let release = CGRect(x: 1000, y: 0, width: 3000, height: 1000) // bbox ×2
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        let gap = result[2]!.minX - result[1]!.maxX
        XCTAssertEqual(gap, 16, accuracy: 0.5, "the 8pt gap doubles at ×2 — the one-window metaphor")
    }

    func testCornerScalesBothAxes() {
        let release = CGRect(x: 1000, y: 0, width: 1500, height: 1500)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.height, 1500, accuracy: 0.5)
        XCTAssertEqual(result[1]!.width, 1240, accuracy: 0.5)
    }

    func testUnscaledAxisKeepsReleaseValues() {
        // During the drag, live shared-edge propagation already shrank window 1
        // horizontally. The settle scales only the vertical axis and must NOT
        // undo that horizontal adjustment by remapping it from session start.
        let liveShrunk = CGRect(x: 0, y: 0, width: 900, height: 1000)
        let release = CGRect(x: 1000, y: 0, width: 1000, height: 1300) // bottom edge +300
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: liveShrunk, 2: release],
                                        changed: 2, outerEdges: [.top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.width, 900, accuracy: 0.5,
                       "the live-propagated horizontal result survives the settle")
        XCTAssertEqual(result[1]!.height, 1300, accuracy: 0.5)
    }

    func testLeftEdgeDeltaMovesOriginAndScales() {
        // Dragging the LEFT window's left edge -400 (outward): origin moves.
        let release = CGRect(x: -400, y: 0, width: 1392, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: release, 2: right],
                                        changed: 1, outerEdges: [.left, .top, .bottom],
                                        minimumSize: floor)
        // bbox 2000 → 2400, fx = 1.2
        XCTAssertEqual(result[1]!.minX, -400, accuracy: 0.5)
        XCTAssertEqual(result[2]!.maxX, 2000, accuracy: 0.5, "the far right edge is anchored")
        XCTAssertEqual(result[2]!.width, 1200, accuracy: 0.5)
    }

    func testShrinkClampsAtFloor() {
        // Two-window fixtures cannot reach the floor: the dragged window's own
        // shared edge bounds the shrink. Three in a row, with narrow leftmost
        // members, can — dragging the wide rightmost window's right edge from
        // 2000 down to 500 gives fx = 0.25, which would leave the 192pt
        // members at 48pt without the clamp.
        let a = CGRect(x: 0, y: 0, width: 192, height: 1000)
        let b = CGRect(x: 200, y: 0, width: 192, height: 1000)
        let c = CGRect(x: 400, y: 0, width: 1600, height: 1000)
        let release = CGRect(x: 400, y: 0, width: 100, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: a, 2: b, 3: c],
                                        releaseFrames: [1: a, 2: b, 3: release],
                                        changed: 3, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.width, floor.width, accuracy: 0.5,
                       "48pt of proportional share is clamped up to the floor")
        for frame in result.values {
            XCTAssertGreaterThanOrEqual(frame.width, floor.width - 0.5,
                                        "no member is crushed below usability")
        }
        // Overlap at extremes is accepted, same stance as GroupLayoutSolver.clamp.
    }

    func testNoOuterDeltaProducesNothing() {
        // Only the shared edge moved — that is live propagation's job.
        let release = CGRect(x: 900, y: 0, width: 1100, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertTrue(result.isEmpty,
                      "left-edge movement is not in outerEdges for window 2, and no outer edge moved")
    }

    func testDegenerateShrinkIsRefused() {
        // Dragged so far the extent would invert.
        let release = CGRect(x: 1000, y: 0, width: 10, height: 1000)
        let start = [1: CGRect(x: 990, y: 0, width: 10, height: 1000), 2: right]
        let result = MagnetScale.settle(startFrames: start,
                                        releaseFrames: [1: start[1]!, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        // Either clamped sane frames or an empty refusal — never inverted rects.
        for frame in result.values {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    func testSingleMemberSettlesNothing() {
        let result = MagnetScale.settle(startFrames: [2: right],
                                        releaseFrames: [2: right.insetBy(dx: -100, dy: 0)],
                                        changed: 2, outerEdges: [.left, .right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertTrue(result.isEmpty, "a group of one has nothing to scale")
    }
}
