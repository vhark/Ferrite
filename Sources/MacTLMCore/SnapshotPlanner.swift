import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns a captured set of windows into per-display MonitorLayouts (PRD §3.2).
public enum SnapshotPlanner {
    public struct Window {
        public let bundleID: String
        /// Live title, in-memory only: pin matching during capture, never stored.
        public let title: String
        public let titleHash: String?
        public let frame: CGRect   // CG space
        public let zIndex: Int     // global, 0 = frontmost
        public init(bundleID: String, title: String, titleHash: String?,
                    frame: CGRect, zIndex: Int) {
            self.bundleID = bundleID; self.title = title
            self.titleHash = titleHash
            self.frame = frame; self.zIndex = zIndex
        }
    }

    public struct Display {
        public let info: DisplayInfo
        public let name: String
        public let visibleArea: CGRect  // CG space
        public init(info: DisplayInfo, name: String, visibleArea: CGRect) {
            self.info = info; self.name = name; self.visibleArea = visibleArea
        }
    }

    public static func plan(name: String, stageMode: StageMode,
                            windows: [Window], displays: [Display],
                            date: Date) -> [MonitorLayout] {
        guard !displays.isEmpty else { return [] }
        var byDisplay: [String: [Window]] = [:]
        for window in windows {
            let display = assign(window: window, displays: displays)
            byDisplay[display.info.id, default: []].append(window)
        }
        return displays.compactMap { display in
            guard let assigned = byDisplay[display.info.id], !assigned.isEmpty
            else { return nil }
            let ordered = assigned.sorted { $0.zIndex < $1.zIndex }
            let entries = ordered.enumerated().map { index, window in
                LayoutEntry(bundleID: window.bundleID,
                            titleHash: window.titleHash,
                            frame: NormalizedFrame(windowFrame: window.frame,
                                                   visibleArea: display.visibleArea),
                            zIndex: index,
                            pinPattern: nil,
                            optional: false)
            }
            return MonitorLayout(id: UUID(), name: name,
                                 displayID: display.info.id,
                                 displayName: display.name,
                                 displayMetrics: display.info,
                                 stageMode: stageMode,
                                 entries: entries,
                                 createdAt: date)
        }
    }

    /// The area owning a rect: center containment first, else nearest center.
    /// The one display-bucketing rule — capture (`assign`) and placement
    /// affinity (`WindowMatcher.Affinity`) both delegate here; never fork it.
    public static func ownerIndex(of frame: CGRect, areas: [CGRect]) -> Int? {
        guard !areas.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = areas.firstIndex(where: { $0.contains(center) }) {
            return containing
        }
        // Off-screen fallback: nearest display center.
        return areas.indices.min { a, b in
            distanceSquared(center, to: areas[a]) < distanceSquared(center, to: areas[b])
        }
    }

    private static func assign(window: Window, displays: [Display]) -> Display {
        displays[ownerIndex(of: window.frame, areas: displays.map(\.visibleArea))!]
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}
