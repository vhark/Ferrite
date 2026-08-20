# M2c — Apps Tab and Layout Entry Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the things that are still JSON-edit-only from the Preferences window — the exclude list, pin rules, stale per-app records, and individual windows inside a saved workspace.

**Architecture:** Core gains record and entry mutations (pure, unit-tested). The Preferences window becomes a `TabView` with **Layouts** and **Apps** tabs. All record edits route through `WindowTracker` rather than the store file (see the hazard below).

**Tech Stack:** Swift 5.9 mode, XCTest, AppKit, SwiftUI, KeyboardShortcuts 3.0.1. No new dependencies.

**Scope correction from the original M2c sketch:** the target-display picker and per-app merged placement are **dropped from this milestone**. Both require a second monitor to verify, and the author runs one display; writing them blind is exactly the speculative work they were deferred to avoid. They stay in `docs/BACKLOG.md` until there is hardware to test against.

## CRITICAL hazard: records must be mutated through the tracker

`WindowTracker` holds `ConfigurationRecords` in memory and persists them wholesale (debounced ~2s, and on app termination). If the Preferences UI wrote pin edits or record deletions straight to `configurations/<key>.json`, the tracker's next persist would silently overwrite them with its stale in-memory copy. Every record mutation in this plan therefore goes through new `WindowTracker` methods that mutate memory **and** flush immediately. Do not add a code path that writes that file from anywhere else.

Layout edits are safe to make through `LayoutLibraryStore` directly — nothing holds `LayoutLibrary` in memory across calls.

**Observed data motivating this milestone** (live store, 2026-08-20): records exist for `Oracle.MacJREInstaller`, `com.apple.calculator`, and a `com.apple.TextEdit` slot titled `"Open"` — a transient dialog captured before the subrole filter existed. `Design&Comms` has 9 entries including Spotify, Obsidian, and Rambox, which the author may not consider workspace members.

**Spec:** PRD §3.1 (pin rules), §4 (Preferences: Apps tab). Prior findings: `docs/BACKLOG.md`.

---

### Task 1: Record mutations in Core

**Files:**
- Modify: `Sources/MacTLMCore/WindowRecord.swift`
- Create: `Tests/MacTLMCoreTests/ConfigurationRecordsMutationTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/ConfigurationRecordsMutationTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class ConfigurationRecordsMutationTests: XCTestCase {
    private func record(slot: Int, title: String, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, title: title,
                     frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.5),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testSetPinPatternOnSlot() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work"), record(slot: 1, title: "Personal")],
        ])
        records.setPinPattern("Work", bundleID: "arc", slot: 0)
        XCTAssertEqual(records.apps["arc"]?[0].pinPattern, "Work")
        XCTAssertNil(records.apps["arc"]?[1].pinPattern)
    }

    func testClearPinPatternWithNil() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work", pin: "Work")],
        ])
        records.setPinPattern(nil, bundleID: "arc", slot: 0)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern)
    }

    func testSetPinPatternIgnoresUnknownAppOrSlot() {
        var records = ConfigurationRecords(apps: ["arc": [record(slot: 0, title: "Work")]])
        records.setPinPattern("X", bundleID: "nope", slot: 0)
        records.setPinPattern("X", bundleID: "arc", slot: 9)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern)
        XCTAssertNil(records.apps["nope"])
    }

    func testForgetAppRemovesEveryRecord() {
        var records = ConfigurationRecords(apps: [
            "arc": [record(slot: 0, title: "Work")],
            "junk": [record(slot: 0, title: "Open")],
        ])
        records.forgetApp(bundleID: "junk")
        XCTAssertNil(records.apps["junk"])
        XCTAssertEqual(records.apps.count, 1)
    }

    func testEmptyPinTreatedAsCleared() {
        var records = ConfigurationRecords(apps: ["arc": [record(slot: 0, title: "W")]])
        records.setPinPattern("   ", bundleID: "arc", slot: 0)
        XCTAssertNil(records.apps["arc"]?[0].pinPattern,
                     "whitespace-only pins must clear, not match everything")
    }
}
```
The last test matters: `WindowMatcher` already guards `!pattern.isEmpty`, but a whitespace-only pin would slip past that guard and claim the frontmost window.

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `setPinPattern`.

