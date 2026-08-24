import XCTest
@testable import FerriteCore

/// One-shot MacTLM → Ferrite state migration: copy-never-delete, and above
/// all never clobber anything Ferrite already owns. The salt is the
/// load-bearing value (finding 14): every persisted titleHash derives from
/// it, so it must cross byte-for-byte and must never overwrite a salt the
/// new install already created.
///
/// All defaults access goes through throwaway `dev.ferrite.test.<uuid>`
/// suites removed in teardown — never the real domains.
final class LegacyMigrationTests: XCTestCase {
    var oldDir: URL!
    var newDir: URL!
    var oldSuiteName: String!
    var newSuiteName: String!
    var oldDefaults: UserDefaults!
    var newDefaults: UserDefaults!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
        oldDir = root.appendingPathComponent("MacTLM")
        newDir = root.appendingPathComponent("Ferrite")
        oldSuiteName = "dev.ferrite.test.\(UUID().uuidString)"
        newSuiteName = "dev.ferrite.test.\(UUID().uuidString)"
        oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuiteName))
        newDefaults = try XCTUnwrap(UserDefaults(suiteName: newSuiteName))
    }

    override func tearDownWithError() throws {
        oldDefaults.removePersistentDomain(forName: oldSuiteName)
        newDefaults.removePersistentDomain(forName: newSuiteName)
        try? FileManager.default.removeItem(
            at: oldDir.deletingLastPathComponent())
    }

    /// A plausible legacy Application Support tree: layouts.json,
    /// configurations/, exclude.json.
    private func makeOldDirectory() throws {
        try FileManager.default.createDirectory(
            at: oldDir.appendingPathComponent("configurations"),
            withIntermediateDirectories: true)
        try Data("{\"layouts\":[]}".utf8)
            .write(to: oldDir.appendingPathComponent("layouts.json"))
        try Data("{\"bundleIDs\":[]}".utf8)
            .write(to: oldDir.appendingPathComponent("exclude.json"))
        try Data("{\"records\":{}}".utf8)
            .write(to: oldDir.appendingPathComponent("configurations/abc.json"))
    }

    private func runMigration() -> LegacyMigration.Report {
        LegacyMigration.run(oldDirectory: oldDir, newDirectory: newDir,
                            oldDefaults: oldDefaults, newDefaults: newDefaults)
    }

    private func contentHashes(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            let relative = url.path.replacingOccurrences(
                of: directory.path + "/", with: "")
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    // MARK: - Behaviours

    func testFreshMachineIsANoOp() {
        // No old directory, no old defaults: nothing to migrate.
        let report = runMigration()
        XCTAssertFalse(report.filesCopied)
        XCTAssertFalse(report.saltMigrated)
        XCTAssertEqual(report.hotkeyKeysCopied, [])
        XCTAssertFalse(report.skippedBecause.isEmpty,
                       "a no-op run explains itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path),
                       "migration never invents a new directory")
    }

    func testFullMigrationCopiesDirectorySaltAndHotkeys() throws {
        try makeOldDirectory()
        var saltBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { saltBytes[i] = UInt8(i * 7 % 256) }
        let salt = Data(saltBytes)
        oldDefaults.set(salt, forKey: "dev.mactlm.identitySalt")
        oldDefaults.set("shortcutA", forKey: "KeyboardShortcuts_applyBundle1")
        oldDefaults.set("shortcutB", forKey: "KeyboardShortcuts_applyBundle2")
        oldDefaults.set("not-a-hotkey", forKey: "someUnrelatedKey")

        let report = runMigration()

        XCTAssertTrue(report.filesCopied)
        XCTAssertTrue(report.saltMigrated)
        XCTAssertEqual(Set(report.hotkeyKeysCopied),
                       ["KeyboardShortcuts_applyBundle1",
                        "KeyboardShortcuts_applyBundle2"])
        // Files arrived whole.
        XCTAssertEqual(try contentHashes(of: newDir),
                       try contentHashes(of: oldDir))
        // The old tree is still there: copy, never move.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.path))
        // Salt crossed byte-for-byte.
        XCTAssertEqual(newDefaults.data(forKey: "dev.ferrite.identitySalt"),
                       salt)
        // Hotkeys crossed; unrelated keys did not.
        XCTAssertEqual(newDefaults.string(forKey: "KeyboardShortcuts_applyBundle1"),
                       "shortcutA")
        XCTAssertEqual(newDefaults.string(forKey: "KeyboardShortcuts_applyBundle2"),
                       "shortcutB")
        XCTAssertNil(newDefaults.object(forKey: "someUnrelatedKey"))
    }

    func testSecondRunIsIdempotent() throws {
        try makeOldDirectory()
        oldDefaults.set(Data(repeating: 9, count: 32),
                        forKey: "dev.mactlm.identitySalt")
        oldDefaults.set("shortcutA", forKey: "KeyboardShortcuts_applyBundle1")

        _ = runMigration()
        let filesAfterFirst = try contentHashes(of: newDir)
        // Poison the old tree AFTER the first run: if the second run copied
        // anything, the new tree would change.
        try Data("poisoned".utf8)
            .write(to: oldDir.appendingPathComponent("layouts.json"))

        let second = runMigration()

        XCTAssertFalse(second.filesCopied)
        XCTAssertFalse(second.saltMigrated)
        XCTAssertEqual(second.hotkeyKeysCopied, [])
        XCTAssertFalse(second.skippedBecause.isEmpty)
        XCTAssertEqual(try contentHashes(of: newDir), filesAfterFirst,
                       "second run must not touch migrated files")
    }

    func testExistingNewDirectoryIsNeverOverwritten() throws {
        try makeOldDirectory()
        // A half-adopted install: Ferrite already has its own (different) data.
        try FileManager.default.createDirectory(
            at: newDir, withIntermediateDirectories: true)
        try Data("ferrite-owned".utf8)
            .write(to: newDir.appendingPathComponent("layouts.json"))

        let report = runMigration()

        XCTAssertFalse(report.filesCopied)
        XCTAssertEqual(
            try Data(contentsOf: newDir.appendingPathComponent("layouts.json")),
            Data("ferrite-owned".utf8),
            "existing new-domain files are sacred")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: newDir.appendingPathComponent("exclude.json").path),
            "no partial copy into an existing directory")
    }

    func testSaltIsNeverOverwrittenWhenBothDomainsHaveOne() {
        let oldSalt = Data(repeating: 1, count: 32)
        let newSalt = Data(repeating: 2, count: 32)
        oldDefaults.set(oldSalt, forKey: "dev.mactlm.identitySalt")
        newDefaults.set(newSalt, forKey: "dev.ferrite.identitySalt")

        let report = runMigration()

        XCTAssertFalse(report.saltMigrated)
        XCTAssertEqual(newDefaults.data(forKey: "dev.ferrite.identitySalt"),
                       newSalt,
                       "an existing new-domain salt must survive untouched")
    }

    func testHotkeyCopySkipsKeysAlreadyPresent() {
        oldDefaults.set("old-A", forKey: "KeyboardShortcuts_applyBundle1")
        oldDefaults.set("old-B", forKey: "KeyboardShortcuts_applyBundle2")
        newDefaults.set("ferrite-A", forKey: "KeyboardShortcuts_applyBundle1")

        let report = runMigration()

        XCTAssertEqual(report.hotkeyKeysCopied, ["KeyboardShortcuts_applyBundle2"])
        XCTAssertEqual(newDefaults.string(forKey: "KeyboardShortcuts_applyBundle1"),
                       "ferrite-A",
                       "a key the user already re-recorded is never clobbered")
        XCTAssertEqual(newDefaults.string(forKey: "KeyboardShortcuts_applyBundle2"),
                       "old-B")
    }

    func testMissingOldDefaultsSkipsSaltAndHotkeysButStillCopiesFiles() throws {
        try makeOldDirectory()

        let report = LegacyMigration.run(
            oldDirectory: oldDir, newDirectory: newDir,
            oldDefaults: nil, newDefaults: newDefaults)

        XCTAssertTrue(report.filesCopied)
        XCTAssertFalse(report.saltMigrated)
        XCTAssertEqual(report.hotkeyKeysCopied, [])
        XCTAssertTrue(report.skippedBecause.contains { $0.contains("defaults") },
                      "an unreadable old domain is reported, not silent (plan risk note)")
    }
}
