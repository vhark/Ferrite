import XCTest
@testable import FerriteCore

final class WindowIdentityMatchingTests: XCTestCase {
    private func record(slot: Int, hash: String?, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, titleHash: hash,
                     frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.5),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testMatchesByTitleHashNotTitleText() {
        let records = [record(slot: 0, hash: "aaaa1111"),
                       record(slot: 1, hash: "bbbb2222")]
        // Reopened in swapped order; hashes must still pair correctly.
        let windows = [WindowCandidate(id: 10, title: "irrelevant",
                                       titleHash: "bbbb2222", order: 0),
                       WindowCandidate(id: 11, title: "irrelevant",
                                       titleHash: "aaaa1111", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testNilHashesDoNotMatchEachOther() {
        let records = [record(slot: 0, hash: nil), record(slot: 1, hash: nil)]
        let windows = [WindowCandidate(id: 10, title: "", titleHash: nil, order: 0),
                       WindowCandidate(id: 11, title: "", titleHash: nil, order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        // Falls through to order pairing, never hash-equality on nil.
        XCTAssertEqual(result[10]?.slot, 0)
        XCTAssertEqual(result[11]?.slot, 1)
    }

    func testPinsStillMatchAgainstLiveTitle() {
        // Pins are user-authored patterns tested against the LIVE title, which
        // is in memory only — so pinning still works with titles unpersisted.
        let records = [record(slot: 0, hash: "zzzz9999", pin: "Titan"),
                       record(slot: 1, hash: "yyyy8888")]
        let windows = [WindowCandidate(id: 10, title: "Koa (Health Coach)",
                                       titleHash: "nope0000", order: 0),
                       WindowCandidate(id: 11, title: "Titan (Coach)",
                                       titleHash: "nope1111", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[11]?.slot, 0, "pin claims by live title")
        XCTAssertEqual(result[10]?.slot, 1)
    }

    func testRecordCodableHasNoTitleKey() throws {
        let records = ConfigurationRecords(apps: ["a": [record(slot: 0, hash: "abcd1234")]])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(records), as: UTF8.self)
        XCTAssertFalse(json.contains("\"title\""),
                       "no title key may ever be written to disk")
        XCTAssertTrue(json.contains("titleHash"))
    }

    func testLegacyRecordsWithPlaintextTitleDecodeAndDropIt() throws {
        // Files written before this change carry "title"; it must be ignored,
        // not crash, and must not survive a re-encode.
        let json = """
        {"apps":{"a":[{"frame":{"h":0.5,"w":0.5,"x":0,"y":0},
        "lastSeen":"2026-08-19T00:00:00Z","slot":0,"title":"Secret Page Title"}]}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConfigurationRecords.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(decoded.apps["a"]?.count, 1)
        XCTAssertNil(decoded.apps["a"]?[0].titleHash)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("Secret Page Title"),
                       "legacy plaintext must not be rewritten")
    }

    func testLayoutEntryCodableHasNoTitleKey() throws {
        let entry = LayoutEntry(bundleID: "a", titleHash: "abcd1234",
                                frame: NormalizedFrame(x: 0, y: 0, w: 1, h: 1),
                                zIndex: 0, pinPattern: nil, optional: false)
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertFalse(json.contains("\"title\""))
    }
}
