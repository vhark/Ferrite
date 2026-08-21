import AppKit
import MacTLMCore

/// Reflows the windows of one display into a preset.
///
/// M3a has no explicit magnet groups yet (those arrive with drag-mating in
/// M3b), so the group is every eligible window on the display holding the
/// frontmost window: standard subrole, not minimized, app not excluded, and
/// never MacTLM itself. Weights come from stacking order — frontmost is
/// heaviest — so the treemap needs no manual setup.
struct DisplayGroupReflow {
    let driver: MacWindowDriver
    let excludedBundleIDs: Set<String>

    /// Applies `preset` and returns the number of windows moved.
    @discardableResult
    func apply(_ preset: GroupLayoutSolver.Preset,
               gap: CGFloat = 8,
               minimumSize: CGSize = CGSize(width: 240, height: 160)) -> Int {
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
            // Same clamp policy as RestoreEngine: set, read back, one retry,
            // then accept whatever the app insisted on.
            let achieved = driver.setFrame(target, of: member.window)
            if !achieved.approximatelyEquals(target, tolerance: RestoreEngine.tolerance) {
                _ = driver.setFrame(target, of: member.window)
            }
            moved += 1
        }
        return moved
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
