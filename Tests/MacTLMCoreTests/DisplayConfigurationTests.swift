import XCTest
@testable import MacTLMCore

final class DisplayConfigurationTests: XCTestCase {
    let laptop = DisplayInfo(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                             width: 1600, height: 1000, scale: 2.0)
    let ultrawide = DisplayInfo(id: "A46D2F5E-0000-0000-1A2B-0104B53F0000",
                                width: 3440, height: 1440, scale: 1.0)

    func testKeyIsStableAcrossDisplayOrdering() {
        let a = DisplayConfiguration(displays: [laptop, ultrawide])
        let b = DisplayConfiguration(displays: [ultrawide, laptop])
        XCTAssertEqual(a.key, b.key)
    }

    func testDifferentConfigurationsGetDifferentKeys() {
        let solo = DisplayConfiguration(displays: [laptop])
        let dual = DisplayConfiguration(displays: [laptop, ultrawide])
        XCTAssertNotEqual(solo.key, dual.key)
    }

    func testKeyIsFilesystemSafe() {
        let key = DisplayConfiguration(displays: [laptop, ultrawide]).key
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        XCTAssertNil(key.rangeOfCharacter(from: forbidden))
    }
}
