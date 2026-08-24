import AppKit
import MacTLMCore

/// The AppKit half of magnet groups: mating windows on drop, and following a
/// shared edge when one of a group's windows is resized.
///
/// macOS has no drag-ended AX notification, so a drag is bracketed by the first
/// moved event and a real `.leftMouseUp` from a global event monitor. Debouncing
/// moved events instead would fire mid-drag and snap the window out from under
/// the cursor.
final class MagnetDragSession {
    /// Gap left between mated windows — the same one reflow uses.
    static let gap: CGFloat = 8

    /// How long a frame we wrote keeps suppressing events for its window. Long
    /// enough to cover the AX echo of a write that lands in two parts, short
    /// enough that the user's next gesture is not swallowed.
    private static let suppressionWindow: TimeInterval = 0.4

    private let driver: MacWindowDriver
    private let monitor: WorkspaceMonitor
    private unowned let coordinator: PersistenceCoordinator
    private let overlay = MagnetSnapOverlay()

    init(driver: MacWindowDriver, monitor: WorkspaceMonitor,
         coordinator: PersistenceCoordinator) {
        self.driver = driver
        self.monitor = monitor
        self.coordinator = coordinator
    }

    deinit {
        endDrag()
    }

    /// Entry point for every rich window event. Runs on the main thread: AX
    /// observers and global event monitors both deliver on the main run loop.
    func handle(_ event: AppObserver.WindowEvent) {
        guard !isSelfInflicted(event) else { return }
        switch event.kind {
        case .moved: handleMoved(event)
        case .resized: handleResized(event)
        case .created, .titleChanged: break
        }
    }

    // MARK: - Drag sessions

    private struct Neighbour {
        let windowID: Int
        let bundleID: String
        let frame: CGRect
    }

    private struct Drag {
        let windowID: Int
        let bundleID: String
        /// The other eligible windows, captured when the drag opened. Only the
        /// dragged window moves during a drag, so re-enumerating AX for every
        /// moved event would cost a full sweep of every app at cursor rate.
        let neighbours: [Neighbour]
        let mouseUpMonitor: Any?
        var candidate: MagnetMating.Candidate?
    }

    private var drag: Drag?

    private func handleMoved(_ event: AppObserver.WindowEvent) {
        if let open = drag, open.windowID != event.windowID {
            // Nobody drags two windows at once, and no mouse-up arrived for the
            // old one: dropping it is honest, snapping it would not be.
            endDrag()
        }
        if drag == nil {
            // Only a held left button is a drag. Without this a programmatic
            // move opens a session that waits for the user's next click
            // anywhere and then snaps a window they never touched.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            openDrag(for: event)
        }
        updateCandidate(for: event)
    }

