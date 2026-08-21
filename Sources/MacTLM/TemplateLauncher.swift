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

    /// Places one app's windows on every display that has placements for it.
    private func place(bundleID: String, multi: MultiApplyPlanner.MultiPlan) {
        for item in multi.items {
            let records = item.plan.matchingRecords(forBundleID: bundleID)
            guard !records.isEmpty else { continue }
            engine.restore(records: records, bundleID: bundleID,
                           visibleArea: item.visibleArea)
        }
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

    /// Brings one member app forward, then raises its own windows
    /// backmost-first on each display so its internal order matches the layout.
    private func activateAndRaise(bundleID: String,
                                  multi: MultiApplyPlanner.MultiPlan) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where !app.isHidden {
            app.activate(options: [])
        }
        for item in multi.items {
            let records = item.plan.matchingRecords(forBundleID: bundleID)
            // Excluded app: it joins the cascade by activation alone, so we
            // never enumerate or raise its windows (PRD §9).
            guard !records.isEmpty else { continue }
            let windows = driver.windows(ofBundleID: bundleID)
            let candidates = windows.enumerated().map { index, window in
                WindowCandidate(id: window.id, title: window.title,
                                titleHash: window.titleHash, order: index)
            }
            // Same count gate as placement, so raise order matches what was placed.
            let assignment = WindowMatcher.assign(
                records: records, to: candidates,
                allowOrderFallback: windows.count >= records.count)
            let placements = item.plan.placements.filter { $0.bundleID == bundleID }
            let backToFront = assignment
                .map { (windowID: $0.key,
                        zIndex: zIndex(ofSlot: $0.value.slot, in: placements)) }
                .sorted { $0.zIndex > $1.zIndex }
            for entry in backToFront {
                guard let handle = driver.handle(forWindowID: entry.windowID) else { continue }
                AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            }
        }
    }

    /// Template zIndex for a per-bundle slot; unknown slots raise first.
    private func zIndex(ofSlot slot: Int,
                        in placements: [TemplateApplyPlanner.Placement]) -> Int {
        slot < placements.count ? placements[slot].zIndex : Int.max
    }
}
