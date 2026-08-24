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
        endResize()
    }

    /// Live tracing, enabled with `MACTLM_TRACE_DRAG=1`.
    ///
    /// Not scaffolding: mating correctness depends on AX delivery timing, mouse
    /// button state and real window geometry, none of which a unit test can
    /// reach. Two separate live defects (a reach threshold measured too tight,
    /// and a session ended by an unexpected event) were both diagnosed with
    /// this trace, so it stays available behind an env var it costs nothing to
    /// leave in.
    static let trace = ProcessInfo.processInfo.environment["MACTLM_TRACE_DRAG"] == "1"

    private func trace(_ message: @autoclosure () -> String) {
        guard Self.trace else { return }
        NSLog("MacTLM/drag: \(message())")
    }

    /// Entry point for every rich window event. Runs on the main thread: AX
    /// observers and global event monitors both deliver on the main run loop.
    func handle(_ event: AppObserver.WindowEvent) {
        if isSelfInflicted(event) {
            trace("ignored self-inflicted \(event.kind) win=\(event.windowID)")
            return
        }
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
        let buttons = NSEvent.pressedMouseButtons
        trace("moved \(event.bundleID) win=\(event.windowID) " +
              "frame=\(event.frame) buttons=\(buttons) session=\(drag != nil)")
        if let open = drag, open.windowID != event.windowID {
            // Nobody drags two windows at once, and no mouse-up arrived for the
            // old one: dropping it is honest, snapping it would not be.
            trace("ending session for win=\(open.windowID): a different window moved")
            endDrag()
        }
        if drag == nil {
            // Only a held left button is a drag. Without this a programmatic
            // move opens a session that waits for the user's next click
            // anywhere and then snaps a window they never touched.
            //
            // Verified live 2026-08-24: AX delivers moved notifications while
            // the button is still down, so reading it here does not race the
            // drag. Every sampled event during a real drag reported buttons=1.
            guard buttons & 1 != 0 else {
                trace("no session: left button not held")
                return
            }
            openDrag(for: event)
            trace("openDrag -> session=\(drag != nil) neighbours=\(drag?.neighbours.count ?? -1)")
        }
        updateCandidate(for: event)
        if let candidate = drag?.candidate {
            trace("candidate mate=\(candidate.mateID) \(candidate.edge) " +
                  "dist=\(Int(candidate.distance))")
        } else if let open = drag {
            let nearest = MagnetMating.evaluate(
                dragged: event.frame,
                others: open.neighbours.map { (id: $0.windowID, frame: $0.frame) })
            for evaluation in nearest.prefix(3) {
                trace("  miss win=\(evaluation.mateID) \(evaluation.edge) " +
                      "dist=\(Int(evaluation.distance)) " +
                      "overlap=\(String(format: "%.2f", evaluation.overlap)) " +
                      "dist_ok=\(evaluation.passesDistance) " +
                      "overlap_ok=\(evaluation.passesOverlap)")
            }
        }
    }

    private func openDrag(for event: AppObserver.WindowEvent) {
        let eligible = eligibleWindows()
        // Eligibility of the dragged window falls out of the sweep: the driver
        // only enumerates standard, non-minimized windows of unhidden regular
        // apps, and the sweep drops MacTLM and every excluded bundle.
        guard eligible.contains(where: { $0.windowID == event.windowID }) else {
            trace("no session: win=\(event.windowID) is not eligible " +
                  "(\(eligible.count) eligible windows swept)")
            return
        }
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
        guard let open = drag else {
            trace("mouse-up with no open session")
            return
        }
        let candidate = open.candidate
        endDrag()
        guard let candidate else {
            trace("mouse-up: no mate, nothing to do")
            return
        }
        guard let window = liveWindow(id: open.windowID, bundleID: open.bundleID) else {
            trace("mouse-up: win=\(open.windowID) vanished before it could be snapped")
            return
        }
        trace("mouse-up: snapping win=\(open.windowID) to \(candidate.snapped)")
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

    /// Frame at each window's previous RESIZED event. The no-op guard and
    /// propagation's `previous` must NOT read `monitor.lastKnownFrame`: an
    /// origin-moving resize (left/top edge drag) makes AX emit a moved twin
    /// before each resized event, and the moved twin refreshes that cache
    /// first — so the resized event compared equal and was eaten as a no-op.
    /// Measured live 2026-08-24: an 851pt width change classified "no-op",
    /// which killed live propagation for origin-moving drags and made resize
    /// sessions open only on lucky event ordering. This cache is scoped to
    /// resized events, which is what "previous" meant all along.
    private var lastResizedFrames: [Int: CGRect] = [:]

    private func handleResized(_ event: AppObserver.WindowEvent) {
        // First resized event for a window seeds from the general cache; the
        // moved twin may already have poisoned it to equal this event's frame,
        // in which case this event reads as a no-op and the NEXT one carries
        // the delta — one event's lag, self-correcting.
        let previous = lastResizedFrames[event.windowID]
            ?? monitor.lastKnownFrame(ofWindow: event.windowID)
            ?? event.frame
        // Bounded: window ids churn over weeks of daemon uptime.
        if lastResizedFrames.count > 256 { lastResizedFrames.removeAll() }
        lastResizedFrames[event.windowID] = event.frame

        // Finding 23: AX re-emits resized notifications whose frame is
        // identical to the previous one — 14 within 150ms during a plain
        // drag. Leave before paying for group resolution, and never let a
        // resize that resized nothing end the move session.
        let grew = abs(previous.width - event.frame.width) > 0.5
            || abs(previous.height - event.frame.height) > 0.5
        guard grew else {
            trace("no-op resize win=\(event.windowID) frame=\(event.frame): ignored")
            return
        }

        // Now it is genuinely a resize gesture rather than a move, so a session
        // opened by the moved events a resize also emits must not snap on
        // release.
        if drag?.windowID == event.windowID {
            trace("ending session for win=\(event.windowID): really resized to " +
                  "\(event.frame.size)")
            endDrag()
        }

        // Cheapest question first: with no groups remembered there is nothing
        // to propagate to.
        let groups = coordinator.magnetGroups()
        guard !groups.isEmpty,
              let slot = coordinator.slot(forWindowID: event.windowID,
                                          bundleID: event.bundleID),
              let group = groups.first(where: {
                  $0.contains(bundleID: event.bundleID, slot: slot)
              })
        else { return }

        let live = coordinator.liveMembers(of: group)
        // A genuine resize of a grouped window may be scaling the whole
        // group: open the settle-on-release session before live propagation
        // runs, so an outer-edge drag (which propagates nothing) still ends
        // with a settle.
        openResize(for: event, previous: previous, live: live)
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
        trace("resize win=\(event.windowID) previous=\(previous) now=\(event.frame) " +
              "mode=\(group.resizeMode) mates=\(frames.count - 1) moves=\(moves.count)")
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

    // MARK: - Resize sessions

    private struct Resize {
        let windowID: Int
        let bundleID: String
        /// Frames of every live member at session start, keyed by window id —
        /// the dragged window's is its pre-gesture frame.
        let startFrames: [Int: CGRect]
        /// Live members at session start, for back-to-front application.
        let members: [PersistenceCoordinator.LiveMember]
        let outerEdges: Set<MagnetMating.Edge>
        let mouseUpMonitor: Any?
    }
    private var resize: Resize?

    /// Opens the settle-on-release session for a grouped window that is being
    /// resized by the user. Reuses the group/live resolution `handleResized`
    /// already paid for.
    private func openResize(for event: AppObserver.WindowEvent,
                            previous: CGRect,
                            live: [PersistenceCoordinator.LiveMember]) {
        if let open = resize, open.windowID != event.windowID {
            // Nobody resizes two windows at once, and no mouse-up arrived for
            // the old one: dropping it is honest, settling it would not be —
            // the mirror of the move-session rule.
            trace("ending resize session for win=\(open.windowID): " +
                  "a different window resized")
            endResize()
        }
        // The release frame is read at mouse-up, not accumulated per event.
        guard resize == nil else { return }
        // Only a held left button is a user resize. Programmatic resizes never
        // open sessions.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        guard live.count > 1 else { return }
        var startFrames = Dictionary(live.map { ($0.window.id, $0.window.frame) },
                                     uniquingKeysWith: { first, _ in first })
        // The driver's enumeration can trail the notification: the dragged
        // window's start frame is its pre-gesture frame.
        startFrames[event.windowID] = previous
        let outer = MagnetScale.outerEdges(
            of: previous,
            among: live.filter { $0.window.id != event.windowID }
                .map { $0.window.frame },
            gap: Self.gap)
        let mouseUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) {
            [weak self] _ in self?.finishResize()
        }
        resize = Resize(windowID: event.windowID,
                        bundleID: event.bundleID,
                        startFrames: startFrames,
                        members: live,
                        outerEdges: outer,
                        mouseUpMonitor: mouseUp)
        trace("resize session open win=\(event.windowID) outer=\(outer)")
    }

    /// Mouse-up: the resize is over. Settle the group so it scales as one
    /// window along the axes whose outer edges moved.
    private func finishResize() {
        guard let open = resize else {
            trace("mouse-up with no open resize session")
            return
        }
        endResize()
        var releaseFrames: [Int: CGRect] = [:]
        for member in open.members {
            let id = member.window.id
            releaseFrames[id] = monitor.lastKnownFrame(ofWindow: id)
                ?? liveWindow(id: id, bundleID: member.member.bundleID)?.frame
                ?? open.startFrames[id]
        }
        let moved = MagnetScale.settle(startFrames: open.startFrames,
                                       releaseFrames: releaseFrames,
                                       changed: open.windowID,
                                       outerEdges: open.outerEdges)
        guard !moved.isEmpty else {
            trace("resize settle win=\(open.windowID): nothing to move")
            return
        }
        // Deepest first, same stacking argument as live propagation. Every
        // frame goes through write(), which suppresses its own AX echo so the
        // settle cannot re-enter mating, propagation, or session-opening.
        let ordered = PersistenceCoordinator.backToFront(
            open.members.filter { moved[$0.window.id] != nil })
        for member in ordered {
            guard let frame = moved[member.window.id] else { continue }
            write(frame, to: member.window, bundleID: member.member.bundleID)
        }
        trace("resize settle moved=\(moved.count) of=\(open.members.count)")
    }

    /// Removes the mouse-up monitor and the session. Safe to call twice, like
    /// `endDrag`.
    private func endResize() {
        if let mouseUp = resize?.mouseUpMonitor { NSEvent.removeMonitor(mouseUp) }
        resize = nil
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
        // Keep the resize-scoped previous current for frames WE moved, or the
        // next genuine event would measure its delta against a pre-settle
        // frame and propagate a change nobody made.
        lastResizedFrames[window.id] = achieved
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