- [ ] **Step 3: Implement**

Append to `Sources/MacTLMCore/WindowRecord.swift`:
```swift
public extension ConfigurationRecords {
    /// Sets or clears a slot's pin pattern. Blank input clears it, so a
    /// whitespace-only pattern can never claim the frontmost window.
    mutating func setPinPattern(_ pattern: String?, bundleID: String, slot: Int) {
        guard var slots = apps[bundleID],
              let index = slots.firstIndex(where: { $0.slot == slot }) else { return }
        let trimmed = pattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        slots[index].pinPattern = (trimmed?.isEmpty ?? true) ? nil : trimmed
        apps[bundleID] = slots
    }

    /// Drops every remembered window for an app (stale or unwanted records).
    mutating func forgetApp(bundleID: String) {
        apps.removeValue(forKey: bundleID)
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (5 new; 95 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowRecord.swift Tests/MacTLMCoreTests/ConfigurationRecordsMutationTests.swift
git commit -m "feat: pin-pattern and forget-app record mutations"
```

---

### Task 2: Tracker-mediated record editing

**Files:**
- Modify: `Sources/MacTLMCore/WindowTracker.swift`
- Modify: `Tests/MacTLMCoreTests/WindowTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacTLMCoreTests/WindowTrackerTests.swift`:
```swift
    func testSetPinPatternPersistsImmediately() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker(saveDelay: 60) // debounce far in the future
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Work", bundleID: "arc", slot: 0)
        // Immediate flush, not waiting on the debounce.
        XCTAssertEqual(store.load(configKey: "test-config")
            .apps["arc"]?[0].pinPattern, "Work")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    func testPinSurvivesTheNextCapture() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        tracker.setPinPattern("Work", bundleID: "arc", slot: 0)
        // A later capture must not wipe the pin the user just set.
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }

    func testForgetAppClearsMemoryAndDisk() {
        driver.windowsByBundle["junk"] = [
            DriverWindow(id: 1, title: "Open", frame: CGRect(x: 0, y: 25, width: 400, height: 300)),
        ]
        let tracker = makeTracker(saveDelay: 60)
        tracker.noteActivity(bundleID: "junk")
        tracker.forgetApp(bundleID: "junk")
        XCTAssertTrue(tracker.recordsFor(bundleID: "junk").isEmpty)
        XCTAssertNil(store.load(configKey: "test-config").apps["junk"])
    }

    func testRememberedBundleIDsReflectsForget() {
        driver.windowsByBundle["a"] = [
            DriverWindow(id: 1, title: "A", frame: CGRect(x: 0, y: 25, width: 400, height: 300)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "a")
        XCTAssertEqual(tracker.rememberedBundleIDs, ["a"])
        tracker.forgetApp(bundleID: "a")
        XCTAssertTrue(tracker.rememberedBundleIDs.isEmpty)
    }
```
`testPinSurvivesTheNextCapture` guards the existing `assignPins` carry-over: capture preserves pins by title match, then slot fallback, so a freshly set pin must not be lost on the next window event.

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `setPinPattern` on `WindowTracker`.

- [ ] **Step 3: Implement**

