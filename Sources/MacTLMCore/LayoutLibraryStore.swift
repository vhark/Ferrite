import Foundation

/// JSON persistence for the layout library at a single file URL.
/// Same posture as LayoutStore: fail-soft load, atomic deterministic save.
public final class LayoutLibraryStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> LayoutLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? decoder.decode(LayoutLibrary.self, from: data)
        else { return LayoutLibrary() }
        return library
    }

    public func save(_ library: LayoutLibrary) throws {
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
