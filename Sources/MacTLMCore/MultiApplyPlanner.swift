import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Plans one apply operation spanning several displays (a bundle launch).
/// Single-layout launches are the n = 1 case, so the launcher has one path.
public enum MultiApplyPlanner {
    public struct Item {
        public let plan: TemplateApplyPlanner.ApplyPlan
        public let displayID: String
        public let visibleArea: CGRect
    }

    /// One window of one app in the merged, cross-display placement set.
    /// `targetRect` is ABSOLUTE (the per-display denormalization the item's
    /// planner already computed) — placement never re-denormalizes against a
    /// single display's visible area.
    public struct MergedPlacement: Equatable {
        public let slot: Int          // globally unique within the app, item order
        public let targetRect: CGRect
        public let zIndex: Int
        public let titleHash: String?
        public let pinPattern: String?
        public let displayID: String
    }

    public struct MultiPlan {
        /// One entry per requested layout, in request order.
        public let items: [Item]
        /// Per-app merged placements across every display: matched ONCE per
        /// app against its global window list, placed by absolute rect.
        public let placements: [String: [MergedPlacement]]
        /// Merged, deduped, backmost-first across every display.
        public let appsToLaunch: [String]
        /// Merged activation order, backmost-first across every display.
        public let appStackingOrder: [String]
        public let memberBundleIDs: Set<String>
        /// clearStage when ANY member layout asks for it.
        public let stageMode: StageMode
    }

    public static func plan(
        requests: [(layout: MonitorLayout, target: TemplateApplyPlanner.Target)],
        runningBundleIDs: Set<String>,
        excludedBundleIDs: Set<String>
    ) -> MultiPlan {
        var items: [Item] = []
        // An app's backmost window across ALL displays decides its rank, so a
        // shared app is activated once, behind everything it sits behind.
        // Depth is the real zIndex, not a per-display rank: ranks from displays
        // holding different numbers of apps are not comparable to each other.
        var backmostZ: [String: Int] = [:]
        // First appearance across the concatenated per-display orders breaks
        // depth ties, which keeps the n = 1 case identical to ApplyPlan's order.
        var firstSeen: [String: Int] = [:]
        var members = Set<String>()
        var anyClearStage = false
        var placements: [String: [MergedPlacement]] = [:]

        for request in requests {
            let plan = TemplateApplyPlanner.plan(layout: request.layout,
                                                 runningBundleIDs: runningBundleIDs,
                                                 excludedBundleIDs: excludedBundleIDs,
                                                 target: request.target)
            items.append(Item(plan: plan, displayID: request.target.info.id,
                              visibleArea: request.target.visibleArea))
            // Merge this display's placements, re-slotting so slots stay
            // unique per app across the whole bundle (item order). The
            // absolute rect the item's planner computed is threaded through.
            for placement in plan.placements {
                let slot = placements[placement.bundleID]?.count ?? 0
                placements[placement.bundleID, default: []].append(
                    MergedPlacement(slot: slot,
                                    targetRect: placement.targetRect,
                                    zIndex: placement.zIndex,
                                    titleHash: placement.titleHash,
                                    pinPattern: placement.pinPattern,
                                    displayID: request.target.info.id))
            }
            members.formUnion(plan.memberBundleIDs)
            if plan.stageMode == .clearStage { anyClearStage = true }
            for bundleID in plan.appStackingOrder {
                guard let depth = plan.appFrontmostZ[bundleID] else { continue }
                backmostZ[bundleID] = max(backmostZ[bundleID] ?? Int.min, depth)
                if firstSeen[bundleID] == nil { firstSeen[bundleID] = firstSeen.count }
            }
        }

        let stackingOrder = backmostZ.sorted { lhs, rhs in
            lhs.value == rhs.value
                ? firstSeen[lhs.key, default: 0] < firstSeen[rhs.key, default: 0]
                : lhs.value > rhs.value
        }.map(\.key)

        return MultiPlan(items: items,
                         placements: placements,
                         appsToLaunch: stackingOrder.filter {
                             !runningBundleIDs.contains($0) && members.contains($0)
                         },
                         appStackingOrder: stackingOrder,
                         memberBundleIDs: members,
                         stageMode: anyClearStage ? .clearStage : .leaveOthers)
    }
}

public extension [MultiApplyPlanner.MergedPlacement] {
    /// Pseudo-records for one app's single, global `WindowMatcher.assign`.
    /// The normalized frame is inert (zeroed): merged placement matches on
    /// pin/hash/order and places by the absolute `targetRect`, never by
    /// re-denormalizing — these records must not be fed to `restore`.
    var matchingRecords: [WindowRecord] {
        map { placement in
            WindowRecord(slot: placement.slot, titleHash: placement.titleHash,
                         frame: NormalizedFrame(x: 0, y: 0, w: 0, h: 0),
                         pinPattern: placement.pinPattern,
                         lastSeen: Date(timeIntervalSince1970: 0))
        }
    }

    /// Slot → target display, the record half of `WindowMatcher.Affinity`.
    var recordDisplays: [Int: String] {
        Dictionary(uniqueKeysWithValues: map { ($0.slot, $0.displayID) })
    }
}
