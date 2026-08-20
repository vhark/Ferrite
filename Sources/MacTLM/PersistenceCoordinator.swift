import AppKit
import MacTLMCore

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
    private(set) lazy var templateLauncher = TemplateLauncher(driver: driver,
                                                              coordinator: self,
                                                              engine: engine)
    private struct PendingSettle {
        let debouncer: Debouncer
        let fire: () -> Void
    }
    /// bundleID → armed settle. Presence suppresses tracker capture.
    private var pendingSettles: [String: PendingSettle] = [:]
    private var screenToken: NSObjectProtocol?
    var isPaused = false

    var currentExcludedBundleIDs: Set<String> { excludeList.bundleIDs }

    private var excludeList: ExcludeList {
        get { excludeBox.list }
        set { excludeBox.list = newValue }
    }

    init() throws {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTLM")
        store = try LayoutStore(directory: supportDir.appendingPathComponent("configurations"))
        excludeURL = supportDir.appendingPathComponent("exclude.json")
        excludeBox = ExcludeListBox(ExcludeList.load(from: excludeURL))
        layoutLibraryStore = LayoutLibraryStore(
            url: supportDir.appendingPathComponent("layouts.json"))
        tracker = WindowTracker(
            driver: driver, store: store,
            configKey: { ScreenGeometry.currentConfiguration.key },
            visibleArea: { ScreenGeometry.cgVisibleAreaOfMainScreen },
            excludeList: { [excludeBox] in excludeBox.list })
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
        monitor.start()

        // Display-configuration changes swap the record namespace and re-assert.
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isPaused else { return }
                self.tracker.reloadForCurrentConfiguration()
                self.restoreAll()
        }

        // Login trigger: launched at login → restore everything after a grace
        // period for macOS Resume to finish reopening apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, !self.isPaused else { return }
            self.restoreAll()
        }
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
        excludeList.bundleIDs.insert(bundleID)
        try? excludeList.save(to: excludeURL)
    }

    func saveCurrentArrangement(name: String, stageMode: StageMode) {
        let layouts = SnapshotBuilder.snapshot(name: name, stageMode: stageMode)
        guard !layouts.isEmpty else { return }
        var library = layoutLibraryStore.load()
        library.upsert(layouts)
        try? layoutLibraryStore.save(library)
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

    func deleteLayout(id: UUID) {
        var library = layoutLibraryStore.load()
        library.layouts.removeAll { $0.id == id }
        try? layoutLibraryStore.save(library)
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
