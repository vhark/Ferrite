import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Tunable magnet-gesture behavior. Lives in magnets.json beside layouts.json
/// and reflows.json, so it syncs with the rest of the user's configuration.
public struct MagnetSettings: Codable, Equatable {
    /// Bounds the model and the UI share, so a slider can never offer a value
    /// the model would silently rewrite.
    public static let minimumMateReach: CGFloat = 8
    public static let maximumMateReach: CGFloat = 128

    /// How near facing edges must be before a mate is offered, in points.
    /// Clamped on every way in: a zero or negative reach would disable mating
    /// with no way back from the UI (the slider could no longer be reached by
    /// a gesture that never fires), and an enormous one would mate across the
    /// display.
    public var mateReach: CGFloat {
        get { reach }
        set { reach = Self.clampedMateReach(newValue) }
    }

    private var reach: CGFloat

    public init(mateReach: CGFloat = MagnetMating.defaultThreshold) {
        reach = Self.clampedMateReach(mateReach)
    }

    public static func clampedMateReach(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumMateReach), maximumMateReach)
    }

    enum CodingKeys: String, CodingKey {
        case mateReach
    }

    /// Absent-tolerant: a missing field decodes to the built-in default, so a
    /// file written by an older Ferrite can never be read as zero and written
    /// back as a disabled gesture (finding 11).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(CGFloat.self, forKey: .mateReach)
        reach = Self.clampedMateReach(stored ?? MagnetMating.defaultThreshold)
    }

    /// Hand-written because the stored property is private behind the clamping
    /// accessor; the file must still read as a plain `mateReach`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reach, forKey: .mateReach)
    }
}

/// JSON persistence for magnet settings. Same posture as ReflowStore:
/// fail-soft load, atomic deterministic save.
public final class MagnetSettingsStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> MagnetSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(MagnetSettings.self, from: data)
        else { return MagnetSettings() }
        return settings
    }

    public func save(_ settings: MagnetSettings) throws {
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
