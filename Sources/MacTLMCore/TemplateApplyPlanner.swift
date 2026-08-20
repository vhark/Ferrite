import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Computes everything needed to apply a MonitorLayout to a target display.
public enum TemplateApplyPlanner {
    public struct Target {
        public let info: DisplayInfo
        public let visibleArea: CGRect
        public init(info: DisplayInfo, visibleArea: CGRect) {
            self.info = info; self.visibleArea = visibleArea
        }
    }

    public struct Placement: Equatable {
        public let bundleID: String
        public let entryIndex: Int      // index into layout.entries
        public let targetRect: CGRect
        public let normalizedFrame: NormalizedFrame
        public let zIndex: Int
        public let title: String
        public let pinPattern: String?
    }

    public struct ApplyPlan {
        public let adapted: Bool
        public let appsToLaunch: [String]       // deduped, entry order
        public let placements: [Placement]      // excluded apps carry none
        public let stageMode: StageMode
        public let memberBundleIDs: Set<String> // for clear-stage hiding

        /// Pseudo-records for WindowMatcher when adopting a running app's windows.
        public func matchingRecords(forBundleID bundleID: String) -> [WindowRecord] {
            placements.filter { $0.bundleID == bundleID }
                .enumerated()
                .map { slot, placement in
                    WindowRecord(slot: slot, title: placement.title,
                                 frame: placement.normalizedFrame,
                                 pinPattern: placement.pinPattern,
                                 lastSeen: Date(timeIntervalSince1970: 0))
                }
        }
    }

    public static func plan(layout: MonitorLayout,
                            runningBundleIDs: Set<String>,
                            excludedBundleIDs: Set<String>,
                            target: Target) -> ApplyPlan {
        let adapted = layout.displayID != target.info.id
            || layout.displayMetrics.width != target.info.width
            || layout.displayMetrics.height != target.info.height
        let targetSmaller = target.info.width * target.info.height
            < layout.displayMetrics.width * layout.displayMetrics.height
        let skipOptionals = adapted && targetSmaller

        let activeEntries = layout.entries.enumerated().filter { _, entry in
            !(skipOptionals && entry.optional)
        }

        var seenLaunch = Set<String>()
        var appsToLaunch: [String] = []
        var placements: [Placement] = []
        var members = Set<String>()

        for (index, entry) in activeEntries {
            members.insert(entry.bundleID)
            if !runningBundleIDs.contains(entry.bundleID),
               seenLaunch.insert(entry.bundleID).inserted {
                appsToLaunch.append(entry.bundleID)
            }
            guard !excludedBundleIDs.contains(entry.bundleID) else { continue }
            placements.append(Placement(bundleID: entry.bundleID,
                                        entryIndex: index,
                                        targetRect: entry.frame.rect(in: target.visibleArea),
                                        normalizedFrame: entry.frame,
                                        zIndex: entry.zIndex,
                                        title: entry.title,
                                        pinPattern: entry.pinPattern))
        }
        return ApplyPlan(adapted: adapted, appsToLaunch: appsToLaunch,
                         placements: placements, stageMode: layout.stageMode,
                         memberBundleIDs: members)
    }
}
