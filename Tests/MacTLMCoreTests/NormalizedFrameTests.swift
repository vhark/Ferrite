import XCTest
@testable import MacTLMCore

final class NormalizedFrameTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975) // laptop, menu bar cut

    func testRoundTripIsExactOnSameArea() {
        let original = CGRect(x: 320, y: 74, width: 400, height: 877)
        let normalized = NormalizedFrame(windowFrame: original, visibleArea: area)
        let restored = normalized.rect(in: area)
        XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
        XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
    }

    func testRemapToDifferentAreaScalesProportionally() {
        // Right half of the source area…
        let original = CGRect(x: 800, y: 25, width: 800, height: 975)
        let normalized = NormalizedFrame(windowFrame: original, visibleArea: area)
        // …must map to the right half of any target area.
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1415)
        let remapped = normalized.rect(in: ultrawide)
        XCTAssertEqual(remapped.minX, 1720, accuracy: 0.001)
        XCTAssertEqual(remapped.minY, 0, accuracy: 0.001)
        XCTAssertEqual(remapped.width, 1720, accuracy: 0.001)
        XCTAssertEqual(remapped.height, 1415, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let frame = NormalizedFrame(x: 0.25, y: 0.1, w: 0.5, h: 0.8)
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(NormalizedFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }
}
