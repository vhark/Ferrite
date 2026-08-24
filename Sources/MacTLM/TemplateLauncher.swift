import AppKit
import MacTLMCore

/// Applies one or more MonitorLayouts as a single operation: hides non-members
/// (clear-stage), places running apps, launches missing ones and places them
/// after settle, then restores stacking order back-to-front across displays.
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

    /// Passing a single layout is the ordinary single-display launch; passing a
    /// bundle's layouts restores a whole multi-display workspace at once.
    func apply(_ layouts: [MonitorLayout], excludedBundleIDs: Set<String>) {
        guard !layouts.isEmpty else { return }
        if inFlight != nil {
            // A second apply supersedes the first; the old launches are dropped.
            launchDeadline?.cancel()
            launchDeadline = nil
            inFlight = nil
            NSLog("MacTLM: superseding an in-flight template launch")
        }
        var requests: [(layout: MonitorLayout, target: TemplateApplyPlanner.Target)] = []
        for layout in layouts {
            guard let target = resolveTarget(for: layout),
                  target.visibleArea.width > 0, target.visibleArea.height > 0
            else { continue }
            requests.append((layout, target))
        }
        guard !requests.isEmpty else { return }

        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
        let multi = MultiApplyPlanner.plan(requests: requests,
                                          runningBundleIDs: running,
                                          excludedBundleIDs: excludedBundleIDs)
        // A fresh apply owns raising: stale assignments from the previous
        // launch must never leak into this cascade.
        assignments = [:]

        if multi.stageMode == .clearStage {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !multi.memberBundleIDs.contains(bundleID) else { continue }
                app.hide()
            }
        }

        // Place already-running members now, on whichever display owns them.
        for bundleID in multi.memberBundleIDs.intersection(running) {
            place(bundleID: bundleID, multi: multi)
        }

        // Launch missing members backmost-first; place each after its settle.
        var awaited = Set<String>()
        for bundleID in multi.appsToLaunch {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("MacTLM: no app found for %@", bundleID)
                continue
            }
            awaited.insert(bundleID)
            coordinator.armSettle(bundleID: bundleID) { [weak self] in
                self?.awaitedDidSettle(bundleID: bundleID, multi: multi)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        inFlight = InFlight(multi: multi, awaiting: awaited)

        if !awaited.isEmpty {
            // Anything not arrived in 15s: place what came, report the rest.
            let deadline = DispatchWorkItem { [weak self] in self?.reportMissing() }
            launchDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: deadline)
        } else {
            restoreStacking(multi: multi)
        }
    }

    // MARK: - Private

    /// The one apply currently waiting on launches: its merged plan, the apps
    /// still to arrive, and whether the launch deadline already reported them
    /// missing (we keep waiting so stragglers still get restacked).
    private struct InFlight {
        let multi: MultiApplyPlanner.MultiPlan
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

    /// One app's assignment from the launch's single merged match, kept so
    /// raising consumes exactly what placement computed (windowID → slot).
    private var assignments: [String: [Int: Int]] = [:]

    /// Places one app's windows ONCE across every display in the plan: live
    /// windows bucketed by their current display, one global assign with
    /// affinity, absolute-rect placement. Never per display — that was the
    /// M2b residual (cross-display claims).
    private func place(bundleID: String, multi: MultiApplyPlanner.MultiPlan) {
        guard let merged = multi.placements[bundleID], !merged.isEmpty
        else { return } // excluded app: joins the cascade launch-only (PRD §9)
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let affinity = WindowMatcher.Affinity(
            recordDisplays: merged.recordDisplays,
            windowDisplays: WindowMatcher.Affinity.windowDisplays(
                of: windows,
                displays: multi.items.map { ($0.displayID, $0.visibleArea) }))
        // The count gate is GLOBAL: the app must show at least as many windows
        // as the whole bundle remembers before order fallback is trusted.
        let assignment = WindowMatcher.assign(
            records: merged.matchingRecords, to: candidates,
            allowOrderFallback: windows.count >= merged.count,
            affinity: affinity)
        assignments[bundleID] = assignment.mapValues(\.slot)
        let targetBySlot = Dictionary(uniqueKeysWithValues:
            merged.map { ($0.slot, $0.targetRect) })
        engine.place(assignments: windows.compactMap { window in
            guard let slot = assignment[window.id]?.slot,
                  let target = targetBySlot[slot] else { return nil }
            return (window: window, target: target)
        })
    }

    private func awaitedDidSettle(bundleID: String,
                                  multi: MultiApplyPlanner.MultiPlan) {
        guard inFlight?.awaiting.contains(bundleID) == true else { return } // superseded
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return } // never launched — the deadline will report it
        inFlight?.awaiting.remove(bundleID)
        place(bundleID: bundleID, multi: multi)
        if inFlight?.reportedMissing == true {
            // A late arrival: re-run the cascade so it lands in its z position
            // instead of staying frontmost on top of the template.
            restoreStacking(multi: multi)
        } else if inFlight?.awaiting.isEmpty == true {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(multi: multi)
        }
    }

    private func reportMissing() {
        guard let flight = inFlight else { return }
        let missing = flight.awaiting.sorted()
        launchDeadline = nil
        guard !missing.isEmpty else {
            // Raced the deadline: everything arrived, finish normally.
            restoreStacking(multi: flight.multi)
            return
        }
        // Keep the flight alive: a slow launcher whose window shows up after
        // the deadline still needs placing and restacking.
        inFlight?.reportedMissing = true
        restoreStacking(multi: flight.multi)
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
        // Hard stop: stop waiting for stragglers two minutes after the report.
        let stop = DispatchWorkItem { [weak self] in self?.inFlight = nil }
        launchDeadline = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 120.0, execute: stop)
    }

    /// Restores stacking across apps and displays: activate member apps
    /// backmost-first (spaced so each activation lands), raising each app's own
    /// windows back-to-front as we go. The app owning the backmost window is
    /// activated first, so the frontmost one ends up on top.
    /// Excluded apps take part too — activation only, no frames touched.
    private func restoreStacking(multi: MultiApplyPlanner.MultiPlan) {
        // Done waiting, unless we're holding the flight open for late arrivals.
        if inFlight?.awaiting.isEmpty == true, inFlight?.reportedMissing == false {
            inFlight = nil
        }
        for (step, bundleID) in multi.appStackingOrder.enumerated() {
            let delay = Double(step) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activateAndRaise(bundleID: bundleID, multi: multi)
            }
        }
    }

    /// Brings one member app forward, then raises its windows backmost-first
    /// across all displays, consuming the SAME assignment placement computed —
    /// never a second assign.
    private func activateAndRaise(bundleID: String,
                                  multi: MultiApplyPlanner.MultiPlan) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where !app.isHidden {
            app.activate(options: [])
        }
        // Excluded app (no placements) or one that never placed (still
        // launching): it joins the cascade by activation alone, so we never
        // enumerate or raise its windows (PRD §9).
        guard let merged = multi.placements[bundleID],
              let assignment = assignments[bundleID] else { return }
        let placementBySlot = Dictionary(uniqueKeysWithValues:
            merged.map { ($0.slot, $0) })
        // Backmost-first; equal depths keep item (display) order via the slot,
        // matching the old per-display iteration.
        var backToFront: [(windowID: Int, slot: Int, zIndex: Int)] = []
        for (windowID, slot) in assignment {
            backToFront.append((windowID: windowID, slot: slot,
                                zIndex: placementBySlot[slot]?.zIndex ?? Int.max))
        }
        backToFront.sort { lhs, rhs in
            lhs.zIndex == rhs.zIndex ? lhs.slot < rhs.slot : lhs.zIndex > rhs.zIndex
        }
        for entry in backToFront {
            guard let handle = driver.handle(forWindowID: entry.windowID) else { continue }
            AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        }
    }
}
