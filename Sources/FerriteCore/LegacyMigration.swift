import Foundation

/// One-shot, first-launch migration of MacTLM state into Ferrite.
///
/// Copy-never-delete: the old MacTLM directory and defaults domain stay on
/// disk untouched, as their own rollback. Every step is copy-if-new-absent,
/// so a half-adopted Ferrite install is never clobbered and a second run is
/// a reported no-op.
///
/// The salt is THE load-bearing value (finding 14): every persisted
/// titleHash derives from it, so it crosses byte-for-byte and never
/// overwrites a salt the new install already created — losing either way
/// silently orphans every stored titleHash.
///
/// Foundation only (`FileManager`, `UserDefaults` are in
/// corelibs-foundation), so Core stays portable.
public enum LegacyMigration {
    /// Old MacTLM salt key. Read-only: migration is the one place the old
    /// name survives in code.
    public static let oldSaltKey = "dev.mactlm.identitySalt"
    public static let newSaltKey = "dev.ferrite.identitySalt"
    /// The KeyboardShortcuts library persists recorded hotkeys under this
    /// prefix in the app's standard defaults.
    public static let hotkeyKeyPrefix = "KeyboardShortcuts_"

    public struct Report {
        /// The whole old directory was copied to the new location.
        public let filesCopied: Bool
        /// The old salt was copied verbatim into the new domain.
        public let saltMigrated: Bool
        /// Old-domain hotkey keys copied because they were absent new-side.
        public let hotkeyKeysCopied: [String]
        /// Why each step that did nothing did nothing.
        public let skippedBecause: [String]

        public var didAnything: Bool {
            filesCopied || saltMigrated || !hotkeyKeysCopied.isEmpty
        }

        /// One-line startup summary.
        public var summary: String {
            var parts: [String] = []
            if filesCopied { parts.append("files copied") }
            if saltMigrated { parts.append("salt migrated") }
            if !hotkeyKeysCopied.isEmpty {
                parts.append("\(hotkeyKeysCopied.count) hotkey key(s) copied")
            }
            parts.append(contentsOf: skippedBecause)
            return parts.joined(separator: "; ")
        }
    }

    /// Runs the migration. Idempotent; every step independently no-ops when
    /// the new side already has the data. `oldDefaults` is optional because
    /// `UserDefaults(suiteName:)` is — an unreadable old domain is reported,
    /// never silently skipped.
    @discardableResult
    public static func run(oldDirectory: URL, newDirectory: URL,
                           oldDefaults: UserDefaults?,
                           newDefaults: UserDefaults) -> Report {
        var skipped: [String] = []

        // 1. Files: whole-directory copy, only onto virgin ground.
        var filesCopied = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: newDirectory.path) {
            skipped.append("files: new directory already exists")
        } else if !fileManager.fileExists(atPath: oldDirectory.path) {
            skipped.append("files: no old directory")
        } else {
            do {
                try fileManager.createDirectory(
                    at: newDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.copyItem(at: oldDirectory, to: newDirectory)
                filesCopied = true
            } catch {
                skipped.append("files: copy failed: \(error)")
            }
        }

        // 2. Salt: verbatim bytes, and NEVER over an existing new-domain salt.
        var saltMigrated = false
        if newDefaults.data(forKey: newSaltKey) != nil {
            skipped.append("salt: new domain already has one")
        } else if let oldDefaults {
            if let salt = oldDefaults.data(forKey: oldSaltKey) {
                newDefaults.set(salt, forKey: newSaltKey)
                saltMigrated = true
            } else {
                skipped.append("salt: old domain has none")
            }
        } else {
            skipped.append("salt: old defaults domain unreadable")
        }

        // 3. Hotkeys: copy prefixed keys absent from the new domain. The
        // KeyboardShortcuts library reads the app's standard defaults, so
        // copied keys light up with no library changes.
        var hotkeyKeysCopied: [String] = []
        if let oldDefaults {
            let hotkeyKeys = oldDefaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(hotkeyKeyPrefix) }
                .sorted()
            for key in hotkeyKeys where newDefaults.object(forKey: key) == nil {
                if let value = oldDefaults.object(forKey: key) {
                    newDefaults.set(value, forKey: key)
                    hotkeyKeysCopied.append(key)
                }
            }
            if hotkeyKeysCopied.isEmpty {
                skipped.append(hotkeyKeys.isEmpty
                    ? "hotkeys: old domain has none"
                    : "hotkeys: all already present")
            }
        } else {
            skipped.append("hotkeys: old defaults domain unreadable")
        }

        return Report(filesCopied: filesCopied, saltMigrated: saltMigrated,
                      hotkeyKeysCopied: hotkeyKeysCopied,
                      skippedBecause: skipped)
    }
}
