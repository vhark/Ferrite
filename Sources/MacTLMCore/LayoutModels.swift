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
}
