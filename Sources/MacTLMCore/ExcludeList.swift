import Foundation

/// Apps persistence never touches.
///
/// The defaults seed the list with apps that fight external frame changes, but
/// membership is meant to be *measured*, not inherited. The seed originally came
/// from Rectangle's known-hostile set; `--probe-frame com.adobe.illustrator`
/// (2026-08-21) nudged a real Illustrator window, read the frame back and got
/// the requested rect — it ACCEPTS frame changes, so Illustrator is now managed
/// like any other app. After Effects and MATLAB stay until someone can run the
/// same probe against them.
///
/// Any app can be re-excluded (or un-excluded) in Preferences > Apps.
public struct ExcludeList: Codable, Equatable {
    public static let defaults = ExcludeList(bundleIDs: [
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
