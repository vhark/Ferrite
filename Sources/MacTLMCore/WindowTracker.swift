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
        self.records = store.load(configKey: loadedKey)
    }

    /// Call on window created/moved/resized/title-changed for an app.
    public func noteActivity(bundleID: String) {
        guard !excludeList().isExcluded(bundleID) else { return }
        guard configKey() == loadedKey else { return } // mid-config-change; caller reloads next
        capture(bundleID: bundleID)
        saveDebouncer.call { [weak self] in self?.persist() }
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

    /// Call when the display configuration changes: swap namespaces.
    public func reloadForCurrentConfiguration() {
        saveDebouncer.cancel()
        persist() // flush old namespace before swapping
        loadedKey = configKey()
        records = store.load(configKey: loadedKey)
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
                         title: window.title,
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
