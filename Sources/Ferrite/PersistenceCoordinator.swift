import AppKit
import FerriteCore

/// Mutable box so the tracker's excludeList closure sees the coordinator's
/// current list without capturing `self` before full initialization.
final class ExcludeListBox {
    var list: ExcludeList
    init(_ list: ExcludeList) { self.list = list }
}

/// Wires monitor → tracker/engine. Owns the launch-settle state machine.
final class PersistenceCoordinator {
    private let driver = MacWindowDriver()
    private let store: LayoutStore
    private let tracker: WindowTracker
    private let engine: RestoreEngine
    private let monitor = WorkspaceMonitor()
    private let excludeBox: ExcludeListBox
    private let excludeURL: URL
    let layoutLibraryStore: LayoutLibraryStore
    private let reflowStore: ReflowStore
    private(set) lazy var templateLauncher = TemplateLauncher(driver: driver,
                                                              coordinator: self,
                                                              engine: engine)
    /// Mating and shared-edge resize. Lazy: it is only needed once window
    /// events start arriving, and it needs a fully initialized coordinator.
    private lazy var magnetSession = MagnetDragSession(driver: driver,
                                                       monitor: monitor,
                                                       coordinator: self)
    private struct PendingSettle {
        let debouncer: Debouncer
        let fire: () -> Void
    }
    /// bundleID → armed settle. Presence suppresses tracker capture.
    private var pendingSettles: [String: PendingSettle] = [:]
    private var screenToken: NSObjectProtocol?
    var isPaused = false
    /// Fires after the record namespace has been swapped, so open UI can
    /// re-read instead of showing the previous configuration's records.
    var onConfigurationChanged: (() -> Void)?
    /// Fires after any layout-library write (menu saves included), so an open
    /// Layouts tab re-reads instead of showing a stale list — the library
    /// sibling of `onConfigurationChanged` (finding 16).
    var onLayoutLibraryChanged: (() -> Void)?
    /// Fires after any reflow-settings write (custom presets, group policy),
    /// so the menu and an open Reflows tab re-read — same lesson as
    /// onLayoutLibraryChanged (finding 16 corollary).
    var onReflowSettingsChanged: (() -> Void)?

    var currentExcludedBundleIDs: Set<String> { excludeList.bundleIDs }

    private var excludeList: ExcludeList {
        get { excludeBox.list }
        set { excludeBox.list = newValue }
    }

    init() throws {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ferrite")
        // One-shot MacTLM → Ferrite migration, BEFORE any store reads: the
        // stores below adopt whatever is on disk at construction, so the
        // legacy files must already be in place (finding 15: never write the
        // store through anything but its own path handling — copy wholesale
        // before it loads instead).
        let migration = LegacyMigration.run(
            oldDirectory: supportDir.deletingLastPathComponent()
                .appendingPathComponent("MacTLM"),
            newDirectory: supportDir,
            oldDefaults: UserDefaults(suiteName: "dev.mactlm.MacTLM"),
            newDefaults: .standard)
        NSLog(migration.didAnything ? "Ferrite: migrated — %@"
                                    : "Ferrite: migration no-op — %@",
              migration.summary)
        store = try LayoutStore(directory: supportDir.appendingPathComponent("configurations"))
        excludeURL = supportDir.appendingPathComponent("exclude.json")
        excludeBox = ExcludeListBox(ExcludeList.load(from: excludeURL))
        layoutLibraryStore = LayoutLibraryStore(
            url: supportDir.appendingPathComponent("layouts.json"))
        reflowStore = ReflowStore(url: supportDir.appendingPathComponent("reflows.json"))
        // Legacy files (written before hashed identities) still carry plaintext
        // titles. Scrub every namespace once per launch, not just the one the
        // tracker loads: a raw-text check per file, rewriting only dirty ones.
        store.purgeLegacyTitlesInAllNamespaces()
        layoutLibraryStore.purgeLegacyTitles()
        tracker = WindowTracker(
            driver: driver, store: store,
            configKey: { ScreenGeometry.currentConfiguration.key },
            visibleArea: { ScreenGeometry.cgVisibleAreaOfMainScreen },
            excludeList: { [excludeBox] in excludeBox.list })
        // A missed didChangeScreenParameters used to stop capture dead; the
        // tracker now repairs itself, and this is the only trace it leaves.
        tracker.onConfigurationDrift = { stale, live in
            NSLog("Ferrite: display configuration drifted unnoticed (%@ -> %@); "
                  + "migrated records namespace mid-capture", stale, live)
        }
        engine = RestoreEngine(driver: driver)
    }

