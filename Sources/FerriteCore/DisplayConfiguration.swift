import Foundation

public struct DisplayInfo: Codable, Equatable, Comparable {
    public let id: String       // display UUID string
    public let width: Double    // points
    public let height: Double   // points
    public let scale: Double

    public init(id: String, width: Double, height: Double, scale: Double) {
        self.id = id; self.width = width; self.height = height; self.scale = scale
    }

    public static func < (a: DisplayInfo, b: DisplayInfo) -> Bool { a.id < b.id }
}

public struct DisplayConfiguration: Equatable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays.sorted()
    }

    /// Stable, filesystem-safe namespace key for this set of displays.
    public var key: String {
        displays
            .map { "\($0.id)_\(Int($0.width))x\(Int($0.height))@\($0.scale)" }
            .joined(separator: "+")
    }
}
