import AppKit
import MacTLMCore

/// Applies a MonitorLayout: hides non-members (clear-stage), places running
/// apps, launches missing ones and places them after settle, then restores
/// stacking order back-to-front.
final class TemplateLauncher {
    private let driver: MacWindowDriver
    private unowned let coordinator: PersistenceCoordinator
    private let engine: RestoreEngine
    private var launchDeadline: DispatchWorkItem?

    init(driver: MacWindowDriver, coordinator: PersistenceCoordinator,
         engine: RestoreEngine) {
        self.driver = driver
        self.coordinator = coordinator
        self.engine = engine
    }

    func apply(_ layout: MonitorLayout, excludedBundleIDs: Set<String>) {
        if inFlight != nil {
            // A second apply supersedes the first; the old launches are dropped.
            launchDeadline?.cancel()
            launchDeadline = nil
            inFlight = nil
            NSLog("MacTLM: superseding an in-flight template launch")
        }
        guard let target = resolveTarget(for: layout) else { return }
        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
        let plan = TemplateApplyPlanner.plan(layout: layout,
                                             runningBundleIDs: running,
                                             excludedBundleIDs: excludedBundleIDs,
                                             target: target)
        let visibleArea = target.visibleArea
        guard visibleArea.width > 0, visibleArea.height > 0 else { return }

        if plan.stageMode == .clearStage {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !plan.memberBundleIDs.contains(bundleID) else { continue }
                app.hide()
            }
        }

        // Place already-running members now.
        let runningMembers = Set(plan.placements.map(\.bundleID)).intersection(running)
        for bundleID in runningMembers {
            engine.restore(records: plan.matchingRecords(forBundleID: bundleID),
                           bundleID: bundleID, visibleArea: visibleArea)
        }

        // Launch missing members; place each after its settle.
        var awaited = Set<String>()
        for bundleID in plan.appsToLaunch {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("MacTLM: no app found for %@", bundleID)
                continue
            }
            awaited.insert(bundleID)
            coordinator.armSettle(bundleID: bundleID) { [weak self] in
                self?.awaitedDidSettle(bundleID: bundleID, plan: plan,
                                       visibleArea: visibleArea)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        inFlight = InFlight(plan: plan, visibleArea: visibleArea, awaiting: awaited)

        if !awaited.isEmpty {
            // Anything not arrived in 15s: place what came, report the rest.
            let deadline = DispatchWorkItem { [weak self] in self?.reportMissing() }
            launchDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: deadline)
        } else {
            restoreStacking(plan: plan)
        }
    }

    // MARK: - Private

    /// The one apply currently waiting on launches: its plan, the display area
    /// it was planned against, the apps still to arrive, and whether the
    /// launch deadline already reported them missing (we keep waiting).
    private struct InFlight {
        let plan: TemplateApplyPlanner.ApplyPlan
        let visibleArea: CGRect
        var awaiting: Set<String>
        var reportedMissing: Bool = false
    }

    private var inFlight: InFlight?

    private func resolveTarget(for layout: MonitorLayout) -> TemplateApplyPlanner.Target? {
        let displays = ScreenGeometry.allDisplays
        if let own = displays.first(where: { $0.info.id == layout.displayID }) {
            return TemplateApplyPlanner.Target(info: own.info, visibleArea: own.visibleArea)
        }
        // Display missing: adapt onto the main display (PRD §3.2 Tier-1).
        guard let main = displays.first else { return nil }
        return TemplateApplyPlanner.Target(info: main.info, visibleArea: main.visibleArea)
    }

    private func awaitedDidSettle(bundleID: String, plan: TemplateApplyPlanner.ApplyPlan,
                                  visibleArea: CGRect) {
        guard inFlight?.awaiting.contains(bundleID) == true else { return } // superseded
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return } // never launched — the deadline will report it
        inFlight?.awaiting.remove(bundleID)
        engine.restore(records: plan.matchingRecords(forBundleID: bundleID),
                       bundleID: bundleID, visibleArea: visibleArea)
        if inFlight?.reportedMissing == true {
            // A late arrival: re-run the cascade so it lands in its z position
            // instead of staying frontmost on top of the template.
            restoreStacking(plan: plan)
        } else if inFlight?.awaiting.isEmpty == true {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(plan: plan)
        }
    }

    private func reportMissing() {
        guard let flight = inFlight else { return }
        let missing = flight.awaiting.sorted()
        launchDeadline = nil
        guard !missing.isEmpty else {
            // Raced the deadline: everything arrived, finish normally.
            restoreStacking(plan: flight.plan)
            return
        }
        // Keep the flight alive: a slow launcher whose window shows up after
        // the deadline still needs placing and restacking.
        inFlight?.reportedMissing = true
        restoreStacking(plan: flight.plan)
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
        // Hard stop: stop waiting for stragglers two minutes after the report.
        let stop = DispatchWorkItem { [weak self] in self?.inFlight = nil }
        launchDeadline = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 120.0, execute: stop)
    }

    /// Restores stacking across apps: activate member apps backmost-first
    /// (spaced so each activation lands), raising each app's own windows
    /// back-to-front as we go. The app owning zIndex 0 ends up frontmost.
    /// Excluded apps take part too — activation only, no frames touched.
    private func restoreStacking(plan: TemplateApplyPlanner.ApplyPlan) {
        // Done waiting, unless we're holding the flight open for late arrivals.
        if inFlight?.awaiting.isEmpty == true, inFlight?.reportedMissing == false {
            inFlight = nil
        }
        // Backmost app first, so the last activation leaves z=0's app in front.
        for (step, bundleID) in plan.appStackingOrder.enumerated() {
            let delay = Double(step) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activateAndRaise(bundleID: bundleID, plan: plan)
            }
        }
    }

    /// Brings one member app forward, then raises its own windows
    /// backmost-first so the app's internal order matches the template.
    private func activateAndRaise(bundleID: String,
                                  plan: TemplateApplyPlanner.ApplyPlan) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where !app.isHidden {
            app.activate(options: [])
        }
        let records = plan.matchingRecords(forBundleID: bundleID)
        // Excluded app: it joins the cascade by activation alone, so we never
        // enumerate or raise its windows (PRD §9).
        guard !records.isEmpty else { return }
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        // Same count gate as placement, so raise order matches what was placed.
        let assignment = WindowMatcher.assign(
            records: records, to: candidates,
            allowOrderFallback: windows.count >= records.count)
        // Records carry per-bundle slots, so placements index directly by slot.
        let placements = plan.placements.filter { $0.bundleID == bundleID }
        let backToFront = assignment
            .map { (windowID: $0.key, zIndex: zIndex(ofSlot: $0.value.slot, in: placements)) }
            .sorted { $0.zIndex > $1.zIndex }
        for entry in backToFront {
            guard let handle = driver.handle(forWindowID: entry.windowID) else { continue }
            AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        }
    }

    /// Template zIndex for a per-bundle slot; unknown slots raise first.
    private func zIndex(ofSlot slot: Int,
                        in placements: [TemplateApplyPlanner.Placement]) -> Int {
        slot < placements.count ? placements[slot].zIndex : Int.max
    }
}
