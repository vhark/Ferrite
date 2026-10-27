import AppKit
import FerriteCore

/// Main-thread orchestration around the pure placement planner. Membership is
/// committed only after every AX write has been read back successfully.
final class AutomaticAppClustering {
    private unowned let coordinator: PersistenceCoordinator
    private let driver: MacWindowDriver
    private let magnets: MagnetDragSession
    private var pending: [String: (ids: Set<Int>, debounce: Debouncer)] = [:]
    private var detached: [String: Set<Int>] = [:]
    private var known: [String: Set<Int>] = [:]
    private var ready = false
    private var enabled = false
    private var deferredGatherAll = false
    private var deferredBundles = Set<String>()
    private var deferredPending = Set<String>()
    private var mouseUpMonitor: Any?

    init(coordinator: PersistenceCoordinator, driver: MacWindowDriver,
         magnets: MagnetDragSession) {
        self.coordinator = coordinator
        self.driver = driver
        self.magnets = magnets
    }

    deinit {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        cancelPending()
        deferredGatherAll = false
        deferredBundles.removeAll()
        deferredPending.removeAll()
        if value {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) {
                [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.mouseReleased() }
            }
            detached.removeAll()
            gatherAll()
        } else if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    func startupRestored() {
        ready = true
        gatherAll()
    }

    func resumed() {
        gatherAll()
    }

    func configurationRestored() {
        cancelPending()
        known.removeAll()
        gatherAll()
    }

    func appSettled(_ bundleID: String) {
        guard enabled, ready, !coordinator.isPaused else { return }
        if dragging {
            deferredBundles.insert(bundleID)
            return
        }
        coordinator.captureForAutomaticClustering(bundleID)
        gather(bundleID)
    }

    func appTerminated(_ bundleID: String) {
        pending.removeValue(forKey: bundleID)?.debounce.cancel()
        deferredBundles.remove(bundleID)
        deferredPending.remove(bundleID)
        detached.removeValue(forKey: bundleID)
        known.removeValue(forKey: bundleID)
    }

    func exclude(_ bundleID: String) {
        pending.removeValue(forKey: bundleID)?.debounce.cancel()
        deferredBundles.remove(bundleID)
        deferredPending.remove(bundleID)
        known.removeValue(forKey: bundleID)
    }

    func manuallyDetached(windowID: Int, bundleID: String) {
        detached[bundleID, default: []].insert(windowID)
        pending[bundleID]?.ids.remove(windowID)
    }

    func observed(windowID: Int, bundleID: String) {
        guard enabled, ready, !coordinator.isPaused,
              !coordinator.isSettling(bundleID: bundleID),
              !coordinator.isExcludedFromAutomaticClustering(bundleID),
              known[bundleID]?.contains(windowID) != true,
              detached[bundleID]?.contains(windowID) != true else { return }
        enqueue(windowID, bundleID: bundleID)
    }

    private func enqueue(_ id: Int, bundleID: String) {
        if pending[bundleID] == nil {
            pending[bundleID] = ([], Debouncer(delay: 0.3, maxDelay: 1.5))
        }
        pending[bundleID]?.ids.insert(id)
        pending[bundleID]?.debounce.call { [weak self] in
            self?.processPending(bundleID)
        }
    }

    private var dragging: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func mouseReleased() {
        guard !dragging, enabled else { return }
        if deferredGatherAll {
            deferredGatherAll = false
            gatherAll()
        }
        let bundles = deferredBundles
        deferredBundles.removeAll()
        for bundleID in bundles.sorted() { appSettled(bundleID) }
        let awaiting = deferredPending
        deferredPending.removeAll()
        for bundleID in awaiting.sorted() {
            pending[bundleID]?.debounce.cancel()
            processPending(bundleID)
        }
    }

