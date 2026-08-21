import Foundation

/// JSON persistence: one `<configKey>.json` per display configuration.
/// Files are pretty-printed and sorted so they diff cleanly under git/Nextcloud.
public final class LayoutStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(configKey: String) -> ConfigurationRecords {
        guard let data = try? Data(contentsOf: url(for: configKey)),
              let records = try? decoder.decode(ConfigurationRecords.self, from: data)
        else { return ConfigurationRecords() }
        return records
    }

    /// Loads, and if the file still contains a legacy plaintext `title` key,
    /// immediately rewrites it without one. Titles were never meant to be at
    /// rest (PRD §7 files are syncable), so the scrub happens on first read.
    public func loadPurgingLegacyTitles(configKey: String) -> ConfigurationRecords {
        let records = load(configKey: configKey)
        guard let data = try? Data(contentsOf: url(for: configKey)),
              let text = String(data: data, encoding: .utf8),
              text.contains("\"title\"") else { return records }
        try? save(records, configKey: configKey)   // re-encodes without the dropped key
        return records
    }

    /// Scrubs legacy plaintext `title` keys from EVERY namespace on disk, not
    /// just the one currently loaded. Titles were never meant to persist, and
    /// a namespace for a display arrangement you have not reattached yet would
    /// otherwise keep them indefinitely.
    public func purgeLegacyTitlesInAllNamespaces() {
        for key in configKeys() {
            _ = loadPurgingLegacyTitles(configKey: key)
        }
    }

    /// Every display-configuration namespace with a file on disk. Pin edits
    /// reach across namespaces, so the tracker needs to know which exist.
    public func configKeys() -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return (contents ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func save(_ records: ConfigurationRecords, configKey: String) throws {
        try encoder.encode(records).write(to: url(for: configKey), options: .atomic)
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