    private func openDrag(for event: AppObserver.WindowEvent) {
        let eligible = eligibleWindows()
        // Eligibility of the dragged window falls out of the sweep: the driver
        // only enumerates standard, non-minimized windows of unhidden regular
        // apps, and the sweep drops MacTLM and every excluded bundle.
        guard eligible.contains(where: { $0.windowID == event.windowID }) else { return }
        let mouseUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) {
            [weak self] _ in self?.finishDrag()
        }
        drag = Drag(windowID: event.windowID,
                    bundleID: event.bundleID,
                    neighbours: eligible.filter { $0.windowID != event.windowID },
                    mouseUpMonitor: mouseUp,
                    candidate: nil)
    }

    /// Recomputes the mate for the frame the dragged window is at right now and
    /// drives the preview with the answer.
    private func updateCandidate(for event: AppObserver.WindowEvent) {
        guard var open = drag else { return }
        let others = neighbours(of: open, sharingDisplayWith: event.frame)
        let candidate = MagnetMating.candidate(dragged: event.frame,
                                               others: others,
                                               gap: Self.gap)
        open.candidate = candidate
        drag = open
        if let candidate {
            overlay.show(edge: candidate.edge, of: candidate.snapped)
        } else {
            overlay.hide()
        }
    }

    /// Windows on the display the dragged frame's centre is over. A drag that
    /// crosses displays therefore mates against the display it ends on.
    private func neighbours(of open: Drag,
                            sharingDisplayWith frame: CGRect) -> [(id: Int, frame: CGRect)] {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let display = ScreenGeometry.allDisplays.first { $0.visibleArea.contains(centre) }
        return open.neighbours.filter { neighbour in
            guard let display else { return true }
            return display.visibleArea.contains(CGPoint(x: neighbour.frame.midX,
                                                        y: neighbour.frame.midY))
        }.map { (id: $0.windowID, frame: $0.frame) }
    }

    /// Mouse-up: the drag is over. Snap if there is a mate, and remember the
    /// pair.
    private func finishDrag() {
        guard let open = drag else { return }
        endDrag()
        guard let candidate = open.candidate,
              let window = liveWindow(id: open.windowID, bundleID: open.bundleID)
        else { return }
        write(candidate.snapped, to: window, bundleID: open.bundleID)
        remember(open, matedTo: candidate)
    }

    /// Removes the mouse-up monitor and the preview. Safe to call twice: a
    /// stuck overlay is worse than no overlay.
    private func endDrag() {
        if let mouseUp = drag?.mouseUpMonitor { NSEvent.removeMonitor(mouseUp) }
        drag = nil
        overlay.hide()
    }

    /// Persists the pair as a group. When either window's identity is not
    /// certain the snap still stands and only the memory is skipped: a gesture
    /// that works without being remembered is honest, a wrongly remembered
    /// group is not.
    private func remember(_ open: Drag, matedTo candidate: MagnetMating.Candidate) {
        guard let mate = open.neighbours.first(where: { $0.windowID == candidate.mateID })
        else { return }
        guard let draggedSlot = coordinator.slot(forWindowID: open.windowID,
                                                 bundleID: open.bundleID) else {
            return logUnresolved(bundleID: open.bundleID, windowID: open.windowID)
        }
        guard let mateSlot = coordinator.slot(forWindowID: mate.windowID,
                                              bundleID: mate.bundleID) else {
            return logUnresolved(bundleID: mate.bundleID, windowID: mate.windowID)
        }
        coordinator.mate(MagnetMember(bundleID: open.bundleID, slot: draggedSlot),
                         with: MagnetMember(bundleID: mate.bundleID, slot: mateSlot))
    }

    private func logUnresolved(bundleID: String, windowID: Int) {
        NSLog("MacTLM: snapped windows but did not remember the group — no record "
              + "certainly identifies %@ window %d", bundleID, windowID)
    }

    // MARK: - Resize propagation

    private func handleResized(_ event: AppObserver.WindowEvent) {
        // The gesture is a resize, not a move: a drag opened by the moved
        // events a resize also emits must not snap the window on release.
        if drag?.windowID == event.windowID { endDrag() }

        // Cheapest question first: with no groups remembered there is nothing
        // to propagate to, and resolving identity would cost an AX sweep of
        // the app for every event of a resize the user is still dragging.
        let groups = coordinator.magnetGroups()
        guard !groups.isEmpty,
              let previous = monitor.lastKnownFrame(ofWindow: event.windowID),
              let slot = coordinator.slot(forWindowID: event.windowID,
                                          bundleID: event.bundleID),
              let group = groups.first(where: {
                  $0.contains(bundleID: event.bundleID, slot: slot)
              })
        else { return }

        let live = coordinator.liveMembers(of: group)
        var frames = Dictionary(live.map { ($0.window.id, $0.window.frame) },
                                uniquingKeysWith: { first, _ in first })
        // The driver's enumeration can trail the notification by a frame.
        frames[event.windowID] = event.frame
        guard frames.count > 1 else { return }

        let moves = MagnetResize.propagate(frames: frames,
                                           changed: event.windowID,
                                           previous: previous,
                                           mode: group.resizeMode,
                                           gap: Self.gap)
        guard !moves.isEmpty else { return }
        // Deepest first, so a write that raises its own window cannot leave the
        // group's stacking inverted. Shrink touches one mate, and ordering one
        // window costs no CG sweep.
        let ordered = PersistenceCoordinator.backToFront(
            live.filter { moves[$0.window.id] != nil })
        for member in ordered {
            guard let frame = moves[member.window.id] else { continue }
            write(frame, to: member.window, bundleID: member.member.bundleID)
        }
    }

    // MARK: - Writing frames

    /// One frame write, with the policy the restore path uses: set, read back,
    /// one retry if the app missed by more than the tolerance, then accept
    /// whatever it insisted on. Every frame written is suppressed first — its
    /// own AX echo would otherwise re-enter mating, walking the window across
    /// the screen, and re-enter propagation, which then never terminates.
    private func write(_ frame: CGRect, to window: DriverWindow, bundleID: String) {
        suppress(frame, ofWindow: window.id)
        var achieved = driver.setFrame(frame, of: window)
        if !achieved.approximatelyEquals(frame, tolerance: RestoreEngine.tolerance) {
            achieved = driver.setFrame(frame, of: window)
        }
        suppress(achieved, ofWindow: window.id)
        monitor.noteWrittenFrame(achieved, ofWindow: window.id,
                                 pid: window.pid, bundleID: bundleID)
    }

    // MARK: - Self-inflicted event suppression

    private struct Suppression {
        let windowID: Int
        let frame: CGRect
        let deadline: Date

        /// AX can land one `setFrame` as a separate position and size write and
        /// notify in between, so an echo may match only half of what we wrote.
        /// Matching either half is deliberate: a missed suppression oscillates,
        /// a false one drops one gesture event inside the deadline.
        func matches(_ other: CGRect) -> Bool {
            let slack = RestoreEngine.tolerance
            let samePosition = abs(frame.minX - other.minX) <= slack
                && abs(frame.minY - other.minY) <= slack
            let sameSize = abs(frame.width - other.width) <= slack
                && abs(frame.height - other.height) <= slack
            return samePosition || sameSize
        }
    }

    private var suppressions: [Suppression] = []

    private func suppress(_ frame: CGRect, ofWindow windowID: Int) {
        suppressions.append(
            Suppression(windowID: windowID, frame: frame,
                        deadline: Date().addingTimeInterval(Self.suppressionWindow)))
    }

    private func isSelfInflicted(_ event: AppObserver.WindowEvent) -> Bool {
        let now = Date()
        suppressions.removeAll { $0.deadline < now }
        return suppressions.contains {
            $0.windowID == event.windowID && $0.matches(event.frame)
        }
    }

    // MARK: - Eligible windows

    /// Every window mating may consider: standard windows of unhidden regular
    /// apps, minus MacTLM itself and minus the exclude list.
    private func eligibleWindows() -> [Neighbour] {
        let excluded = coordinator.currentExcludedBundleIDs
        var result: [Neighbour] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !excluded.contains(bundleID),
                  seen.insert(bundleID).inserted else { continue }
            for window in driver.windows(ofBundleID: bundleID) {
                result.append(Neighbour(windowID: window.id, bundleID: bundleID,
                                        frame: window.frame))
            }
        }
        return result
    }

    /// Re-enumerates the app so the driver holds a live AX handle for the id.
    private func liveWindow(id: Int, bundleID: String) -> DriverWindow? {
        driver.windows(ofBundleID: bundleID).first { $0.id == id }
    }
}
