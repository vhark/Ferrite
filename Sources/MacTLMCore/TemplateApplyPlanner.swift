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
        public let appsToLaunch: [String]       // deduped, backmost-first
        public let placements: [Placement]      // excluded apps carry none
        public let stageMode: StageMode
        public let memberBundleIDs: Set<String> // for clear-stage hiding
        /// Every active member, ordered backmost-first by its frontmost window's
        /// zIndex. Excluded apps appear here (they join the stacking cascade)
        /// even though they carry no placement.
        public let appStackingOrder: [String]

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

        // One rank per bundle: the frontmost (lowest) zIndex it owns, kept in
        // first-appearance order so equal zIndexes sort deterministically.
        var appRanks: [(bundleID: String, frontmostZ: Int)] = []
        var rankIndex: [String: Int] = [:]
        var placements: [Placement] = []

        for (index, entry) in activeEntries {
            if let rank = rankIndex[entry.bundleID] {
                appRanks[rank].frontmostZ = min(appRanks[rank].frontmostZ, entry.zIndex)
            } else {
                rankIndex[entry.bundleID] = appRanks.count
                appRanks.append((entry.bundleID, entry.zIndex))
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

        let appStackingOrder = appRanks.enumerated().sorted {
            $0.element.frontmostZ == $1.element.frontmostZ
                ? $0.offset < $1.offset
                : $0.element.frontmostZ > $1.element.frontmostZ
        }.map(\.element.bundleID)
        // Launch backmost-first too: the backmost apps get a head start, so in
        // the common case they are already behind and need less restacking.
        let appsToLaunch = appStackingOrder.filter { !runningBundleIDs.contains($0) }

        return ApplyPlan(adapted: adapted, appsToLaunch: appsToLaunch,
                         placements: placements, stageMode: layout.stageMode,
                         memberBundleIDs: Set(rankIndex.keys),
                         appStackingOrder: appStackingOrder)
    }
}
