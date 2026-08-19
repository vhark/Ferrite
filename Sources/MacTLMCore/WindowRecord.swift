import Foundation

/// One remembered window of an app, within one display configuration.
public struct WindowRecord: Codable, Equatable {
    public var slot: Int              // stable index within the app's windows
    public var title: String          // title snapshot at capture time
    public var frame: NormalizedFrame
    public var pinPattern: String?    // optional regex matched against titles
    public var lastSeen: Date

    public init(slot: Int, title: String, frame: NormalizedFrame,
                pinPattern: String?, lastSeen: Date) {
        self.slot = slot; self.title = title; self.frame = frame
        self.pinPattern = pinPattern; self.lastSeen = lastSeen
    }
}

/// Everything remembered for one display configuration: bundleID → window slots.
public struct ConfigurationRecords: Codable, Equatable {
    public var apps: [String: [WindowRecord]]

    public init(apps: [String: [WindowRecord]] = [:]) {
        self.apps = apps
    }
}
