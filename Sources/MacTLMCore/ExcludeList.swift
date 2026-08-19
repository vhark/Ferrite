import Foundation

/// Apps persistence never touches. Defaults seeded from Rectangle's
/// known-hostile set (apps that fight external frame changes).
public struct ExcludeList: Codable, Equatable {
    public static let defaults = ExcludeList(bundleIDs: [
        "com.adobe.illustrator",
        "com.adobe.AfterEffects",
        "com.mathworks.matlab",
    ])

    public var bundleIDs: Set<String>

    public init(bundleIDs: Set<String>) {
        self.bundleIDs = bundleIDs
    }

    public func isExcluded(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    public static func load(from url: URL) -> ExcludeList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ExcludeList.self, from: data)
        else { return .defaults }
        return list
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
