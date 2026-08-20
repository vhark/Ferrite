import Foundation

/// What happens to windows NOT in the layout when it launches (PRD §3.2).
public enum StageMode: String, Codable, Equatable {
    case leaveOthers   // template only places its own apps
    case clearStage    // non-members get hidden
}

/// One window slot in a saved layout. zIndex 0 = frontmost.
public struct LayoutEntry: Codable, Equatable {
    public var bundleID: String
    public var title: String          // snapshot title, improves adopt matching
    public var frame: NormalizedFrame
    public var zIndex: Int
    public var pinPattern: String?    // JSON-editable, like WindowRecord pins
    public var optional: Bool         // skipped when adapting to a smaller display

    public init(bundleID: String, title: String, frame: NormalizedFrame,
                zIndex: Int, pinPattern: String?, optional: Bool) {
        self.bundleID = bundleID; self.title = title; self.frame = frame
        self.zIndex = zIndex; self.pinPattern = pinPattern; self.optional = optional
    }
}

/// A saved arrangement for ONE display (PRD §4: templates decompose per monitor).
public struct MonitorLayout: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var displayID: String        // display UUID at capture time
    public var displayName: String      // human name for menu sections
    public var displayMetrics: DisplayInfo
    public var stageMode: StageMode
    public var entries: [LayoutEntry]
    public var createdAt: Date

    public init(id: UUID, name: String, displayID: String, displayName: String,
                displayMetrics: DisplayInfo, stageMode: StageMode,
                entries: [LayoutEntry], createdAt: Date) {
        self.id = id; self.name = name; self.displayID = displayID
        self.displayName = displayName; self.displayMetrics = displayMetrics
        self.stageMode = stageMode; self.entries = entries; self.createdAt = createdAt
    }
}

/// Every saved layout. Bundles (multi-display linking) arrive in M2b.
public struct LayoutLibrary: Codable, Equatable {
    public var layouts: [MonitorLayout]

    public init(layouts: [MonitorLayout] = []) {
        self.layouts = layouts
    }

    /// Replaces layouts sharing a (name, displayID) key with the incoming ones,
    /// appending the rest. Re-snapshotting a name edits it in place (PRD §3.2).
    public mutating func upsert(_ incoming: [MonitorLayout]) {
        let keys = Set(incoming.map { "\($0.name)\u{0}\($0.displayID)" })
        layouts.removeAll { keys.contains("\($0.name)\u{0}\($0.displayID)") }
        layouts.append(contentsOf: incoming)
    }
}

/// A named workspace: every saved layout sharing one name, one per display.
/// Derived from the library rather than persisted — `upsert` already keys on
/// (name, displayID), so same-name layouts across displays are a bundle.
public struct LayoutBundle: Equatable {
    public let name: String
    public let layouts: [MonitorLayout]

    public var spansMultipleDisplays: Bool {
        Set(layouts.map(\.displayID)).count > 1
    }

    public init(name: String, layouts: [MonitorLayout]) {
        self.name = name
        self.layouts = layouts
    }
}

public extension LayoutLibrary {
    /// Bundles sorted by name; each bundle's layouts sorted by display name.
    func bundles() -> [LayoutBundle] {
        Dictionary(grouping: layouts, by: \.name)
            .sorted { $0.key < $1.key }
            .map { name, group in
                LayoutBundle(name: name,
                             layouts: group.sorted { $0.displayID < $1.displayID })
            }
    }
}

public extension LayoutLibrary {
    /// Renames every layout in a bundle. If the new name collides on a display,
    /// the renamed layout wins (same rule as `upsert`).
    mutating func renameBundle(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        let renamed = layouts.filter { $0.name == oldName }.map { layout -> MonitorLayout in
            var copy = layout
            copy.name = newName
            return copy
        }
        guard !renamed.isEmpty else { return }
        layouts.removeAll { $0.name == oldName }
        upsert(renamed)
    }

    mutating func deleteBundle(named name: String) {
        layouts.removeAll { $0.name == name }
    }

    mutating func setStageMode(_ mode: StageMode, forBundleNamed name: String) {
        for index in layouts.indices where layouts[index].name == name {
            layouts[index].stageMode = mode
        }
    }
}
