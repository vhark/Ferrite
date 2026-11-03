import Foundation

public struct KeepAwakeSettings: Codable, Equatable {
    public var keepAwakeEnabled: Bool

    public init(keepAwakeEnabled: Bool = false) {
        self.keepAwakeEnabled = keepAwakeEnabled
    }
}

public final class KeepAwakeSettingsStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> KeepAwakeSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(KeepAwakeSettings.self, from: data)
        else { return KeepAwakeSettings() }
        return settings
    }

    public func save(_ settings: KeepAwakeSettings) throws {
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
