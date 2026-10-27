import XCTest
@testable import FerriteCore

final class AutomaticClusterPlannerTests: XCTestCase {
    private typealias Window = AutomaticClusterPlanner.Window

    func testAppendPreservesEveryExistingFrameAndNewcomerSize() throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        let first = Window(id: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 250))
        let second = Window(id: 2, frame: CGRect(x: 408, y: 100, width: 180, height: 250))
        let newcomer = Window(id: 3, frame: CGRect(x: 590, y: 132, width: 160, height: 190))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(newcomer, to: [first, second], in: bounds))
        XCTAssertEqual(frames[1], first.frame)
        XCTAssertEqual(frames[2], second.frame)
        XCTAssertEqual(frames[3]?.size, newcomer.frame.size)
        assertValid(frames, in: bounds)
    }

    func testAlternateEdgeAndEndpointAlignmentNearDisplayBorder() throws {
        let bounds = CGRect(x: -900, y: 120, width: 700, height: 500)
        let anchor = Window(id: 1, frame: CGRect(x: -560, y: 170, width: 310, height: 260))
        let newcomer = Window(id: 2, frame: CGRect(x: -240, y: 190, width: 210, height: 180))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(newcomer, to: [anchor], in: bounds))
        XCTAssertEqual(frames[1], anchor.frame)
        XCTAssertEqual(frames[2]?.size, newcomer.frame.size)
        assertValid(frames, in: bounds)
    }

    func testChoosesNearestAvailableEdgeWithoutMovingMembers() throws {
        let bounds = CGRect(x: 0, y: 0, width: 850, height: 560)
        let anchor = Window(id: 1, frame: CGRect(x: 250, y: 160, width: 200, height: 180))
        let incoming = Window(id: 2, frame: CGRect(x: 440, y: 180, width: 110, height: 120))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(incoming, to: [anchor], in: bounds))
        XCTAssertEqual(frames[1], anchor.frame)
        XCTAssertEqual(frames[2]?.origin, CGPoint(x: 458, y: 180))
        assertValid(frames, in: bounds)
    }

    func testAlreadyConnectedBridgeDoesNotRearrangeItsNeighbours() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let left = Window(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let right = Window(id: 2, frame: CGRect(x: 416, y: 0, width: 200, height: 200))
        let bridge = Window(id: 3, frame: CGRect(x: 208, y: 0, width: 200, height: 200))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(bridge, to: [left, right], in: bounds))
        XCTAssertEqual(frames, [1: left.frame, 2: right.frame, 3: bridge.frame])
    }

    func testNewcomerBridgesClosedMemberGapWithoutMovingSurvivors() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let left = Window(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let right = Window(id: 2, frame: CGRect(x: 416, y: 0, width: 200, height: 200))
        let newcomer = Window(id: 3, frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(newcomer, to: [left, right], in: bounds))
        XCTAssertEqual(frames[1], left.frame)
        XCTAssertEqual(frames[2], right.frame)
        assertValid(frames, in: bounds)
    }

    func testRepackingTallMemberBesideStackPreservesSizes() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        for (fixed, reversed) in [(false, false), (true, false), (false, true), (true, true)] {
            let frames = [
                CGRect(x: 0, y: 0, width: 500, height: 800),
                CGRect(x: 508, y: 200, width: 500, height: 396),
                CGRect(x: 100, y: 100, width: 500, height: 396),
            ]
            let windows = frames.enumerated().map {
                Window(id: $0.offset, frame: $0.element,
                       minimumSize: fixed ? $0.element.size : CGSize(width: 240, height: 160))
            }
            let cluster = reversed ? [windows[1], windows[0]] : [windows[0], windows[1]]
            let result = try XCTUnwrap(AutomaticClusterPlanner.append(
                windows[2], to: cluster, in: bounds))
            for window in windows { XCTAssertEqual(result[window.id]?.size, window.frame.size) }
            assertValid(result, in: bounds)
        }
    }

    func testThreeSuccessiveAdditionsStayConnected() throws {
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 650)
        var cluster = [Window(id: 1, frame: CGRect(x: 240, y: 150, width: 200, height: 180))]
        for id in 2...4 {
            let incoming = Window(id: id, frame: CGRect(x: 450, y: 170, width: 150, height: 130))
            let frames = try XCTUnwrap(AutomaticClusterPlanner.append(incoming, to: cluster, in: bounds))
            assertValid(frames, in: bounds)
            cluster.append(Window(id: id, frame: try XCTUnwrap(frames[id])))
        }
    }

    func testRepackingWhenNoUnoccupiedEdgeRemains() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 450)
        let first = Window(id: 1, frame: CGRect(x: 0, y: 0, width: 190, height: 450))
        let second = Window(id: 2, frame: CGRect(x: 198, y: 0, width: 190, height: 450))
        let third = Window(id: 3, frame: CGRect(x: 396, y: 0, width: 190, height: 450))
        let fourth = Window(id: 4, frame: CGRect(x: 350, y: 270, width: 190, height: 430),
                            minimumSize: CGSize(width: 160, height: 160))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(fourth, to: [first, second, third], in: bounds))
        XCTAssertNotEqual(frames[1], first.frame)
        assertValid(frames, in: bounds)
    }

    func testOversizedArrivalCanShrinkWithoutEnlargingItsNeighbours() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let cluster = (0..<3).map {
            Window(id: $0, frame: CGRect(x: CGFloat($0) * 208, y: 0, width: 200, height: 160))
        }
        let newcomer = Window(id: 3, frame: CGRect(x: 0, y: 0, width: 980, height: 500))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(newcomer, to: cluster, in: bounds))
        for window in cluster {
            XCTAssertEqual(frames[window.id]?.size, window.frame.size)
        }
        let added = try XCTUnwrap(frames[3])
        XCTAssertLessThanOrEqual(added.width, newcomer.frame.width)
        XCTAssertLessThan(added.height, newcomer.frame.height)
        assertValid(frames, in: bounds)
    }

    func testAlternateGridFitsWhenSquareGridCannot() throws {
        let bounds = CGRect(x: 0, y: 0, width: 950, height: 340)
        let cluster = (0..<3).map { index in
            Window(id: index, frame: CGRect(x: CGFloat(index) * 308, y: 0, width: 300, height: 320),
                   minimumSize: CGSize(width: 200, height: 250))
        }
        let incoming = Window(id: 3, frame: CGRect(x: 1200, y: 0, width: 300, height: 320),
                              minimumSize: CGSize(width: 200, height: 250))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(incoming, to: cluster, in: bounds))
        assertValid(frames, in: bounds)
        XCTAssertGreaterThanOrEqual(frames[3]!.height, 250)
    }

    func testImpossibleAdditionDoesNotProduceOverlappingClampedTiles() {
        let bounds = CGRect(x: 0, y: 0, width: 430, height: 270)
        let first = Window(id: 1, frame: CGRect(x: 0, y: 0, width: 210, height: 260),
                           minimumSize: CGSize(width: 200, height: 250))
        let second = Window(id: 2, frame: CGRect(x: 218, y: 0, width: 210, height: 260),
                            minimumSize: CGSize(width: 200, height: 250))
        let third = Window(id: 3, frame: CGRect(x: 40, y: 40, width: 210, height: 260),
                           minimumSize: CGSize(width: 200, height: 250))
        XCTAssertNil(AutomaticClusterPlanner.append(third, to: [first, second], in: bounds))
    }

    func testSmallFixedSizeFramesStaySmallOnDirectAppend() throws {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 300)
        let first = Window(id: 1, frame: CGRect(x: 10, y: 10, width: 130, height: 100))
        let second = Window(id: 2, frame: CGRect(x: 150, y: 20, width: 120, height: 90))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(second, to: [first], in: bounds))
        XCTAssertEqual(frames[1], first.frame)
        XCTAssertEqual(frames[2]?.size, second.frame.size)
        assertValid(frames, in: bounds)
    }

    func testEmptyClusterSeedsInsideNegativeOriginBounds() throws {
        let bounds = CGRect(x: -800, y: -600, width: 480, height: 320)
        let newcomer = Window(id: 42, frame: CGRect(x: 500, y: 500, width: 350, height: 240))
        let frames = try XCTUnwrap(AutomaticClusterPlanner.append(newcomer, to: [], in: bounds))
        XCTAssertEqual(frames[42]?.size, newcomer.frame.size)
        assertValid(frames, in: bounds)
    }

    func testDeterministicVariedInputsPreserveGeometryInvariants() throws {
        for seed in 0..<36 {
            let bounds = CGRect(x: CGFloat(seed % 3) * -530, y: CGFloat(seed % 4) * -170,
                                width: 530 + CGFloat(seed % 5) * 90,
                                height: 430 + CGFloat(seed % 4) * 70)
            let anchor = Window(id: 0, frame: CGRect(x: bounds.minX + 60, y: bounds.minY + 50,
                                                      width: 210, height: 180))
            let incoming = Window(id: 1, frame: CGRect(x: bounds.minX + CGFloat(seed * 31 % 540),
                                                        y: bounds.minY + CGFloat(seed * 47 % 360),
                                                        width: 110 + CGFloat(seed % 4) * 30,
                                                        height: 95 + CGFloat(seed % 3) * 35))
            let frames = try XCTUnwrap(AutomaticClusterPlanner.append(incoming, to: [anchor], in: bounds))
            XCTAssertEqual(frames, AutomaticClusterPlanner.append(incoming, to: [anchor], in: bounds))
            XCTAssertEqual(frames[0], anchor.frame)
            assertValid(frames, in: bounds)
        }
    }

    private func assertValid(_ frames: [Int: CGRect], in bounds: CGRect,
                             gap: CGFloat = 8, file: StaticString = #filePath, line: UInt = #line) {
        let entries = frames.sorted { $0.key < $1.key }
        for (_, frame) in entries {
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.001, file: file, line: line)
        }
        var visited = Set<Int>()
        if let first = entries.first { visited.insert(first.key) }
        while true {
            let oldCount = visited.count
            for (id, frame) in entries where visited.contains(id) {
                for (otherID, other) in entries where id != otherID {
                    let overlapX = min(frame.maxX, other.maxX) - max(frame.minX, other.minX)
                    let overlapY = min(frame.maxY, other.maxY) - max(frame.minY, other.minY)
                    if overlapX > 0 {
                        XCTAssertGreaterThanOrEqual(abs(other.minY - frame.maxY) < abs(frame.minY - other.maxY)
                                                    ? other.minY - frame.maxY : frame.minY - other.maxY,
                                                    gap - 0.001, file: file, line: line)
                    }
                    if overlapY > 0 {
                        XCTAssertGreaterThanOrEqual(abs(other.minX - frame.maxX) < abs(frame.minX - other.maxX)
                                                    ? other.minX - frame.maxX : frame.minX - other.maxX,
                                                    gap - 0.001, file: file, line: line)
                    }
                    if (overlapX > 0 && abs(abs(other.minY - frame.maxY) - gap) < 0.001) ||
                        (overlapX > 0 && abs(abs(frame.minY - other.maxY) - gap) < 0.001) ||
                        (overlapY > 0 && abs(abs(other.minX - frame.maxX) - gap) < 0.001) ||
                        (overlapY > 0 && abs(abs(frame.minX - other.maxX) - gap) < 0.001) {
                        visited.insert(otherID)
                    }
                }
            }
            if visited.count == oldCount { break }
        }
        XCTAssertEqual(visited.count, entries.count, file: file, line: line)
    }
}
