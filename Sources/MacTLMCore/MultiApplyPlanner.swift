import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Plans one apply operation spanning several displays (a bundle launch).
/// Single-layout launches are the n = 1 case, so the launcher has one path.
public enum MultiApplyPlanner {
    public struct Item {
        public let plan: TemplateApplyPlanner.ApplyPlan
        public let visibleArea: CGRect
    }

    public struct MultiPlan {
        /// One entry per requested layout, in request order.
        public let items: [Item]
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

        for request in requests {
            let plan = TemplateApplyPlanner.plan(layout: request.layout,
                                                 runningBundleIDs: runningBundleIDs,
                                                 excludedBundleIDs: excludedBundleIDs,
                                                 target: request.target)
            items.append(Item(plan: plan, visibleArea: request.target.visibleArea))
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
                         appsToLaunch: stackingOrder.filter {
                             !runningBundleIDs.contains($0) && members.contains($0)
                         },
                         appStackingOrder: stackingOrder,
                         memberBundleIDs: members,
                         stageMode: anyClearStage ? .clearStage : .leaveOthers)
    }
}