    deinit {
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
    }

    func start() {
        // Arm settle restores for remembered apps that are already running,
        // BEFORE the monitor's startup sweep kickstarts capture — otherwise the
        // sweep overwrites saved records and the login restore becomes a no-op.
        for bundleID in tracker.rememberedBundleIDs
        where !excludeList.isExcluded(bundleID)
            && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            armSettle(bundleID: bundleID) { [weak self] in
                self?.restoreRecords(bundleID: bundleID)
            }
        }

        monitor.onActivity = { [weak self] bundleID in
            guard let self, !self.isPaused else { return }
            if let settle = self.pendingSettles[bundleID] {
                // Settle pending: feed the settle timer, do NOT track — the
                // app's own launch placement must not overwrite our records.
                settle.debouncer.call(settle.fire)
            } else {
                self.tracker.noteActivity(bundleID: bundleID)
            }
        }
        monitor.onAppLaunched = { [weak self] bundleID in
            guard let self, !self.isPaused,
                  !self.excludeList.isExcluded(bundleID),
                  !self.tracker.recordsFor(bundleID: bundleID).isEmpty else { return }
            guard self.pendingSettles[bundleID] == nil else { return }
            self.armSettle(bundleID: bundleID) { [weak self] in
                self?.restoreRecords(bundleID: bundleID)
            }
        }
        monitor.onAppTerminated = { [weak self] bundleID in
            if let settle = self?.pendingSettles.removeValue(forKey: bundleID) {
                settle.debouncer.cancel()
            }
            self?.tracker.noteTermination(bundleID: bundleID)
        }
        // Mating and resize propagation ride the rich per-window events. The
        // coarse activity signal above keeps its meaning and its call sites.
        monitor.onWindowEvent = { [weak self] event in
            guard let self, !self.isPaused else { return }
            self.magnetSession.handle(event)
        }
        monitor.start()

