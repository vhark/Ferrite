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
    /// Bundle names hidden from the menu and from hotkey registration.
    /// Archiving is reversible; only the archive can permanently delete.
    public var archivedBundleNames: Set<String>

    public init(layouts: [MonitorLayout] = [],
                archivedBundleNames: Set<String> = []) {
        self.layouts = layouts
        self.archivedBundleNames = archivedBundleNames
    }

    private enum CodingKeys: String, CodingKey {
        case layouts, archivedBundleNames
    }

    /// Absent-tolerant: files written before archiving existed have no
    /// `archivedBundleNames` key and MUST still decode (a failure here would
    /// make the fail-soft store load an empty library and lose real layouts).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try container.decodeIfPresent([MonitorLayout].self,
                                                forKey: .layouts) ?? []
        archivedBundleNames = try container.decodeIfPresent(
            Set<String>.self, forKey: .archivedBundleNames) ?? []
    }

    /// Replaces layouts sharing a (name, displayID) key with the incoming ones,
    /// appending the rest. Re-snapshotting a name edits it in place (PRD §3.2).
    /// Saving over an archived name reactivates it.
    public mutating func upsert(_ incoming: [MonitorLayout]) {
        let keys = Set(incoming.map { "\($0.name)\u{0}\($0.displayID)" })
        layouts.removeAll { keys.contains("\($0.name)\u{0}\($0.displayID)") }
        layouts.append(contentsOf: incoming)
        archivedBundleNames.subtract(incoming.map(\.name))
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
    /// Active (non-archived) bundles, and archived ones, both name-sorted.
    func activeBundles() -> [LayoutBundle] {
        bundles().filter { !archivedBundleNames.contains($0.name) }
    }

    func archivedBundles() -> [LayoutBundle] {
        bundles().filter { archivedBundleNames.contains($0.name) }
    }

    mutating func archiveBundle(named name: String) {
        guard layouts.contains(where: { $0.name == name }) else { return }
        archivedBundleNames.insert(name)
    }

    mutating func restoreBundle(named name: String) {
        archivedBundleNames.remove(name)
    }
}

public extension LayoutLibrary {
    /// Renames every layout in a bundle, carrying the archived flag across.
    /// If the new name collides on a display, the renamed layout wins (same
    /// rule as `upsert`).
    mutating func renameBundle(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        let renamed = layouts.filter { $0.name == oldName }.map { layout -> MonitorLayout in
            var copy = layout
            copy.name = newName
            return copy
        }
        guard !renamed.isEmpty else { return }
        let wasArchived = archivedBundleNames.remove(oldName) != nil
        layouts.removeAll { $0.name == oldName }
        upsert(renamed)   // clears newName from the archive
        if wasArchived { archivedBundleNames.insert(newName) }
    }

    /// Permanent delete: drops the layouts and any archive entry for the name.
    mutating func deleteBundle(named name: String) {
        layouts.removeAll { $0.name == name }
        archivedBundleNames.remove(name)
    }

    mutating func setStageMode(_ mode: StageMode, forBundleNamed name: String) {
        for index in layouts.indices where layouts[index].name == name {
            layouts[index].stageMode = mode
        }
    }
}

public extension LayoutLibrary {
    /// Removes one window from a layout and reindexes zIndex contiguously so
    /// the remaining windows keep a well-ordered stacking sequence.
    mutating func removeEntry(atIndex index: Int, fromLayoutID layoutID: UUID) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[layoutIndex].entries.indices.contains(index) else { return }
        layouts[layoutIndex].entries.remove(at: index)
        let reordered = layouts[layoutIndex].entries
            .enumerated()
            .sorted { $0.element.zIndex < $1.element.zIndex }
        var rebuilt = layouts[layoutIndex].entries
        for (newZ, pair) in reordered.enumerated() {
            rebuilt[pair.offset].zIndex = newZ
        }
        layouts[layoutIndex].entries = rebuilt
    }

    mutating func setEntryOptional(_ optional: Bool, atIndex index: Int,
                                   inLayoutID layoutID: UUID) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[layoutIndex].entries.indices.contains(index) else { return }
        layouts[layoutIndex].entries[index].optional = optional
    }
}
