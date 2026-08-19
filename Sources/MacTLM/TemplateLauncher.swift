import AppKit
import MacTLMCore

/// Applies a MonitorLayout: hides non-members (clear-stage), places running
/// apps, launches missing ones and places them after settle, then restores
/// stacking order back-to-front.
final class TemplateLauncher {
    private let driver: MacWindowDriver
    private unowned let coordinator: PersistenceCoordinator
    private var launchDeadline: DispatchWorkItem?

    init(driver: MacWindowDriver, coordinator: PersistenceCoordinator) {
        self.driver = driver
        self.coordinator = coordinator
    }

    func apply(_ layout: MonitorLayout, excludedBundleIDs: Set<String>) {
        guard let target = resolveTarget(for: layout) else { return }
        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
        let plan = TemplateApplyPlanner.plan(layout: layout,
                                             runningBundleIDs: running,
                                             excludedBundleIDs: excludedBundleIDs,
                                             target: target)
        guard target.visibleArea.width > 0, target.visibleArea.height > 0 else { return }

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
            place(bundleID: bundleID, plan: plan)
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
                self?.awaitedDidSettle(bundleID: bundleID, plan: plan)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        self.awaitedLaunches = awaited
        self.activePlan = plan

        if !awaited.isEmpty {
            // Anything not arrived in 15s: place what came, report the rest.
            let deadline = DispatchWorkItem { [weak self] in self?.reportMissing() }
            launchDeadline?.cancel()
            launchDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: deadline)
        } else {
            restoreStacking(plan: plan)
        }
    }

    // MARK: - Private

    private var awaitedLaunches = Set<String>()
    private var activePlan: TemplateApplyPlanner.ApplyPlan?

    private func resolveTarget(for layout: MonitorLayout) -> TemplateApplyPlanner.Target? {
        let displays = ScreenGeometry.allDisplays
        if let own = displays.first(where: { $0.info.id == layout.displayID }) {
            return TemplateApplyPlanner.Target(info: own.info, visibleArea: own.visibleArea)
        }
        // Display missing: adapt onto the main display (PRD §3.2 Tier-1).
        guard let main = displays.first else { return nil }
        return TemplateApplyPlanner.Target(info: main.info, visibleArea: main.visibleArea)
    }

    private func place(bundleID: String, plan: TemplateApplyPlanner.ApplyPlan) {
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        let records = plan.matchingRecords(forBundleID: bundleID)
        let placementsForBundle = plan.placements.filter { $0.bundleID == bundleID }
        let assignment = WindowMatcher.assign(records: records, to: candidates)
        for window in windows {
            guard let record = assignment[window.id],
                  record.slot < placementsForBundle.count else { continue }
            let targetRect = placementsForBundle[record.slot].targetRect
            let achieved = driver.setFrame(targetRect, of: window)
            if !achieved.approximatelyEquals(targetRect, tolerance: RestoreEngine.tolerance) {
                _ = driver.setFrame(targetRect, of: window)
            }
        }
    }

    private func awaitedDidSettle(bundleID: String, plan: TemplateApplyPlanner.ApplyPlan) {
        awaitedLaunches.remove(bundleID)
        place(bundleID: bundleID, plan: plan)
        if awaitedLaunches.isEmpty {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(plan: plan)
        }
    }

    private func reportMissing() {
        let missing = awaitedLaunches.sorted()
        awaitedLaunches = []
        if let plan = activePlan {
            restoreStacking(plan: plan)
        }
        guard !missing.isEmpty else { return }
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
    }

    /// Raise members backmost-first so the frontmost ends up on top.
    private func restoreStacking(plan: TemplateApplyPlanner.ApplyPlan) {
        let byBundle = Dictionary(grouping: plan.placements, by: \.bundleID)
        var raiseList: [(zIndex: Int, bundleID: String, slot: Int)] = []
        for (bundleID, placements) in byBundle {
            for (slot, placement) in placements.enumerated() {
                raiseList.append((placement.zIndex, bundleID, slot))
            }
        }
        for item in raiseList.sorted(by: { $0.zIndex > $1.zIndex }) {
            let windows = driver.windows(ofBundleID: item.bundleID)
            let candidates = windows.enumerated().map { index, window in
                WindowCandidate(id: window.id, title: window.title, order: index)
            }
            guard let plan = activePlan else { break }
            let records = plan.matchingRecords(forBundleID: item.bundleID)
            let assignment = WindowMatcher.assign(records: records, to: candidates)
            guard let (windowID, _) = assignment.first(where: { $0.value.slot == item.slot }),
                  let handle = driver.handle(forWindowID: windowID) else { continue }
            AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        }
        activePlan = nil
    }
}
