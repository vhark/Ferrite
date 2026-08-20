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

public extension ConfigurationRecords {
    /// Sets or clears a slot's pin pattern. Blank input clears it, so a
    /// whitespace-only pattern can never claim the frontmost window.
    mutating func setPinPattern(_ pattern: String?, bundleID: String, slot: Int) {
        guard var slots = apps[bundleID],
              let index = slots.firstIndex(where: { $0.slot == slot }) else { return }
        let trimmed = pattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        slots[index].pinPattern = (trimmed?.isEmpty ?? true) ? nil : trimmed
        apps[bundleID] = slots
    }

    /// Drops every remembered window for an app (stale or unwanted records).
    mutating func forgetApp(bundleID: String) {
        apps.removeValue(forKey: bundleID)
    }
}
