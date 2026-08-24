import XCTest
@testable import FerriteCore

final class ZOrderMatcherTests: XCTestCase {
    func testAssignsFrontToBackIndices() {
        let ax = [
            ZOrderMatcher.AXRef(id: 10, pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            ZOrderMatcher.AXRef(id: 11, pid: 200, frame: CGRect(x: 50, y: 50, width: 400, height: 300)),
        ]
        let cg = [ // front-to-back
            ZOrderMatcher.CGRef(pid: 200, frame: CGRect(x: 50, y: 50, width: 400, height: 300)),
            ZOrderMatcher.CGRef(pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
        ]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(z[11], 0, "pid 200 window is frontmost")
        XCTAssertEqual(z[10], 1)
    }

    func testToleratesSmallFrameDrift() {
        let ax = [ZOrderMatcher.AXRef(id: 10, pid: 100,
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        let cg = [ZOrderMatcher.CGRef(pid: 100,
                                      frame: CGRect(x: 1.5, y: -1.0, width: 401, height: 299))]
        XCTAssertEqual(ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)[10], 0)
    }

    func testUnmatchedWindowsGetBackAppendedIndices() {
        let ax = [
            ZOrderMatcher.AXRef(id: 10, pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            ZOrderMatcher.AXRef(id: 11, pid: 100, frame: CGRect(x: 900, y: 900, width: 100, height: 100)),
        ]
        let cg = [ZOrderMatcher.CGRef(pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(z[10], 0)
        XCTAssertEqual(z[11], 1, "unmatched window appended behind matched ones")
    }

    func testSameFrameSamePidWindowsConsumeCGEntriesInOrder() {
        // Two identical windows (same pid, same frame): each CG entry may claim
        // only one AX window and vice versa.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ax = [ZOrderMatcher.AXRef(id: 10, pid: 100, frame: frame),
                  ZOrderMatcher.AXRef(id: 11, pid: 100, frame: frame)]
        let cg = [ZOrderMatcher.CGRef(pid: 100, frame: frame),
                  ZOrderMatcher.CGRef(pid: 100, frame: frame)]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(Set(z.values), [0, 1])
        XCTAssertEqual(z.count, 2)
    }
}
