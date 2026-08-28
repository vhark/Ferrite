import AppKit
import FerriteCore

/// Reflows windows into a preset.
///
/// The target is always the caller's choice: `applyToDisplay` reflows every
/// eligible window on the active display — standard subrole, not minimized,
/// app not excluded, and never Ferrite itself — while `apply(_:to:live:)`
/// reflows one magnet group inside its own bounding box with the weights the
/// user set. Display weights come from stacking order, frontmost is heaviest,
/// so the treemap needs no manual setup.
struct DisplayGroupReflow {
    let driver: MacWindowDriver
    let excludedBundleIDs: Set<String>
    /// Answers which group, if any, owns the frontmost window. Unowned like
    /// `MagnetDragSession`'s: the coordinator outlives every reflow it starts.
    unowned let coordinator: PersistenceCoordinator

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

    /// Reflows every eligible window on the active display, returning how many
    /// were written. `keepGroups` picks the magnet-group policy: false places
    /// every window individually; true collapses each intact group into a
    /// single tile and carries its formation into the assigned cell.
    func applyToDisplay(_ preset: GroupLayoutSolver.Preset,
                        keepGroups: Bool,
                        gap: CGFloat = 8,
                        minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Int {
        guard let display = targetDisplay() else { return 0 }
        let members = eligibleWindows(on: display)
        guard members.count > 1 else { return 0 }
        guard keepGroups else {
            return placeIndividually(members, preset: preset,
                                     in: display.visibleArea,
                                     gap: gap, minimumSize: minimumSize)
        }

        // A group counts as intact only when two or more of ITS live members
        // are eligible here; window ids come from the coordinator's own
        // resolution so this adds no second notion of identity (finding 20).
        var groupOfWindow: [Int: UUID] = [:]
        var membersOfGroup: [UUID: [Member]] = [:]
        for group in coordinator.magnetGroups() {
            let live = Set(coordinator.liveMembers(of: group).map(\.window.id))
            let mine = members.filter {
                live.contains($0.window.id) && groupOfWindow[$0.window.id] == nil
            }
            guard mine.count > 1 else { continue }
            for member in mine { groupOfWindow[member.window.id] = group.id }
            membersOfGroup[group.id] = mine
        }

        // One tile per group (keyed by its frontmost member's window id, so the
        // group weighs exactly what that window would have weighed alone) plus
        // one tile per ungrouped window, all still in z-order.
        var tiles: [GroupLayoutSolver.Tile] = []
        var groupTiles: [Int: UUID] = [:]
        var soloTiles: [Int: DriverWindow] = [:]
        var dealt = Set<UUID>()
        for (index, member) in members.enumerated() {
            let tile = GroupLayoutSolver.Tile(id: member.window.id,
                                              weight: Double(members.count - index))
            if let groupID = groupOfWindow[member.window.id] {
                guard dealt.insert(groupID).inserted else { continue }
                groupTiles[member.window.id] = groupID
            } else {
                soloTiles[member.window.id] = member.window
            }
            tiles.append(tile)
        }
        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                             in: display.visibleArea, gap: gap,
                                             minimumSize: minimumSize)
        var moved = 0
        // Back-to-front so the frontmost window ends up on top. A group is
        // written when its tile-owning frontmost member comes up; its deeper
        // members are skipped until then.
        for member in members.reversed() {
            guard let target = solved[member.window.id] else { continue }
            if let groupID = groupTiles[member.window.id],
               let grouped = membersOfGroup[groupID] {
                // The union of the current frames is the formation's own box,
                // so remapping into the cell preserves relative placement.
                let frames = Dictionary(uniqueKeysWithValues:
                    grouped.map { ($0.window.id, $0.window.frame) })
                let box = grouped.dropFirst().reduce(grouped[0].window.frame) {
                    $0.union($1.window.frame)
                }
                let remapped = MagnetScale.remap(frames: frames, from: box, to: target)
                for sibling in grouped.reversed() {
                    guard let cell = remapped[sibling.window.id] else { continue }
                    write(cell, to: sibling.window)
                    moved += 1
                }
            } else if let window = soloTiles[member.window.id] {
                write(target, to: window)
                moved += 1
            }
        }
        return moved
    }

    /// Every window its own tile, weighted by stacking order.
    private func placeIndividually(_ members: [Member],
                                   preset: GroupLayoutSolver.Preset,
                                   in area: CGRect,
                                   gap: CGFloat,
                                   minimumSize: CGSize) -> Int {
        // Frontmost (lowest z index) is heaviest.
        let tiles = members.enumerated().map { index, member in
            GroupLayoutSolver.Tile(id: member.window.id,
                                   weight: Double(members.count - index))
        }
        let solved = GroupLayoutSolver.solve(tiles: tiles, preset: preset,
                                            in: area, gap: gap,
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
