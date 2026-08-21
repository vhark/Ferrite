import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Capture side of persistence: snapshots an app's windows into records on
/// activity, persists debounced, flushes on app termination.
public final class WindowTracker {
    private let driver: WindowDriving
    private let store: LayoutStore
    private let configKey: () -> String
    private let visibleArea: () -> CGRect
    private let excludeList: () -> ExcludeList
    private let saveDebouncer: Debouncer
    private var records: ConfigurationRecords
    private var loadedKey: String

    /// Called when a capture discovers the live configuration key no longer
    /// matches the loaded one and migrates itself (old key, new key). Core is
    /// Foundation-only and has no logger of its own; the app layer logs this.
    public var onConfigurationDrift: ((String, String) -> Void)?

    public init(driver: WindowDriving, store: LayoutStore,
                configKey: @escaping () -> String,
                visibleArea: @escaping () -> CGRect,
                excludeList: @escaping () -> ExcludeList,
                saveDelay: TimeInterval = 2.0) {
        self.driver = driver
        self.store = store
        self.configKey = configKey
        self.visibleArea = visibleArea
        self.excludeList = excludeList
        self.saveDebouncer = Debouncer(delay: saveDelay)
        self.loadedKey = configKey()
        self.records = store.loadPurgingLegacyTitles(configKey: loadedKey)
    }

    /// Call on window created/moved/resized/title-changed for an app.
    public func noteActivity(bundleID: String) {
        guard !excludeList().isExcluded(bundleID) else { return }
        healDriftIfNeeded()
        capture(bundleID: bundleID)
        saveDebouncer.call { [weak self] in self?.persist() }
    }

    /// The display configuration can change without
    /// `reloadForCurrentConfiguration()` ever running — a
    /// `didChangeScreenParameters` notification that is missed, coalesced, or
    /// arrives while paused. Until M2e that stranded the tracker on a dead
    /// namespace and every later capture was dropped, silently and forever.
    ///
    /// Migrating here keeps the original intent of that guard: records captured
    /// under configuration A are flushed to A's file *before* the swap, so
    /// nothing is written into B's file that belongs to A.
    private func healDriftIfNeeded() {
        let live = configKey()
        guard live != loadedKey else { return }
        let stale = loadedKey
        migrate(to: live)
        onConfigurationDrift?(stale, live)
    }

    /// Call when an app terminates — flush immediately (quit snapshot).
    public func noteTermination(bundleID: String) {
        saveDebouncer.cancel()
        persist()
    }

    public func recordsFor(bundleID: String) -> [WindowRecord] {
        records.apps[bundleID] ?? []
    }

    /// All bundle IDs with remembered windows in the current configuration.
    public var rememberedBundleIDs: [String] {
        Array(records.apps.keys)
    }

    /// Sets or clears a pin, then flushes. Pin edits come from the UI, so they
    /// must not wait on the capture debounce (and must not be clobbered by it).
    ///
    /// A pin describes a window, not a monitor arrangement, so it is applied to
    /// every namespace that remembers this slot — including ones not loaded.
    /// Without that, an edit made after a display change reached no file at
    /// all: the Apps tab still lists the namespace it opened with while the
    /// tracker has already swapped to one that has no record for the slot, so
    /// the mutation was a silent no-op.
    public func setPinPattern(_ pattern: String?, bundleID: String, slot: Int) {
        records.setPinPattern(pattern, bundleID: bundleID, slot: slot)
        persist()
        for key in store.configKeys() where key != loadedKey {
            var other = store.load(configKey: key)
            let before = other
            other.setPinPattern(pattern, bundleID: bundleID, slot: slot)
            guard other != before else { continue }
            try? store.save(other, configKey: key)
        }
    }

    /// Forgets every remembered window for an app, then flushes.
    public func forgetApp(bundleID: String) {
        records.forgetApp(bundleID: bundleID)
        persist()
    }

    /// Snapshot of everything remembered in this configuration, for the UI.
    public func allRecords() -> [String: [WindowRecord]] {
        records.apps
    }

    /// Call when the display configuration changes: swap namespaces.
    public func reloadForCurrentConfiguration() {
        migrate(to: configKey())
    }

    /// Flushes the loaded namespace, then adopts `key` and loads its records.
    /// Single migration implementation: the notified path and the drift-repair
    /// path must not be able to diverge.
    private func migrate(to key: String) {
        saveDebouncer.cancel()
        persist() // flush old namespace before swapping
        loadedKey = key
        records = store.loadPurgingLegacyTitles(configKey: loadedKey)
    }

    private func capture(bundleID: String) {
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { return } // keep last-known on close-all
        let area = visibleArea()
        guard area.width > 0, area.height > 0 else { return }
        let existing = records.apps[bundleID] ?? []
        let pins = assignPins(existing: existing, windows: windows)
        records.apps[bundleID] = windows.enumerated().map { index, window in
            WindowRecord(slot: index,
                         titleHash: window.titleHash,
                         frame: NormalizedFrame(windowFrame: window.frame, visibleArea: area),
                         pinPattern: pins[index],
                         lastSeen: Date())
        }
    }

    /// Pins follow their window: each pin re-attaches to the first captured
    /// window whose title matches its pattern; unmatched (or invalid/empty)
    /// pins fall back to their original slot.
    private func assignPins(existing: [WindowRecord], windows: [DriverWindow]) -> [Int: String] {
        var result: [Int: String] = [:]
        var unmatched: [(slot: Int, pattern: String)] = []
        var taken = Set<Int>()
        for record in existing {
            guard let pattern = record.pinPattern else { continue }
            if !pattern.isEmpty,
               let index = windows.indices.first(where: { candidate in
                   !taken.contains(candidate) && windows[candidate].title.range(
                       of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
               }) {
                result[index] = pattern
                taken.insert(index)
            } else {
                unmatched.append((record.slot, pattern))
            }
        }
        for (slot, pattern) in unmatched where slot < windows.count && result[slot] == nil {
            result[slot] = pattern
        }
        return result
    }

    private func persist() {
        try? store.save(records, configKey: loadedKey)
    }
}
