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
    /// bundleID → settle debouncer. Presence means "restore pending".
    private var pendingRestores: [String: Debouncer] = [:]
    var isPaused = false

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
        tracker = WindowTracker(
            driver: driver, store: store,
            configKey: { ScreenGeometry.currentConfiguration.key },
            visibleArea: { ScreenGeometry.cgVisibleAreaOfMainScreen },
            excludeList: { [excludeBox] in excludeBox.list })
        engine = RestoreEngine(driver: driver)
    }

    func start() {
        monitor.onActivity = { [weak self] bundleID in
            guard let self, !self.isPaused else { return }
            if let settle = self.pendingRestores[bundleID] {
                // Restore pending: feed the settle timer, do NOT track — the
                // app's own launch placement must not overwrite our records.
                settle.call { [weak self] in self?.fireRestore(bundleID) }
            } else {
                self.tracker.noteActivity(bundleID: bundleID)
            }
        }
        monitor.onAppLaunched = { [weak self] bundleID in
            guard let self, !self.isPaused,
                  !self.excludeList.isExcluded(bundleID),
                  !self.tracker.recordsFor(bundleID: bundleID).isEmpty else { return }
            let settle = Debouncer(delay: 1.5, maxDelay: 10.0)
            self.pendingRestores[bundleID] = settle
            settle.call { [weak self] in self?.fireRestore(bundleID) }
        }
        monitor.onAppTerminated = { [weak self] bundleID in
            self?.pendingRestores.removeValue(forKey: bundleID)?.cancel()
            self?.tracker.noteTermination(bundleID: bundleID)
        }
        monitor.start()

        // Display-configuration changes swap the record namespace and re-assert.
        NotificationCenter.default.addObserver(
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

    private func fireRestore(_ bundleID: String) {
        pendingRestores.removeValue(forKey: bundleID)
        engine.restore(records: tracker.recordsFor(bundleID: bundleID),
                       bundleID: bundleID,
                       visibleArea: ScreenGeometry.cgVisibleAreaOfMainScreen)
    }
}
