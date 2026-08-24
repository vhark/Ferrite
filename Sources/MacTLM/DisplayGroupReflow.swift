import AppKit
import MacTLMCore

/// Reflows windows into a preset.
///
/// A magnet group overrides the display: when the frontmost window belongs to
/// a group with two or more windows open, only that group reflows, inside its
/// own bounding box, with the weights the user set. Otherwise the group is
/// every eligible window on the display holding the frontmost window: standard
/// subrole, not minimized, app not excluded, and never MacTLM itself. Weights
/// then come from stacking order — frontmost is heaviest — so the treemap needs
/// no manual setup.
struct DisplayGroupReflow {
    let driver: MacWindowDriver
    let excludedBundleIDs: Set<String>
    /// Answers which group, if any, owns the frontmost window. Unowned like
    /// `MagnetDragSession`'s: the coordinator outlives every reflow it starts.
    unowned let coordinator: PersistenceCoordinator

    struct Outcome {
        let moved: Int
        /// The group that overrode the display, so the caller can remember
        /// which preset it was last reflowed with.
        let group: MagnetGroup?
    }

    /// Applies `preset` to the frontmost window's group, or to its whole
    /// display when it has no group.
    @discardableResult
    func apply(_ preset: GroupLayoutSolver.Preset,
               gap: CGFloat = 8,
               minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Outcome {
        if let active = coordinator.activeGroup() {
            let moved = apply(preset, to: active.group, live: active.live,
                              gap: gap, minimumSize: minimumSize)
            return Outcome(moved: moved, group: active.group)
        }
        return Outcome(moved: applyToDisplay(preset, gap: gap, minimumSize: minimumSize),
                       group: nil)
    }

    /// Reflows one group inside its own bounding box. `live` is the group's
    /// members that have a window open, already resolved by the caller.
    @discardableResult
    func apply(_ preset: GroupLayoutSolver.Preset,
               to group: MagnetGroup,
               live: [PersistenceCoordinator.LiveMember],
               gap: CGFloat = 8,
               minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Int {
        let windows = live.map {
            GroupReflowPlanner.LiveWindow(id: $0.window.id,
                                          bundleID: $0.member.bundleID,
                                          slot: $0.member.slot,
                                          frame: $0.window.frame)
        }
        guard let plan = GroupReflowPlanner.plan(group: group, live: windows,
                                                 preset: preset, gap: gap,
                                                 minimumSize: minimumSize) else { return 0 }
        var moved = 0
        // Deepest first, so the frontmost window ends up on top.
        for member in PersistenceCoordinator.backToFront(live) {
            guard let target = plan.frames[member.window.id] else { continue }
            write(target, to: member.window)
            moved += 1
        }
        return moved
    }

    private func applyToDisplay(_ preset: GroupLayoutSolver.Preset,
                                gap: CGFloat,
                                minimumSize: CGSize) -> Int {
        guard let display = targetDisplay() else { return 0 }
        let members = eligibleWindows(on: display)
        guard members.count > 1 else { return 0 }

        // Frontmost (lowest z index) is heaviest.
        let tiles = members.enumerated().map { index, member in
            GroupLayoutSolver.Tile(id: member.window.id,
                                   weight: Double(members.count - index))
        }
        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                            in: display.visibleArea, gap: gap,
                                            minimumSize: minimumSize)
        var moved = 0
        // Apply back-to-front so the frontmost window ends up on top.
        for member in members.reversed() {
            guard let target = solved[member.window.id] else { continue }
            write(target, to: member.window)
            moved += 1
        }
        return moved
    }

    /// Same clamp policy as RestoreEngine: set, read back, one retry, then
    /// accept whatever the app insisted on.
    private func write(_ target: CGRect, to window: DriverWindow) {
        let achieved = driver.setFrame(target, of: window)
        if !achieved.approximatelyEquals(target, tolerance: RestoreEngine.tolerance) {
            _ = driver.setFrame(target, of: window)
        }
    }

    private struct Member {
        let window: DriverWindow
        let bundleID: String
    }

    /// The display containing the frontmost eligible window, else the main one.
    private func targetDisplay() -> SnapshotPlanner.Display? {
        let displays = ScreenGeometry.allDisplays
        guard !displays.isEmpty else { return nil }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !excludedBundleIDs.contains(frontmost),
           let window = driver.windows(ofBundleID: frontmost).first,
           let owning = displays.first(where: {
               $0.visibleArea.contains(CGPoint(x: window.frame.midX,
                                               y: window.frame.midY))
           }) {
            return owning
        }
        return displays.first
    }

    /// Front-to-back eligible windows whose centre lies on `display`.
    private func eligibleWindows(on display: SnapshotPlanner.Display) -> [Member] {
        var members: [Member] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !excludedBundleIDs.contains(bundleID),
                  seen.insert(bundleID).inserted else { continue }
            for window in driver.windows(ofBundleID: bundleID) {
                let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
                guard display.visibleArea.contains(centre) else { continue }
                members.append(Member(window: window, bundleID: bundleID))
            }
        }
        // Order by global stacking so weights follow what the user is using.
        let order = ZOrderMatcher.zIndices(
            axWindows: members.map {
                ZOrderMatcher.AXRef(id: $0.window.id, pid: $0.window.pid,
                                    frame: $0.window.frame)
            },
            cgFrontToBack: ZOrderCapture.frontToBack())
        return members.sorted {
            (order[$0.window.id] ?? .max) < (order[$1.window.id] ?? .max)
        }
    }
}
