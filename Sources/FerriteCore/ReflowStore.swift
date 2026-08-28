import Foundation

/// A user-defined reflow preset pinned to the menu's glyph rows.
public struct CustomReflowPreset: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var preset: GroupLayoutSolver.Preset

    public init(id: UUID = UUID(), name: String,
                preset: GroupLayoutSolver.Preset) {
        self.id = id
        self.name = name
        self.preset = preset
    }
}

/// Everything reflow-related that persists: pinned custom presets and the
/// display-reflow group policy. Lives in reflows.json next to layouts.json —
/// sync-friendly like the rest of the App Support directory.
public struct ReflowSettings: Codable, Equatable {
    public var customPresets: [CustomReflowPreset]
    /// Display reflow policy: false (default) explodes magnet groups —
    /// members reflow individually and membership is dissolved; true keeps
    /// each intact group as one tile.
    public var keepGroupsOnDisplayReflow: Bool

    public init(customPresets: [CustomReflowPreset] = [],
                keepGroupsOnDisplayReflow: Bool = false) {
        self.customPresets = customPresets
        self.keepGroupsOnDisplayReflow = keepGroupsOnDisplayReflow
    }

    enum CodingKeys: String, CodingKey {
        case customPresets, keepGroupsOnDisplayReflow
    }

    /// Absent-tolerant: every field decodes to its default when missing, so
    /// adding fields later can never wipe a real file (finding 11).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customPresets = try container.decodeIfPresent(
            [CustomReflowPreset].self, forKey: .customPresets) ?? []
        keepGroupsOnDisplayReflow = try container.decodeIfPresent(
            Bool.self, forKey: .keepGroupsOnDisplayReflow) ?? false
    }
}

/// JSON persistence for reflow settings. Same posture as LayoutLibraryStore:
/// fail-soft load, atomic deterministic save.
public final class ReflowStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> ReflowSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(ReflowSettings.self, from: data)
        else { return ReflowSettings() }
        return settings
    }

    public func save(_ settings: ReflowSettings) throws {
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
