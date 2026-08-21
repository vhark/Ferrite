import Foundation

/// One remembered window of an app, within one display configuration.
///
/// `titleHash` is an opaque per-install identity (see `WindowIdentity` in the
/// app layer), never the readable title: titles are browsing history and these
/// files are designed to be syncable (PRD §7).
public struct WindowRecord: Codable, Equatable {
    public var slot: Int              // stable index within the app's windows
    public var titleHash: String?     // opaque identity at capture time
    public var frame: NormalizedFrame
    public var pinPattern: String?    // optional regex matched against live titles
    public var lastSeen: Date

    /// Deliberately omits `title`: files written before hashed identities carry
    /// that key, and it must be ignored on decode and never re-encoded.
    enum CodingKeys: String, CodingKey {
        case slot, titleHash, frame, pinPattern, lastSeen
    }

    public init(slot: Int, titleHash: String?, frame: NormalizedFrame,
                pinPattern: String?, lastSeen: Date) {
        self.slot = slot; self.titleHash = titleHash; self.frame = frame
        self.pinPattern = pinPattern; self.lastSeen = lastSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(Int.self, forKey: .slot)
        titleHash = try container.decodeIfPresent(String.self, forKey: .titleHash)
        frame = try container.decode(NormalizedFrame.self, forKey: .frame)
        pinPattern = try container.decodeIfPresent(String.self, forKey: .pinPattern)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
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