Add to `WindowTracker` (public API, alongside `recordsFor`):
```swift
    /// Sets or clears a pin, then flushes. Pin edits come from the UI, so they
    /// must not wait on the capture debounce (and must not be clobbered by it).
    public func setPinPattern(_ pattern: String?, bundleID: String, slot: Int) {
        records.setPinPattern(pattern, bundleID: bundleID, slot: slot)
        persist()
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
```

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 99 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowTracker.swift Tests/MacTLMCoreTests/WindowTrackerTests.swift
git commit -m "feat: tracker-mediated pin and forget-app editing"
```

---

### Task 3: Layout entry mutations in Core

**Files:**
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Create: `Tests/MacTLMCoreTests/LayoutEntryEditingTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutEntryEditingTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutEntryEditingTests: XCTestCase {
    private func entry(_ bundleID: String, z: Int, optional: Bool = false) -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, title: "\(bundleID) window",
                    frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: optional)
    }

    private func library(entries: [LayoutEntry]) -> LayoutLibrary {
        LayoutLibrary(layouts: [
            MonitorLayout(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                          name: "W", displayID: "A", displayName: "DA",
                          displayMetrics: DisplayInfo(id: "A", width: 1600,
                                                      height: 1000, scale: 2.0),
                          stageMode: .leaveOthers, entries: entries,
                          createdAt: Date(timeIntervalSince1970: 0)),
        ])
    }

    func testRemoveEntryDropsItAndReindexesZ() {
        var lib = library(entries: [entry("a", z: 0), entry("b", z: 1), entry("c", z: 2)])
        let id = lib.layouts[0].id
        lib.removeEntry(atIndex: 1, fromLayoutID: id)
        XCTAssertEqual(lib.layouts[0].entries.map(\.bundleID), ["a", "c"])
        XCTAssertEqual(lib.layouts[0].entries.map(\.zIndex), [0, 1],
                       "z reindexed contiguously so stacking stays well-ordered")
    }

    func testRemoveEntryIgnoresBadIndexOrID() {
        var lib = library(entries: [entry("a", z: 0)])
        lib.removeEntry(atIndex: 5, fromLayoutID: lib.layouts[0].id)
        lib.removeEntry(atIndex: 0, fromLayoutID: UUID())
        XCTAssertEqual(lib.layouts[0].entries.count, 1)
    }

    func testSetEntryOptional() {
        var lib = library(entries: [entry("a", z: 0), entry("b", z: 1)])
        let id = lib.layouts[0].id
        lib.setEntryOptional(true, atIndex: 1, inLayoutID: id)
        XCTAssertFalse(lib.layouts[0].entries[0].optional)
        XCTAssertTrue(lib.layouts[0].entries[1].optional)
    }

    func testRemovingLastEntryLeavesAnEmptyLayoutNotACrash() {
        var lib = library(entries: [entry("a", z: 0)])
        lib.removeEntry(atIndex: 0, fromLayoutID: lib.layouts[0].id)
        XCTAssertTrue(lib.layouts[0].entries.isEmpty)
        XCTAssertEqual(lib.layouts.count, 1)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `removeEntry`.

- [ ] **Step 3: Implement**

Append to `Sources/MacTLMCore/LayoutModels.swift`:
```swift
public extension LayoutLibrary {
    /// Removes one window from a layout and reindexes zIndex contiguously so
    /// the remaining windows keep a well-ordered stacking sequence.
    mutating func removeEntry(atIndex index: Int, fromLayoutID layoutID: UUID) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[layoutIndex].entries.indices.contains(index) else { return }
        layouts[layoutIndex].entries.remove(at: index)
        let reordered = layouts[layoutIndex].entries
            .enumerated()
            .sorted { $0.element.zIndex < $1.element.zIndex }
        var rebuilt = layouts[layoutIndex].entries
        for (newZ, pair) in reordered.enumerated() {
            rebuilt[pair.offset].zIndex = newZ
        }
        layouts[layoutIndex].entries = rebuilt
    }

    mutating func setEntryOptional(_ optional: Bool, atIndex index: Int,
                                   inLayoutID layoutID: UUID) {
        guard let layoutIndex = layouts.firstIndex(where: { $0.id == layoutID }),
              layouts[layoutIndex].entries.indices.contains(index) else { return }
        layouts[layoutIndex].entries[index].optional = optional
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 103 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/LayoutModels.swift Tests/MacTLMCoreTests/LayoutEntryEditingTests.swift
git commit -m "feat: remove and flag individual layout entries"
```

---

### Task 4: Coordinator surface for the Apps tab

**Files:**
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`

- [ ] **Step 1: Add the API**

```swift
    // MARK: - Preferences surface

    /// One row per app with remembered windows, for the Apps tab.
    struct AppRecordSummary: Identifiable {
        let bundleID: String
        let displayName: String
        let slots: [WindowRecord]
        let isExcluded: Bool
        var id: String { bundleID }
    }

    func appRecordSummaries() -> [AppRecordSummary] {
        let excluded = excludeList.bundleIDs
        return tracker.allRecords()
            .map { bundleID, slots in
                AppRecordSummary(
                    bundleID: bundleID,
                    displayName: Self.localizedAppName(forBundleID: bundleID),
                    slots: slots.sorted { $0.slot < $1.slot },
                    isExcluded: excluded.contains(bundleID))
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending }
    }

    /// Best-effort human name; falls back to the bundle ID for apps that are
    /// not installed any more (stale records are exactly what this tab cleans).
    private static func localizedAppName(forBundleID bundleID: String) -> String {
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
        try? layoutLibraryStore.save(library)
    }

    func setEntryOptional(_ optional: Bool, atIndex index: Int, inLayoutID layoutID: UUID) {
        var library = layoutLibraryStore.load()
        library.setEntryOptional(optional, atIndex: index, inLayoutID: layoutID)
        try? layoutLibraryStore.save(library)
    }
```
`tracker` is currently `private let`; keep it private and expose only these wrappers. `excludeList` is the computed property over `ExcludeListBox`, so writes already reach the tracker's closure — verify that the existing `exclude(bundleID:)` menu action still compiles and behaves (it may now be expressible as `setExcluded(true, bundleID:)`; if so, make it call through and delete the duplicate body).

- [ ] **Step 2: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 103 tests; bundle built.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTLM/PersistenceCoordinator.swift
git commit -m "feat: coordinator surface for apps and entry editing"
```

---

### Task 5: Preferences becomes tabbed, with an Apps tab

**Files:**
- Create: `Sources/MacTLM/AppsPreferencesView.swift`
- Modify: `Sources/MacTLM/PreferencesWindowController.swift`
- Modify: `Sources/MacTLM/LayoutsPreferencesView.swift`

- [ ] **Step 1: Apps tab view**

`Sources/MacTLM/AppsPreferencesView.swift` — a `List` over `coordinator.appRecordSummaries()`, one section per app:
- Header: app display name, with the bundle ID as a caption.
- **Exclude toggle** ("Never move this app's windows") bound to `setExcluded(_:bundleID:)`. Show a hint when the app is one of `ExcludeList.defaults` so the user understands why Illustrator starts excluded.
- One row per remembered slot: `slot`, the captured title (truncated), and a `TextField` for the pin pattern committing on `.onSubmit` to `setPinPattern(_:bundleID:slot:)`. Placeholder: "no pin". Caption under the field, shown once per app: "A pin re-attaches a remembered position to the window whose title matches this pattern."
- **Forget button** per app calling `forgetApp(bundleID:)`, behind a confirmation (`.confirmationDialog`, Cancel as the safe default) worded: `Forget saved positions for "<name>"? · MacTLM will stop restoring its windows until it learns them again.` Rationale: same "too easy and permanent" lesson as layout deletion.
- Model: `AppsPreferencesModel: ObservableObject` with `@Published var apps: [PersistenceCoordinator.AppRecordSummary]`, `reload()`, and one method per mutation, each reloading after.

- [ ] **Step 2: Entry editing in the Layouts tab**

In `LayoutsPreferencesView`, each active workspace row gains a `DisclosureGroup` ("N windows") listing that bundle's layouts and their entries. Per entry: `zIndex`, app display name, truncated title, an **Optional** checkbox (`setEntryOptional`), and a **Remove** button (`removeEntry`) — no confirmation, since a removed entry is recoverable by re-snapshotting and the row is inert once gone. Removing the last entry leaves an empty layout, which is allowed (Core test covers it); show "No windows left in this layout." in that case.

- [ ] **Step 3: Tabs**

`PreferencesWindowController` hosts a `TabView` with two tabs — "Layouts" (`LayoutsPreferencesView`) and "Apps" (`AppsPreferencesView`) — sharing one window; widen `minWidth` to 620. Window title stays "MacTLM Layouts" or becomes "MacTLM Preferences" (prefer the latter now that it is not layouts-only). Update the menu item text from "Layouts…" to "Preferences…" with `keyEquivalent: ","` and the ⌘ modifier, matching macOS convention.

- [ ] **Step 4: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 103 tests; bundle built. Do not launch the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: tabbed preferences with Apps tab and entry editing"
```

---

### Task 6: Live acceptance (user at keyboard)

- [ ] **Step 1:** `./scripts/install.sh`, confirm the menu-bar icon returns and `--login-status` is still `enabled`.
- [ ] **Step 2:** Menu → **Preferences…** (⌘,) opens a two-tab window. The Apps tab lists apps with remembered windows, sorted by display name.
- [ ] **Step 3 (the cleanup this milestone exists for):** Forget the stale records — `Oracle.MacJREInstaller`, `com.apple.calculator`, and the `com.apple.TextEdit` slot titled "Open". Confirm the dialog appears, then that the rows disappear and `configurations/<key>.json` no longer contains those apps.
- [ ] **Step 4:** Pin one of the two Arc windows: type a pattern matching a stable part of its title, submit, and verify the pin appears in the JSON immediately (no 2s wait). Then move both Arc windows, quit and relaunch Arc, and confirm the pinned window returns to its own slot.
- [ ] **Step 5:** Verify the tracker hazard is really handled: with the app running, set a pin, then immediately move a window of the same app (triggering a capture) and re-read the JSON. The pin must still be there.
- [ ] **Step 6:** In the Layouts tab, expand `Design + Comms` and remove Spotify, Obsidian, and Rambox. Launch the workspace via its hotkey and confirm those apps are no longer moved, while the rest still land correctly.
- [ ] **Step 7:** Toggle **Never move this app's windows** on for some app, move its windows, relaunch it, and confirm MacTLM leaves it alone.
- [ ] **Step 8:** Tag:
```bash
git tag -a v0.4.0-m2c -m "M2c: Apps tab, pin editing, record cleanup, layout entry editing"
```

---

## Plan self-review notes

- **Spec coverage:** PRD §4's Apps tab (exclude list + pin rules) ✓ (T1, T2, T4, T5); PRD §3.1 pin rules become editable rather than JSON-only ✓; `optional` entry flags become editable ✓ (T3, T5). Not in this milestone and still JSON-only: nothing — after M2c every persisted field the PRD exposes has UI, except layout geometry itself (edited by re-snapshot, per PRD §3.2).
- **Hazard guard:** `testPinSurvivesTheNextCapture` and `testSetPinPatternPersistsImmediately` are the tests that would catch a regression into direct store writes, which is the failure mode most likely to lose user edits silently.
- **Type consistency:** `ConfigurationRecords.setPinPattern/forgetApp` (T1) consumed by `WindowTracker` (T2); `WindowTracker.allRecords/setPinPattern/forgetApp` (T2) consumed by the coordinator (T4); `AppRecordSummary` (T4) consumed by `AppsPreferencesView` (T5); `LayoutLibrary.removeEntry/setEntryOptional` (T3) consumed by the coordinator (T4) and the Layouts tab (T5).
- **Deliberate omission:** no unit tests for the SwiftUI views (no headless surface), consistent with M1–M2b. Covered by Task 6.
- **Dropped from the original sketch:** target-display picker and per-app merged placement — both need a second monitor to verify; they remain in `docs/BACKLOG.md`.

---

### Task 7 (amendment, added mid-execution): One workspace row, one submenu

A second display arrived mid-milestone, which made the M2b menu design's defect visible: a workspace spanning two displays appeared in **three** places with identical labels — once under "Workspaces (all displays)" and once under each display's section — and only the first restored both screens. Clicking a per-display row faithfully restored one screen and left the other scrambled, which is indistinguishable from a bug.

Measured evidence that the launcher itself is correct (2026-08-20): `--apply-bundle "Design&Print"` processed 2 layouts across 2 displays and placed both laptop windows pixel-exact (`crealityprint` → `(3045, 2198, 1986, 1291)`, `paseo` → `(3210, 2318, 1840, 1051)`, both matching computed expectations). The fix is therefore purely presentational.

**New menu shape:** one row per workspace. Single-display workspaces act directly. Multi-display workspaces open a submenu: **All displays**, then one item per member display, each marked *(adapted)* when that display is not currently connected.

**Files:**
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Create: `Tests/MacTLMCoreTests/LayoutBundleConnectionTests.swift`
- Modify: `Sources/MacTLM/StatusMenuController.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutBundleConnectionTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutBundleConnectionTests: XCTestCase {
    private func layout(_ display: String) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: "W", displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: .leaveOthers, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testSplitsConnectedFromDisconnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A"), layout("B")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["A"])
        XCTAssertEqual(split.connected.map(\.displayID), ["A"])
        XCTAssertEqual(split.disconnected.map(\.displayID), ["B"])
    }

    func testAllConnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A"), layout("B")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["A", "B"])
        XCTAssertEqual(split.connected.count, 2)
        XCTAssertTrue(split.disconnected.isEmpty)
        XCTAssertTrue(bundle.isFullyConnected(connectedDisplayIDs: ["A", "B"]))
    }

    func testNoneConnected() {
        let bundle = LayoutBundle(name: "W", layouts: [layout("A")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["Z"])
        XCTAssertTrue(split.connected.isEmpty)
        XCTAssertEqual(split.disconnected.count, 1)
        XCTAssertFalse(bundle.isFullyConnected(connectedDisplayIDs: ["Z"]))
    }

    func testPreservesLayoutOrderWithinEachGroup() {
        let bundle = LayoutBundle(name: "W",
                                  layouts: [layout("A"), layout("B"), layout("C")])
        let split = bundle.layoutsByConnection(connectedDisplayIDs: ["C", "A"])
        XCTAssertEqual(split.connected.map(\.displayID), ["A", "C"],
                       "bundle layout order is preserved, not reordered by the set")
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `layoutsByConnection`.

- [ ] **Step 3: Implement in Core**

Append to `Sources/MacTLMCore/LayoutModels.swift`:
```swift
public extension LayoutBundle {
    /// Splits the workspace's layouts by whether their display is attached
    /// right now, preserving bundle order within each group.
    func layoutsByConnection(connectedDisplayIDs: Set<String>)
        -> (connected: [MonitorLayout], disconnected: [MonitorLayout]) {
        (layouts.filter { connectedDisplayIDs.contains($0.displayID) },
         layouts.filter { !connectedDisplayIDs.contains($0.displayID) })
    }

    func isFullyConnected(connectedDisplayIDs: Set<String>) -> Bool {
        layouts.allSatisfy { connectedDisplayIDs.contains($0.displayID) }
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 107 total).

- [ ] **Step 5: Rebuild the menu's workspace listing**

In `StatusMenuController.menuNeedsUpdate`, DELETE the three competing sections (the "Workspaces (all displays)" section, the per-connected-display sections, and the "Inactive Monitor Layouts" submenu) and replace them with a single **Workspaces** section over `coordinator.loadBundles()`:

- Let `connected = Set(ScreenGeometry.allDisplays.map(\.info.id))`.
- Split bundles into those with at least one connected display and those with none. The latter go into a collapsed **Workspaces for other displays** submenu at the end, same row shape.
- **Row per workspace**, titled with the bundle name and carrying the bundle's hotkey via `setShortcut` (unchanged behavior):
  - `bundle.layouts.count == 1` → direct action `launchBundle(_:)` (identical to today for single-display workspaces).
  - otherwise → a **submenu**:
    - `All displays` → `launchBundle(_:)` with `representedObject = bundle.name as NSString`.
    - one item per layout in bundle order, titled `layout.displayName`, or `"\(layout.displayName) (adapted)"` when `!connected.contains(layout.displayID)`, action `launchSingleLayout(_:)` with `representedObject = layout.id as NSUUID`.
- Add `@objc private func launchSingleLayout(_ sender: NSMenuItem)` resolving the UUID through `menuLayouts` and calling `coordinator.applyLayout(_:)`. Keep `menuLayouts` populated by whatever builds these rows.
- `layoutItem(_:indent:)` is no longer used by the menu once per-display sections are gone; delete it if nothing else references it (check first), or keep it only if the submenu rows reuse it.

Everything below (Save Current Arrangement, Restore All, Pause, Exclude Frontmost, Launch at Login, Preferences…, Quit) is unchanged.

- [ ] **Step 6: Verify and commit**

`swift build` clean, `swift test` 107 passing, `./scripts/make-app.sh` succeeds. Do not launch the app.
```bash
git add Sources docs Tests
git commit -m "fix: one workspace row per layout set, with an explicit display submenu"
```