    private func processPending(_ bundleID: String) {
        guard enabled, ready, !coordinator.isPaused,
              !coordinator.isSettling(bundleID: bundleID),
              !coordinator.isExcludedFromAutomaticClustering(bundleID) else { return }
        if dragging {
            deferredPending.insert(bundleID)
            return
        }
        // The creation notification may precede AX enumeration. Make one
        // capture after its debounce, using the tracker's actual assignment.
        coordinator.captureForAutomaticClustering(bundleID)
        let candidates = pending.removeValue(forKey: bundleID)?.ids ?? []
        let windows = driver.windows(ofBundleID: bundleID)
        let live = Set(windows.map(\.id))
        for id in candidates.sorted() where live.contains(id)
            && known[bundleID]?.contains(id) != true
            && detached[bundleID]?.contains(id) != true {
            guard coordinator.capturedSlot(forWindowID: id, bundleID: bundleID) != nil else { continue }
            known[bundleID, default: []].insert(id)
            append(id, bundleID: bundleID)
        }
    }

    private func cancelPending() {
        for item in pending.values { item.debounce.cancel() }
        pending.removeAll()
    }

    private func gatherAll() {
        guard enabled, ready, !coordinator.isPaused else { return }
        if dragging {
            deferredGatherAll = true
            return
        }
        let bundles = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy == .regular ? app.bundleIdentifier : nil
        })
        for bundleID in bundles.sorted() where !coordinator.isSettling(bundleID: bundleID) {
            coordinator.captureForAutomaticClustering(bundleID)
            gather(bundleID)
        }
    }

    private func gather(_ bundleID: String) {
        guard enabled, ready, !coordinator.isPaused,
              !coordinator.isExcludedFromAutomaticClustering(bundleID) else { return }
        if dragging {
            deferredBundles.insert(bundleID)
            return
        }
        let windows = driver.windows(ofBundleID: bundleID)
        let live = Set(windows.map(\.id))
        let displays = ScreenGeometry.allDisplays
        for display in displays {
            let onDisplay = windows.filter { display.visibleArea.contains(
                CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            guard onDisplay.count > 1 else { continue }
            // Driver enumeration is front-to-back.
            guard let anchor = onDisplay.first(where: {
                detached[bundleID]?.contains($0.id) != true
                    && member(for: $0, bundleID: bundleID) != nil
                    && plannedWindow($0) != nil
            }) else { continue }
            known[bundleID, default: []].insert(anchor.id)
            for window in onDisplay where window.id != anchor.id {
                known[bundleID, default: []].insert(window.id)
                guard detached[bundleID]?.contains(window.id) != true else { continue }
                append(window.id, bundleID: bundleID, anchorID: anchor.id)
            }
        }
        known[bundleID, default: []].formUnion(live)
    }

    private func append(_ id: Int, bundleID: String, anchorID: Int? = nil) {
        let windows = driver.windows(ofBundleID: bundleID)
        guard let newcomer = windows.first(where: { $0.id == id }),
              let newcomerMember = member(for: newcomer, bundleID: bundleID),
              let display = ScreenGeometry.allDisplays.first(where: {
                  $0.visibleArea.contains(CGPoint(x: newcomer.frame.midX,
                                                  y: newcomer.frame.midY))
              }), plannedWindow(newcomer) != nil
        else { return }
        let onDisplay = windows.filter {
            display.visibleArea.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        guard let anchor = onDisplay.first(where: {
            if let anchorID { return $0.id == anchorID }
            return $0.id != id && detached[bundleID]?.contains($0.id) != true
                && member(for: $0, bundleID: bundleID) != nil
                && plannedWindow($0) != nil
        }), anchor.id != id,
              let anchorMember = member(for: anchor, bundleID: bundleID)
        else { return }
        let groups = coordinator.magnetGroups()
        let anchorGroup = groups.first { $0.contains(bundleID: bundleID, slot: anchorMember.slot) }
        let incomingGroup = groups.first { $0.contains(bundleID: bundleID, slot: newcomerMember.slot) }
        let host = anchorGroup.map { coordinator.liveMembers(of: $0).map(\.window).filter { $0.id != id } }
            ?? [anchor]
        let arrivals: [DriverWindow]
        if let incomingGroup, incomingGroup.id != anchorGroup?.id {
            arrivals = coordinator.liveMembers(of: incomingGroup).map(\.window)
        } else {
            arrivals = [newcomer]
        }
        let ordered = host + arrivals
        guard !host.isEmpty, !arrivals.isEmpty,
              ordered.allSatisfy({ window in
                  onDisplay.contains(where: { $0.id == window.id })
                      && detached[bundleID]?.contains(window.id) != true
              }) else { return }
        let planned = ordered.compactMap(plannedWindow)
        guard planned.count == ordered.count else { return }
        var layout = Array(planned.prefix(host.count))
        var plan: [Int: CGRect] = [:]
        for arrival in planned.dropFirst(host.count) {
            guard let next = AutomaticClusterPlanner.append(
                arrival, to: layout, in: display.visibleArea, gap: MagnetDragSession.gap)
            else { return }
            layout = layout.map {
                AutomaticClusterPlanner.Window(id: $0.id, frame: next[$0.id]!,
                                               minimumSize: $0.minimumSize)
            }
            layout.append(AutomaticClusterPlanner.Window(
                id: arrival.id, frame: next[arrival.id]!, minimumSize: arrival.minimumSize))
            plan = next
        }
        guard ordered.allSatisfy({ window in
            guard let handle = driver.handle(forWindowID: window.id),
                  let target = plan[window.id] else { return false }
            return handle.canResize || target.size == window.frame.size
        }) else { return }
        let original = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.frame) })
        for window in ordered {
            let target = plan[window.id]!
            if window.frame.approximatelyEquals(target, tolerance: 0.5) { continue }
            let achieved = write(target, to: window, bundleID: bundleID)
            guard achieved.approximatelyEquals(target, tolerance: 2) else {
                rollback(ordered, original: original, bundleID: bundleID)
                return
            }
        }
        // An AX app can move a *different* window while satisfying our write.
        // Inspect all actual frames before any membership is persisted.
        let actual: [CGRect] = ordered.compactMap { driver.handle(forWindowID: $0.id)?.frame }
        let bounds = display.visibleArea.insetBy(dx: -2, dy: -2)
        guard actual.count == ordered.count,
              zip(ordered, actual).allSatisfy({ window, frame in
                  bounds.contains(frame) && plan[window.id]?.approximatelyEquals(frame, tolerance: 2) == true
              }),
              !actual.indices.contains(where: { i in
                  actual.indices.contains(where: { j in i < j && actual[i].intersects(actual[j]) })
              }) else {
            rollback(ordered, original: original, bundleID: bundleID)
            return
        }
        coordinator.mate(anchorMember, with: newcomerMember)
    }

    private func rollback(_ changed: [DriverWindow], original: [Int: CGRect], bundleID: String) {
        for window in changed.reversed() {
            if let frame = original[window.id] { _ = write(frame, to: window, bundleID: bundleID) }
        }
    }

    @discardableResult
    private func write(_ frame: CGRect, to window: DriverWindow, bundleID: String) -> CGRect {
        magnets.expectOwnWrite(frame, to: window, bundleID: bundleID)
        var achieved = driver.setFrame(frame, of: window)
        if !achieved.approximatelyEquals(frame, tolerance: RestoreEngine.tolerance) {
            achieved = driver.setFrame(frame, of: window)
        }
        magnets.expectOwnWrite(achieved, to: window, bundleID: bundleID)
        return achieved
    }

    private func plannedWindow(_ window: DriverWindow) -> AutomaticClusterPlanner.Window? {
        guard let handle = driver.handle(forWindowID: window.id),
              !handle.isMinimized, !handle.isFullScreen,
              handle.isStandardWindow else { return nil }
        let minimum = handle.canResize
            ? CGSize(width: max(240, handle.minimumSize?.width ?? 0),
                     height: max(160, handle.minimumSize?.height ?? 0))
            : window.frame.size
        return AutomaticClusterPlanner.Window(id: window.id, frame: window.frame,
                                              minimumSize: minimum)
    }

    private func member(for window: DriverWindow, bundleID: String) -> MagnetMember? {
        guard let slot = coordinator.capturedSlot(forWindowID: window.id,
                                                  bundleID: bundleID) else { return nil }
        return MagnetMember(bundleID: bundleID, slot: slot)
    }
}
