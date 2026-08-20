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
    /// it was planned against, and the apps still to arrive.
    private struct InFlight {
        let plan: TemplateApplyPlanner.ApplyPlan
        let visibleArea: CGRect
        var awaiting: Set<String>
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
        if inFlight?.awaiting.isEmpty == true {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(plan: plan)
        }
    }

    private func reportMissing() {
        guard let flight = inFlight else { return }
        let missing = flight.awaiting.sorted()
        inFlight = nil
        launchDeadline = nil
        restoreStacking(plan: flight.plan)
        guard !missing.isEmpty else { return }
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
    }

    /// Restores stacking across apps: activate member apps backmost-first
    /// (spaced so each activation lands), raising each app's own windows
    /// back-to-front as we go. The app owning zIndex 0 ends up frontmost.
    private func restoreStacking(plan: TemplateApplyPlanner.ApplyPlan) {
        defer { inFlight = nil }
        // Frontmost (lowest zIndex) placement per bundle decides app order.
        var frontmostZ: [String: Int] = [:]
        for placement in plan.placements {
            let current = frontmostZ[placement.bundleID] ?? Int.max
            frontmostZ[placement.bundleID] = min(current, placement.zIndex)
        }
        // Backmost app first, so the last activation leaves z=0's app in front.
        let appOrder = frontmostZ.sorted { $0.value > $1.value }.map(\.key)
        for (step, bundleID) in appOrder.enumerated() {
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
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        let records = plan.matchingRecords(forBundleID: bundleID)
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
