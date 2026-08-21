import XCTest
@testable import MacTLMCore

/// The purge used to reach only the namespace the tracker had loaded, so files
/// for display arrangements you had not reattached kept plaintext titles.
final class LegacyTitlePurgeAllNamespacesTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One legacy per-config file: a single record carrying the dropped
    /// plaintext `title` key, plus an optional pin that must survive the scrub.
    private func writeLegacyConfig(key: String, secret: String,
                                   pinPattern: String?) throws {
        let pin = pinPattern.map { ",\"pinPattern\":\"\($0)\"" } ?? ""
        let legacy = """
        {"apps":{"com.apple.finder":[{"frame":{"h":0.6,"w":0.16,"x":0.02,"y":0.2},
        "lastSeen":"2026-08-19T00:00:00Z"\(pin),"slot":0,"title":"\(secret)",
        "titleHash":"h:abc"}]}}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("\(key).json"))
    }

    private func rawText(_ key: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("\(key).json"),
                   encoding: .utf8)
    }

    private func modificationDate(_ key: String) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("\(key).json").path)
        return attrs[.modificationDate] as! Date
    }

    func testPurgeScrubsEveryNamespaceFile() throws {
        try writeLegacyConfig(key: "laptop", secret: "Secret A", pinPattern: nil)
        try writeLegacyConfig(key: "desk", secret: "Secret B", pinPattern: "Inbox.*")
        try writeLegacyConfig(key: "dock", secret: "Secret C", pinPattern: nil)

        store.purgeLegacyTitlesInAllNamespaces()

        for key in ["laptop", "desk", "dock"] {
            let text = try rawText(key)
            XCTAssertFalse(text.contains("\"title\""),
                           "\(key) must lose the legacy title key")
            XCTAssertFalse(text.contains("Secret"),
                           "\(key) must lose the plaintext title value")
            XCTAssertEqual(store.load(configKey: key).apps["com.apple.finder"]?.count, 1,
                           "\(key) keeps its record")
        }
        XCTAssertEqual(store.load(configKey: "desk").apps["com.apple.finder"]?[0].pinPattern,
                       "Inbox.*", "pins are user data and survive the scrub")
    }

    func testPurgeIsIdempotentAndLeavesCleanFilesAlone() throws {
        try writeLegacyConfig(key: "laptop", secret: "Secret A", pinPattern: nil)
        try writeLegacyConfig(key: "desk", secret: "Secret B", pinPattern: "Inbox.*")

        store.purgeLegacyTitlesInAllNamespaces()
        let firstPass = try ["laptop", "desk"].map { try modificationDate($0) }
        let firstText = try ["laptop", "desk"].map { try rawText($0) }
        Thread.sleep(forTimeInterval: 0.05)

        store.purgeLegacyTitlesInAllNamespaces()

        for (index, key) in ["laptop", "desk"].enumerated() {
            XCTAssertEqual(try modificationDate(key), firstPass[index],
                           "an already-clean \(key) must not be rewritten")
            XCTAssertEqual(try rawText(key), firstText[index])
        }
    }

    func testLibraryPurgeSideEffectForm() throws {
        let url = directory.appendingPathComponent("layouts.json")
        let legacy = """
        {"layouts":[{"createdAt":"2026-08-19T00:00:00Z","displayID":"A",
        "displayMetrics":{"height":1000,"id":"A","scale":2,"width":1600},
        "displayName":"DA","entries":[{"bundleID":"com.apple.finder",
        "frame":{"h":1,"w":1,"x":0,"y":0},"optional":false,
        "title":"Secret Library","zIndex":0}],
        "id":"AAAAAAAA-0000-0000-0000-000000000001","name":"W",
        "stageMode":"leaveOthers"}]}
        """
        try Data(legacy.utf8).write(to: url)
        let library = LayoutLibraryStore(url: url)

        library.purgeLegacyTitles()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\"title\""), "legacy key is gone from disk")
        XCTAssertFalse(text.contains("Secret Library"), "plaintext is gone from disk")
        let reloaded = library.load()
        XCTAssertEqual(reloaded.layouts.count, 1, "the layout survives")
        XCTAssertEqual(reloaded.layouts[0].entries.first?.bundleID, "com.apple.finder",
                       "the entry survives")
    }
}
