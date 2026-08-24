import XCTest
@testable import FerriteCore

final class WindowRecordTests: XCTestCase {
    func testConfigurationRecordsCodableRoundTrip() throws {
        var records = ConfigurationRecords()
        records.apps["company.thebrowser.Browser"] = [
            WindowRecord(slot: 0, titleHash: "h:Work",
                         frame: NormalizedFrame(x: 0.22, y: 0.05, w: 0.25, h: 0.90),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
            WindowRecord(slot: 1, titleHash: "h:Personal",
                         frame: NormalizedFrame(x: 0.48, y: 0.05, w: 0.25, h: 0.90),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConfigurationRecords.self,
                                         from: try encoder.encode(records))
        XCTAssertEqual(decoded, records)
    }
}
