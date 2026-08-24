import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Capture side of persistence: merges an app's open windows into its records
/// on activity, persists debounced, flushes on app termination.
public final class WindowTracker {
    /// Ceiling on remembered windows per app. Records survive their windows
    /// now, so without one a document app would grow its list forever.
    static let maxRecordsPerApp = 16

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

    /// Magnet groups remembered for the loaded configuration.
    public var magnetGroups: [MagnetGroup] { records.groups }

    /// Replaces the remembered groups, then flushes. Group edits come from a
    /// user gesture, so they must neither wait on the capture debounce nor be
    /// clobbered by it: the debounced save writes this whole record set, so a
    /// group written anywhere else would not survive the next capture.
    public func setMagnetGroups(_ groups: [MagnetGroup]) {
        records.groups = groups
        persist()
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

    /// Merges the open windows into what is already remembered.
    ///
    /// Replacing the app's records with only the windows open at this instant
    /// silently destroyed the remembered frames of every window that was not
    /// open yet — and worse, once the counts lined up again the order fallback
    /// was allowed and the next window to appear was dragged into a slot that
    /// belonged to another. Any app whose windows appear more than a settle
    /// apart hit it, as did any user reopening documents one at a time.
    private func capture(bundleID: String) {
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { return } // keep last-known on close-all
        let area = visibleArea()
        guard area.width > 0, area.height > 0 else { return }
        let existing = records.apps[bundleID] ?? []

        // One identity-resolution path: `WindowMatcher` pairs live windows with
        // records here exactly as it does for restore — pins, then identity
        // hashes, then order — so capture and restore can never disagree about
        // which record belongs to which window. The order fallback is gated the
        // same way `RestoreEngine` gates it: with fewer live windows than
        // records, the missing ones are simply not open, and pairing the
        // survivors by z-order would overwrite the wrong record's frame.
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title,
                            titleHash: window.titleHash, order: index)
        }
        let assignment = WindowMatcher.assign(
            records: existing, to: candidates,
            allowOrderFallback: windows.count >= existing.count)

        let now = Date()
        var merged = existing
        var seen = Set<Int>() // slots this capture touched; never evictable
        var nextSlot = (existing.map(\.slot).max() ?? -1) + 1
        for window in windows {
            let frame = NormalizedFrame(windowFrame: window.frame, visibleArea: area)
            if let matched = assignment[window.id],
               let index = merged.firstIndex(where: { $0.slot == matched.slot }) {
                // Slot and pin are the record's identity; only what the window
                // currently looks like is refreshed.
                merged[index].frame = frame
                merged[index].titleHash = window.titleHash
                merged[index].lastSeen = now
                seen.insert(matched.slot)
            } else {
                merged.append(WindowRecord(slot: nextSlot, titleHash: window.titleHash,
                                           frame: frame, pinPattern: nil, lastSeen: now))
                seen.insert(nextSlot)
                nextSlot += 1
            }
        }
        records.apps[bundleID] = evictingOverflow(from: merged, keeping: seen)
            .sorted { $0.slot < $1.slot }
    }

    /// Records now outlive the windows they describe, so the list needs a
    /// ceiling: an app churning through documents would otherwise accumulate
    /// them forever. The stalest go first, and only ever the stale — a pinned
    /// record was asked for by name, and one seen in this capture is open right
    /// now. If that leaves nothing evictable the cap yields; correctness of the
    /// remembered set outranks its size.
    private func evictingOverflow(from merged: [WindowRecord],
                                  keeping seen: Set<Int>) -> [WindowRecord] {
        let overflow = merged.count - Self.maxRecordsPerApp
        guard overflow > 0 else { return merged }
        let doomed = Set(merged
            .filter { $0.pinPattern == nil && !seen.contains($0.slot) }
            .sorted { $0.lastSeen < $1.lastSeen }
            .prefix(overflow)
            .map(\.slot))
        return merged.filter { !doomed.contains($0.slot) }
    }

    private func persist() {
        try? store.save(records, configKey: loadedKey)
    }
}