        // Display-configuration changes swap the record namespace and re-assert.
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isPaused else { return }
                self.tracker.reloadForCurrentConfiguration()
                self.restoreAll()
                // The Apps tab lists one namespace's records; after a swap its
                // rows describe records the tracker no longer holds.
                self.onConfigurationChanged?()
        }

        // Login trigger: launched at login → restore everything after a grace
        // period for macOS Resume to finish reopening apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, !self.isPaused else { return }
            self.restoreAll()
        }

        refreshShortcuts()
    }

    /// Restore every remembered app that is currently running.
    func restoreAll() {
        let area = ScreenGeometry.cgVisibleAreaOfMainScreen
        guard area.width > 0, area.height > 0 else { return }
        for bundleID in tracker.rememberedBundleIDs
        where !excludeList.isExcluded(bundleID) {
            engine.restore(records: tracker.recordsFor(bundleID: bundleID),
                           bundleID: bundleID, visibleArea: area)
        }
    }

    func exclude(bundleID: String) {
        setExcluded(true, bundleID: bundleID)
    }

    func saveCurrentArrangement(name: String, stageMode: StageMode) {
        let layouts = SnapshotBuilder.snapshot(name: name, stageMode: stageMode)
        guard !layouts.isEmpty else { return }
        var library = layoutLibraryStore.load()
        library.upsert(layouts)
        writeLibrary(library)
        refreshShortcuts()
    }

    func applyLayout(_ layout: MonitorLayout) {
        templateLauncher.apply([layout], excludedBundleIDs: currentExcludedBundleIDs)
    }

    /// Launches every layout sharing this name — the whole workspace.
    func applyBundle(named name: String) {
        let layouts = layoutLibraryStore.load().layouts.filter { $0.name == name }
        guard !layouts.isEmpty else { return }
        templateLauncher.apply(layouts, excludedBundleIDs: currentExcludedBundleIDs)
    }

    /// Reflows every eligible window on the active display into `preset`.
    /// Magnet groups follow the stored policy: exploded (dissolved, members
    /// placed individually — the default) or kept as one tile each. A reflow
    /// is a normal window move: the tracker records the new frames afterwards.
    func reflowDisplay(_ preset: GroupLayoutSolver.Preset) {
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs,
                                        coordinator: self)
        let keep = reflowStore.load().keepGroupsOnDisplayReflow
        let outcome = reflow.applyToDisplay(preset, keepGroups: keep)
        let dissolved = keep ? 0 : dissolveGroups(scatteredAmong: outcome.writtenWindowIDs)
        NSLog("Ferrite: display reflow %@ moved %d windows (%@ groups, %d dissolved)",
              String(describing: preset), outcome.written,
              keep ? "kept" : "exploded", dissolved)
    }

    /// Reflows exactly one group inside its own bounding box.
    func reflowGroup(_ preset: GroupLayoutSolver.Preset, groupID: UUID) {
        guard let group = magnetGroups().first(where: { $0.id == groupID }) else { return }
        let live = liveMembers(of: group)
        guard live.count > 1 else { return }
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs,
                                        coordinator: self)
        let moved = reflow.apply(preset, to: group, live: live)
        lastGroupPreset[group.id] = preset
        NSLog("Ferrite: group reflow %@ moved %d windows",
              String(describing: preset), moved)
    }

    /// Explode policy: a group whose windows this reflow actually scattered
    /// loses its membership, reusing the Groups menu's own ungroup path
    /// (finding 20). Never leave a group whose members no longer touch —
    /// stale membership with broken adjacency is a documented footgun. But a
    /// group the reflow never touched — one living on another display, say —
    /// is left completely alone: never discard user work the operation did not
    /// affect (finding 18). Returns how many groups it dissolved.
    private func dissolveGroups(scatteredAmong writtenWindowIDs: Set<Int>) -> Int {
        var dissolved = 0
        // A snapshot: `ungroup` rewrites the tracker's array on every call.
        for group in magnetGroups() {
            let touched = liveMembers(of: group).contains {
                writtenWindowIDs.contains($0.window.id)
            }
            guard touched else { continue }
            ungroup(group.id)
            dissolved += 1
        }
        return dissolved
    }

    // MARK: - Magnet groups

    /// A group member paired with the window it currently resolves to.
    struct LiveMember {
        let member: MagnetMember
        let window: DriverWindow
    }

    /// The magnet groups remembered for the display configuration in use now.
    func magnetGroups() -> [MagnetGroup] {
        tracker.magnetGroups
    }

    /// Mates two windows: extends whichever group already holds one of them,
    /// unions the two when both are grouped already, otherwise starts a new
    /// group. Persisted through the tracker — writing the store file from here
    /// would be undone by the tracker's next debounced save.
    func mate(_ member: MagnetMember, with other: MagnetMember) {
        guard member != other else { return }
        var groups = tracker.magnetGroups
        let host = groups.firstIndex { $0.contains(bundleID: member.bundleID,
                                                   slot: member.slot) }
        let mate = groups.firstIndex { $0.contains(bundleID: other.bundleID,
                                                   slot: other.slot) }
        switch (host, mate) {
        case (let index?, nil):
            groups[index].members.append(other)
        case (nil, let index?):
            groups[index].members.append(member)
        case (let left?, let right?):
            guard left != right else { return } // already mates
            let absorbed = groups.remove(at: right)
            groups[right < left ? left - 1 : left].merge(absorbed)
        case (nil, nil):
            groups.append(MagnetGroup(members: [member, other]))
        }
        tracker.setMagnetGroups(groups.filter { !$0.isDissolved })
    }

    /// Forgets a group. Its windows keep their frames: ungrouping changes what
    /// Ferrite remembers, it does not move anything.
    func ungroup(_ groupID: UUID) {
        let groups = tracker.magnetGroups
        let remaining = groups.filter { $0.id != groupID }
        guard remaining.count != groups.count else { return }
        tracker.setMagnetGroups(remaining)
    }

    /// Removes one member from whatever group holds it, dropping the group
    /// when it dissolves below two members. No-op when no group contains the
    /// member. Like `ungroup(_:)`, this changes what Ferrite remembers — it
    /// does not move anything.
    func unmate(bundleID: String, slot: Int) {
        var groups = tracker.magnetGroups
        guard let index = groups.firstIndex(where: {
            $0.contains(bundleID: bundleID, slot: slot)
        }) else { return }
        groups[index].remove(bundleID: bundleID, slot: slot)
        tracker.setMagnetGroups(groups.filter { !$0.isDissolved })
    }

    /// The record slot a live window resolves to, or nil when its identity is
    /// not certain. The order fallback is off on purpose: group membership is
    /// written to disk, and the fallback is a guess — remembering the wrong
    /// window as a mate is worse than not remembering the mate at all.
    func slot(forWindowID windowID: Int, bundleID: String) -> Int? {
        let records = tracker.recordsFor(bundleID: bundleID)
        let windows = driver.windows(ofBundleID: bundleID)
        guard !records.isEmpty, !windows.isEmpty else { return nil }
        return WindowMatcher.assign(records: records,
                                    to: Self.windowCandidates(windows),
                                    allowOrderFallback: false)[windowID]?.slot
    }

    /// The members of `group` with a window open right now, resolved the same
    /// certain-identity way as `slot(forWindowID:bundleID:)`.
    func liveMembers(of group: MagnetGroup) -> [LiveMember] {
        var result: [LiveMember] = []
        for (bundleID, members) in Dictionary(grouping: group.members, by: \.bundleID) {
            let records = tracker.recordsFor(bundleID: bundleID)
            let windows = driver.windows(ofBundleID: bundleID)
            guard !records.isEmpty, !windows.isEmpty else { continue }
            let assignment = WindowMatcher.assign(records: records,
                                                  to: Self.windowCandidates(windows),
                                                  allowOrderFallback: false)
            for window in windows {
                guard let slot = assignment[window.id]?.slot,
                      let member = members.first(where: { $0.slot == slot }) else { continue }
                result.append(LiveMember(member: member, window: window))
            }
        }
        return result
    }

    /// Live members ordered deepest first, so a `setFrame` that raises its own
    /// window cannot leave the group's stacking inverted. The last element is
    /// therefore the frontmost. The CG sweep is skipped for a single window.
    static func backToFront(_ members: [LiveMember]) -> [LiveMember] {
        guard members.count > 1 else { return members }
        let order = ZOrderMatcher.zIndices(
            axWindows: members.map {
                ZOrderMatcher.AXRef(id: $0.window.id, pid: $0.window.pid,
                                    frame: $0.window.frame)
            },
            cgFrontToBack: ZOrderCapture.frontToBack())
        return members.sorted {
            (order[$0.window.id] ?? .max) > (order[$1.window.id] ?? .max)
        }
    }

    /// The preset each group was last reflowed with, for this session only: a
    /// preset is a gesture, not a setting, so it is never persisted.
    private var lastGroupPreset: [UUID: GroupLayoutSolver.Preset] = [:]

    /// The `(bundleID, slot)` of the frontmost app's front window, when its
    /// identity is certain. Excluded apps and Ferrite itself never own a group.
    private func frontmostMember() -> MagnetMember? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !excludeList.isExcluded(bundleID),
              let window = driver.windows(ofBundleID: bundleID).first,
              let slot = slot(forWindowID: window.id, bundleID: bundleID)
        else { return nil }
        return MagnetMember(bundleID: bundleID, slot: slot)
    }

    /// One menu row's worth of a group, with no AX resolution left to do.
    struct GroupSummary {
        let id: UUID
        let resizeMode: MagnetGroup.ResizeMode
        /// Localized app names of the members with a window open, in the order
        /// the user built the group.
        let title: String
        /// True for the group that owns the frontmost window.
        let isActive: Bool
    }

    /// The groups worth showing: two or more windows open. A group whose
    /// windows have all closed renders nothing rather than a broken row.
    func magnetGroupSummaries() -> [GroupSummary] {
        let groups = tracker.magnetGroups
        guard !groups.isEmpty else { return [] }
        let front = frontmostMember()
        return groups.compactMap { group in
            let live = Set(liveMembers(of: group).map(\.member))
            guard live.count > 1 else { return nil }
            let isActive = front.map {
                group.contains(bundleID: $0.bundleID, slot: $0.slot)
            } ?? false
            return GroupSummary(
                id: group.id,
                resizeMode: group.resizeMode,
                title: Self.title(ofMembers: group.members.filter(live.contains)),
                isActive: isActive)
        }
    }

    /// "Arc + Safari", or "Arc ×2" — two windows of one app is the common
    /// group, and repeating its name would read like a bug.
    private static func title(ofMembers members: [MagnetMember]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for member in members {
            let name = localizedAppName(forBundleID: member.bundleID)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 1
            return count == 1 ? name : "\(name) ×\(count)"
        }.joined(separator: " + ")
    }

    /// Switches a group between shrink and nudge. Written through the tracker
    /// like `ungroup`: a direct store write would be undone by its next save.
    func setResizeMode(_ mode: MagnetGroup.ResizeMode, ofGroup groupID: UUID) {
        var groups = tracker.magnetGroups
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].resizeMode != mode else { return }
        groups[index].resizeMode = mode
        tracker.setMagnetGroups(groups)
    }

    /// Scales the weight of the group's frontmost open window — the one the
    /// user is looking at, not the frontmost window overall — and re-runs the
    /// group's last preset so the change shows immediately. Clamping belongs
    /// to `MagnetGroup.adjustWeight` and is not repeated here.
    func adjustFrontmostWeight(inGroup groupID: UUID, by factor: Double) {
        var groups = tracker.magnetGroups
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let live = liveMembers(of: groups[index])
        // `backToFront` ends at the front.
        guard live.count > 1, let front = Self.backToFront(live).last else { return }
        groups[index].adjustWeight(bundleID: front.member.bundleID,
                                   slot: front.member.slot, by: factor)
        tracker.setMagnetGroups(groups)
        guard let preset = lastGroupPreset[groupID] else {
            // Nothing to re-run yet: the new weight lands the first time the
            // user picks a preset. Reflowing with a preset they never chose
            // would move windows they did not ask to have moved.
            return NSLog("Ferrite: group weight changed, no preset applied yet")
        }
        let reflow = DisplayGroupReflow(driver: driver,
                                        excludedBundleIDs: currentExcludedBundleIDs,
                                        coordinator: self)
        reflow.apply(preset, to: groups[index], live: live)
    }

    private static func windowCandidates(_ windows: [DriverWindow]) -> [WindowCandidate] {
        windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
    }

    func renameBundle(from oldName: String, to newName: String) {
        var library = layoutLibraryStore.load()
        library.renameBundle(from: oldName, to: newName)
        writeLibrary(library)
        LayoutShortcuts.migrate(from: oldName, to: newName)
        refreshShortcuts()
    }

    /// Reversible: hides the workspace from the menu and stops registering its
    /// hotkey. The recorded shortcut stays in UserDefaults for the restore.
    func archiveBundle(named name: String) {
        var library = layoutLibraryStore.load()
        library.archiveBundle(named: name)
        writeLibrary(library)
        refreshShortcuts()
    }

    func restoreBundle(named name: String) {
        var library = layoutLibraryStore.load()
        library.restoreBundle(named: name)
        writeLibrary(library)
        refreshShortcuts()
    }

    /// Permanent delete — only reachable from the archive in the UI.
    func deleteBundle(named name: String) {
        var library = layoutLibraryStore.load()
        library.deleteBundle(named: name)
        writeLibrary(library)
        LayoutShortcuts.clear(bundleName: name)
        refreshShortcuts()
    }

    func setStageMode(_ mode: StageMode, forBundleNamed name: String) {
        var library = layoutLibraryStore.load()
        library.setStageMode(mode, forBundleNamed: name)
        writeLibrary(library)
    }

    func loadBundles() -> [LayoutBundle] {
        layoutLibraryStore.load().activeBundles()
    }

    func loadArchivedBundles() -> [LayoutBundle] {
        layoutLibraryStore.load().archivedBundles()
    }

    func reflowSettings() -> ReflowSettings {
        reflowStore.load()
    }

    func updateReflowSettings(_ mutate: (inout ReflowSettings) -> Void) {
        var settings = reflowStore.load()
        mutate(&settings)
        try? reflowStore.save(settings)
        onReflowSettingsChanged?()
    }

    /// Single funnel for library writes: every mutation notifies open UI.
    private func writeLibrary(_ library: LayoutLibrary) {
        try? layoutLibraryStore.save(library)
        onLayoutLibraryChanged?()
    }

    // MARK: - Preferences surface

    /// One row per app with remembered windows, for the Apps tab.
    struct AppRecordSummary: Identifiable {
        let bundleID: String
        let displayName: String
        let slots: [WindowRecord]
        let isExcluded: Bool
        /// slot → the title of the window currently occupying it. Live and
        /// in-memory only; empty when the app is not running.
        let liveTitles: [Int: String]
        var id: String { bundleID }
    }

    func appRecordSummaries() -> [AppRecordSummary] {
        let excluded = excludeList.bundleIDs
        return tracker.allRecords()
            .map { bundleID, slots in
                let ordered = slots.sorted { $0.slot < $1.slot }
                return AppRecordSummary(
                    bundleID: bundleID,
                    displayName: Self.localizedAppName(forBundleID: bundleID),
                    slots: ordered,
                    isExcluded: excluded.contains(bundleID),
                    liveTitles: liveTitles(forRecords: ordered, bundleID: bundleID))
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending }
    }

    /// Runs the same assignment a restore would, so the title shown against a
    /// slot is the window that slot's frame would actually be applied to.
    private func liveTitles(forRecords records: [WindowRecord],
                            bundleID: String) -> [Int: String] {
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { return [:] }
        let assignment = WindowMatcher.assign(
            records: records, to: Self.windowCandidates(windows),
            allowOrderFallback: windows.count >= records.count)
        var titles: [Int: String] = [:]
        for window in windows where !window.title.isEmpty {
            guard let record = assignment[window.id] else { continue }
            titles[record.slot] = window.title
        }
        return titles
    }

    /// Entry index → live title for one saved layout. Entries persist only an
    /// opaque identity hash, so a title appears when the app has a window open
    /// with the same hash; anything else stays absent and the row falls back to
    /// its position label.
    func liveEntryTitles(forLayout layout: MonitorLayout) -> [Int: String] {
        var titlesByBundle: [String: [String: String]] = [:]  // bundle → hash → title
        var result: [Int: String] = [:]
        for (index, entry) in layout.entries.enumerated() {
            guard let hash = entry.titleHash else { continue }
            if titlesByBundle[entry.bundleID] == nil {
                var map: [String: String] = [:]
                for window in driver.windows(ofBundleID: entry.bundleID)
                where !window.title.isEmpty {
                    if let windowHash = window.titleHash { map[windowHash] = window.title }
                }
                titlesByBundle[entry.bundleID] = map
            }
            if let title = titlesByBundle[entry.bundleID]?[hash] { result[index] = title }
        }
        return result
    }

    /// Best-effort human name; falls back to the bundle ID for apps that are
    /// not installed any more (stale records are exactly what this tab cleans).
    static func localizedAppName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    func setPinPattern(_ pattern: String?, bundleID: String, slot: Int) {
        tracker.setPinPattern(pattern, bundleID: bundleID, slot: slot)
    }

    func forgetApp(bundleID: String) {
        tracker.forgetApp(bundleID: bundleID)
    }

    func setExcluded(_ excluded: Bool, bundleID: String) {
        if excluded {
            excludeList.bundleIDs.insert(bundleID)
        } else {
            excludeList.bundleIDs.remove(bundleID)
        }
        try? excludeList.save(to: excludeURL)
    }

    /// Entry editing for the Layouts tab.
    func removeEntry(atIndex index: Int, fromLayoutID layoutID: UUID) {
        var library = layoutLibraryStore.load()
        library.removeEntry(atIndex: index, fromLayoutID: layoutID)
        writeLibrary(library)
    }

    func setEntryOptional(_ optional: Bool, atIndex index: Int, inLayoutID layoutID: UUID) {
        var library = layoutLibraryStore.load()
        library.setEntryOptional(optional, atIndex: index, inLayoutID: layoutID)
        writeLibrary(library)
    }

    /// Re-reads the library and registers a hotkey handler per active bundle.
    /// Call after any library mutation so new bundles become triggerable and
    /// archived ones stop firing.
    func refreshShortcuts() {
        let names = layoutLibraryStore.load().activeBundles().map(\.name)
        LayoutShortcuts.register(bundleNames: names) { [weak self] bundleName in
            self?.applyBundle(named: bundleName)
        }
    }

    /// Arms (or re-arms) a settle for bundleID. While armed, activity events
    /// feed the settle timer instead of the tracker. `fire` runs once after
    /// 1.5s of quiet (10s cap) and the entry is removed first.
    func armSettle(bundleID: String, fire: @escaping () -> Void) {
        let debouncer = Debouncer(delay: 1.5, maxDelay: 10.0)
        let settle = PendingSettle(debouncer: debouncer) { [weak self] in
            self?.pendingSettles.removeValue(forKey: bundleID)
            fire()
        }
        pendingSettles[bundleID]?.debouncer.cancel()
        pendingSettles[bundleID] = settle
        debouncer.call(settle.fire)
    }

    private func restoreRecords(bundleID: String) {
        guard !isPaused, !excludeList.isExcluded(bundleID) else { return }
        let area = ScreenGeometry.cgVisibleAreaOfMainScreen
        guard area.width > 0, area.height > 0 else { return }
        engine.restore(records: tracker.recordsFor(bundleID: bundleID),
                       bundleID: bundleID, visibleArea: area)
    }
}
