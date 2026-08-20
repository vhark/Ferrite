# M2b — Bundles, Hotkeys, and Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One hotkey restores a whole saved workspace across every connected display, and layouts are managed in a Preferences window instead of hand-edited JSON.

**Architecture:** Core gains bundle grouping and a multi-layout apply planner (pure, unit-tested). The app gains a `KeyboardShortcuts` bridge keyed by bundle name, a SwiftUI Preferences window hosted in an `NSHostingController`, and menu entries for bundles with their shortcuts displayed.

**Tech Stack:** Swift 5.9 mode, XCTest, AppKit, SwiftUI (Preferences window only), `sindresorhus/KeyboardShortcuts` 3.0.1 (MIT) — the project's first external dependency.

**Key design decisions (settled before drafting):**
- **Bundles are derived, not persisted.** Layouts already key on `name + displayID` (upsert semantics), so same-name layouts across displays *are* a bundle. No new model, no migration.
- **Hotkeys attach to bundle names, not layout ids.** A single-display layout is a bundle of one, so PRD §9's "one hotkey from a clean login" falls out without per-monitor shortcuts.
- **Multi-apply is one operation, not a loop.** `TemplateLauncher` is single-flight; sequential `apply` calls would cancel each other. It takes a set of layouts, merges their stacking orders and launch lists, and awaits one result. Single-layout launch becomes the n=1 case.
- **SwiftUI is confined to the Preferences window.** Menu-bar, AX, and driver layers stay AppKit.

**Spec:** PRD §3.2, §4 in `docs/superpowers/specs/2026-08-19-mactlm-prd-design.md`. Prior findings: `docs/BACKLOG.md`.

**Scope boundary — M2c, not this plan:** the Apps tab (exclude-list editing, pin-rule editing). Pin rules and `optional` flags stay JSON-editable in M2b.

**Known limitation carried by this plan (stated, not hidden):** when one app has windows on *two* displays within a bundle, each display's records are matched against all of that app's windows, so a window can be claimed by the wrong display. The author runs a single display today, so this is scoped out deliberately rather than solved speculatively — fixing it needs per-app merged placement with absolute target rects, and real evidence to design against. Record it as a residual in `docs/BACKLOG.md` at Task 8.

---

### Task 1: Add the KeyboardShortcuts dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the dependency**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTLM",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
    ],
    targets: [
        .target(name: "MacTLMCore"),
        .executableTarget(
            name: "MacTLM",
            dependencies: [
                "MacTLMCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]),
        .testTarget(name: "MacTLMCoreTests", dependencies: ["MacTLMCore"]),
    ]
)
```
`MacTLMCore` must NOT gain the dependency — it stays pure and Linux-portable.

Version note: 3.0.1 specifically fixes a release-build crash under the Swift 6.3 compiler, which is this project's toolchain. Do not relax the lower bound.

- [ ] **Step 2: Verify resolution and that release builds work**

Run: `swift build && swift build -c release && swift test`
Expected: dependency resolves to 3.0.1 or later; both builds clean; 70 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add KeyboardShortcuts dependency"
```

---

### Task 2: LayoutBundle grouping in Core

**Files:**
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Create: `Tests/MacTLMCoreTests/LayoutBundleTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutBundleTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutBundleTests: XCTestCase {
    private func layout(_ name: String, display: String,
                        stage: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "Display \(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testBundlesGroupByNameSortedByName() {
        let library = LayoutLibrary(layouts: [
            layout("Zed", display: "A"),
            layout("Alpha", display: "A"),
            layout("Alpha", display: "B"),
        ])
        let bundles = library.bundles()
        XCTAssertEqual(bundles.map(\.name), ["Alpha", "Zed"])
        XCTAssertEqual(bundles[0].layouts.count, 2)
        XCTAssertEqual(bundles[1].layouts.count, 1)
    }

    func testBundleSpansMultipleDisplaysFlag() {
        let library = LayoutLibrary(layouts: [
            layout("Solo", display: "A"),
            layout("Dual", display: "A"),
            layout("Dual", display: "B"),
        ])
        let bundles = library.bundles()
        XCTAssertEqual(bundles.first { $0.name == "Dual" }?.spansMultipleDisplays, true)
        XCTAssertEqual(bundles.first { $0.name == "Solo" }?.spansMultipleDisplays, false)
    }

    func testBundleLayoutsAreOrderedByDisplayName() {
        let library = LayoutLibrary(layouts: [
            layout("Dual", display: "Z"),
            layout("Dual", display: "A"),
        ])
        let bundle = library.bundles()[0]
        XCTAssertEqual(bundle.layouts.map(\.displayID), ["A", "Z"])
    }

    func testEmptyLibraryHasNoBundles() {
        XCTAssertTrue(LayoutLibrary().bundles().isEmpty)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `value of type 'LayoutLibrary' has no member 'bundles'`.

- [ ] **Step 3: Implement**

Append to `Sources/MacTLMCore/LayoutModels.swift`:
```swift
/// A named workspace: every saved layout sharing one name, one per display.
/// Derived from the library rather than persisted — `upsert` already keys on
/// (name, displayID), so same-name layouts across displays are a bundle.
public struct LayoutBundle: Equatable {
    public let name: String
    public let layouts: [MonitorLayout]

    public var spansMultipleDisplays: Bool {
        Set(layouts.map(\.displayID)).count > 1
    }

    public init(name: String, layouts: [MonitorLayout]) {
        self.name = name
        self.layouts = layouts
    }
}

public extension LayoutLibrary {
    /// Bundles sorted by name; each bundle's layouts sorted by display name.
    func bundles() -> [LayoutBundle] {
        Dictionary(grouping: layouts, by: \.name)
            .sorted { $0.key < $1.key }
            .map { name, group in
                LayoutBundle(name: name,
                             layouts: group.sorted { $0.displayID < $1.displayID })
            }
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 74 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/LayoutModels.swift Tests/MacTLMCoreTests/LayoutBundleTests.swift
git commit -m "feat: derive layout bundles from same-name layouts"
```

---

### Task 3: MultiApplyPlanner in Core

**Files:**
- Create: `Sources/MacTLMCore/MultiApplyPlanner.swift`
- Create: `Tests/MacTLMCoreTests/MultiApplyPlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/MultiApplyPlannerTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class MultiApplyPlannerTests: XCTestCase {
    private func target(_ id: String, x: CGFloat) -> TemplateApplyPlanner.Target {
        TemplateApplyPlanner.Target(
            info: DisplayInfo(id: id, width: 1600, height: 1000, scale: 2.0),
            visibleArea: CGRect(x: x, y: 25, width: 1600, height: 975))
    }

    private func layout(_ name: String, display: String, stage: StageMode,
                        entries: [LayoutEntry]) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: entries,
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, z: Int) -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, title: "",
                    frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: false)
    }

    func testMergesItemsPerDisplay() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("a", z: 0)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("b", z: 0)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items[0].visibleArea.minX, 0)
        XCTAssertEqual(plan.items[1].visibleArea.minX, 1600)
        XCTAssertEqual(plan.memberBundleIDs, ["a", "b"])
    }

    func testStackingOrderMergedBackmostFirstAcrossDisplays() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("front", z: 0), entry("deep", z: 9)]),
                 target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("middle", z: 3)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.appStackingOrder, ["deep", "middle", "front"])
    }

    func testLaunchListDedupedAcrossDisplaysBackmostFirst() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("shared", z: 1)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .leaveOthers,
                        entries: [entry("shared", z: 7), entry("solo", z: 2)]),
                 target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.appsToLaunch, ["shared", "solo"],
                       "shared app launches once, ranked by its backmost window")
    }

    func testAnyClearStageMakesTheWholeOperationClearStage() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("a", z: 0)]), target("A", x: 0)),
                (layout("W", display: "B", stage: .clearStage,
                        entries: [entry("b", z: 0)]), target("B", x: 1600)),
            ],
            runningBundleIDs: [], excludedBundleIDs: [])
        XCTAssertEqual(plan.stageMode, .clearStage)
    }

    func testRunningAppsAreNotLaunchedButStillStacked() {
        let plan = MultiApplyPlanner.plan(
            requests: [
                (layout("W", display: "A", stage: .leaveOthers,
                        entries: [entry("running", z: 0)]), target("A", x: 0)),
            ],
            runningBundleIDs: ["running"], excludedBundleIDs: [])
        XCTAssertTrue(plan.appsToLaunch.isEmpty)
        XCTAssertEqual(plan.appStackingOrder, ["running"])
    }

    func testSingleRequestMatchesSingleLayoutPlan() {
        let single = layout("W", display: "A", stage: .leaveOthers,
                            entries: [entry("a", z: 0), entry("b", z: 1)])
        let multi = MultiApplyPlanner.plan(requests: [(single, target("A", x: 0))],
                                           runningBundleIDs: [], excludedBundleIDs: [])
        let direct = TemplateApplyPlanner.plan(layout: single, runningBundleIDs: [],
                                               excludedBundleIDs: [],
                                               target: target("A", x: 0))
        XCTAssertEqual(multi.appStackingOrder, direct.appStackingOrder)
        XCTAssertEqual(multi.appsToLaunch, direct.appsToLaunch)
        XCTAssertEqual(multi.items[0].plan.placements, direct.placements)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'MultiApplyPlanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/MultiApplyPlanner.swift`:
```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Plans one apply operation spanning several displays (a bundle launch).
/// Single-layout launches are the n = 1 case, so the launcher has one path.
public enum MultiApplyPlanner {
    public struct Item {
        public let plan: TemplateApplyPlanner.ApplyPlan
        public let visibleArea: CGRect
    }

    public struct MultiPlan {
        /// One entry per requested layout, in request order.
        public let items: [Item]
        /// Merged, deduped, backmost-first across every display.
        public let appsToLaunch: [String]
        /// Merged activation order, backmost-first across every display.
        public let appStackingOrder: [String]
        public let memberBundleIDs: Set<String>
        /// clearStage when ANY member layout asks for it.
        public let stageMode: StageMode
    }

    public static func plan(
        requests: [(layout: MonitorLayout, target: TemplateApplyPlanner.Target)],
        runningBundleIDs: Set<String>,
        excludedBundleIDs: Set<String>
    ) -> MultiPlan {
        var items: [Item] = []
        // An app's backmost window across ALL displays decides its rank, so a
        // shared app is activated once, behind everything it sits behind.
        var backmostZ: [String: Int] = [:]
        var members = Set<String>()
        var anyClearStage = false

        for request in requests {
            let plan = TemplateApplyPlanner.plan(layout: request.layout,
                                                 runningBundleIDs: runningBundleIDs,
                                                 excludedBundleIDs: excludedBundleIDs,
                                                 target: request.target)
            items.append(Item(plan: plan, visibleArea: request.target.visibleArea))
            members.formUnion(plan.memberBundleIDs)
            if plan.stageMode == .clearStage { anyClearStage = true }
            for (rank, bundleID) in plan.appStackingOrder.enumerated() {
                // appStackingOrder is backmost-first, so rank 0 is the deepest
                // window of that display. Convert back to a comparable depth.
                let depth = plan.appStackingOrder.count - rank
                backmostZ[bundleID] = max(backmostZ[bundleID] ?? Int.min, depth)
            }
        }

        let stackingOrder = backmostZ.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)

        return MultiPlan(items: items,
                         appsToLaunch: stackingOrder.filter {
                             !runningBundleIDs.contains($0) && members.contains($0)
                         },
                         appStackingOrder: stackingOrder,
                         memberBundleIDs: members,
                         stageMode: anyClearStage ? .clearStage : .leaveOthers)
    }
}
```

If `testSingleRequestMatchesSingleLayoutPlan` or the merge-order tests fail, the depth conversion is the suspect — fix the conversion, do NOT weaken the tests. The contract: for a single display the merged order must equal `ApplyPlan.appStackingOrder` exactly.

- [ ] **Step 4: Run `swift test`** — PASS (6 new; 80 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/MultiApplyPlanner.swift Tests/MacTLMCoreTests/MultiApplyPlannerTests.swift
git commit -m "feat: MultiApplyPlanner merges per-display plans into one operation"
```

---

### Task 4: Launcher takes a set of layouts

**Files:**
- Modify: `Sources/MacTLM/TemplateLauncher.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`

- [ ] **Step 1: Replace `Sources/MacTLM/TemplateLauncher.swift` entirely**

This is a rewrite of the in-flight state machine that took three review rounds in M2a. Every existing behavior must survive: supersede-on-new-apply, clear-stage hiding that never hides MacTLM, excluded apps activated but never placed, the 15s missing-app report, retained flight for late arrivals with a 120s hard stop, and the 0.06s-spaced activation cascade. The only change is that all of it is now driven by a `MultiPlan` covering one or more displays.

```swift
import AppKit
import MacTLMCore

/// Applies one or more MonitorLayouts as a single operation: hides non-members
/// (clear-stage), places running apps, launches missing ones and places them
/// after settle, then restores stacking order back-to-front across displays.
final class TemplateLauncher {
    private let driver: MacWindowDriver
    private unowned let coordinator: PersistenceCoordinator
    private let engine: RestoreEngine
    private var launchDeadline: DispatchWorkItem?

    init(driver: MacWindowDriver, coordinator: PersistenceCoordinator,
         engine: RestoreEngine) {
        self.driver = driver
        self.coordinator = coordinator
        self.engine = engine
    }

    /// Passing a single layout is the ordinary single-display launch; passing a
    /// bundle's layouts restores a whole multi-display workspace at once.
    func apply(_ layouts: [MonitorLayout], excludedBundleIDs: Set<String>) {
        guard !layouts.isEmpty else { return }
        if inFlight != nil {
            // A second apply supersedes the first; the old launches are dropped.
            launchDeadline?.cancel()
            launchDeadline = nil
            inFlight = nil
            NSLog("MacTLM: superseding an in-flight template launch")
        }
        var requests: [(layout: MonitorLayout, target: TemplateApplyPlanner.Target)] = []
        for layout in layouts {
            guard let target = resolveTarget(for: layout),
                  target.visibleArea.width > 0, target.visibleArea.height > 0
            else { continue }
            requests.append((layout, target))
        }
        guard !requests.isEmpty else { return }

        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
        let multi = MultiApplyPlanner.plan(requests: requests,
                                           runningBundleIDs: running,
                                           excludedBundleIDs: excludedBundleIDs)

        if multi.stageMode == .clearStage {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !multi.memberBundleIDs.contains(bundleID) else { continue }
                app.hide()
            }
        }

        // Place already-running members now, on whichever display owns them.
        for bundleID in multi.memberBundleIDs.intersection(running) {
            place(bundleID: bundleID, multi: multi)
        }

        // Launch missing members backmost-first; place each after its settle.
        var awaited = Set<String>()
        for bundleID in multi.appsToLaunch {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("MacTLM: no app found for %@", bundleID)
                continue
            }
            awaited.insert(bundleID)
            coordinator.armSettle(bundleID: bundleID) { [weak self] in
                self?.awaitedDidSettle(bundleID: bundleID, multi: multi)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        inFlight = InFlight(multi: multi, awaiting: awaited)

        if !awaited.isEmpty {
            // Anything not arrived in 15s: place what came, report the rest.
            let deadline = DispatchWorkItem { [weak self] in self?.reportMissing() }
            launchDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: deadline)
        } else {
            restoreStacking(multi: multi)
        }
    }

    // MARK: - Private

    /// The one apply currently waiting on launches: its merged plan, the apps
    /// still to arrive, and whether the launch deadline already reported them
    /// missing (we keep waiting so stragglers still get restacked).
    private struct InFlight {
        let multi: MultiApplyPlanner.MultiPlan
        var awaiting: Set<String>
        var reportedMissing: Bool = false
    }

    private var inFlight: InFlight?

    private func resolveTarget(for layout: MonitorLayout) -> TemplateApplyPlanner.Target? {
        let displays = ScreenGeometry.allDisplays
        if let own = displays.first(where: { $0.info.id == layout.displayID }) {
            return TemplateApplyPlanner.Target(info: own.info, visibleArea: own.visibleArea)
        }
        // Display missing: adapt onto the main display (PRD §3.2 Tier-1).
        guard let main = displays.first else { return nil }
        return TemplateApplyPlanner.Target(info: main.info, visibleArea: main.visibleArea)
    }

    /// Places one app's windows on every display that has placements for it.
    private func place(bundleID: String, multi: MultiApplyPlanner.MultiPlan) {
        for item in multi.items {
            let records = item.plan.matchingRecords(forBundleID: bundleID)
            guard !records.isEmpty else { continue }
            engine.restore(records: records, bundleID: bundleID,
                           visibleArea: item.visibleArea)
        }
    }

    private func awaitedDidSettle(bundleID: String,
                                  multi: MultiApplyPlanner.MultiPlan) {
        guard inFlight?.awaiting.contains(bundleID) == true else { return } // superseded
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return } // never launched — the deadline will report it
        inFlight?.awaiting.remove(bundleID)
        place(bundleID: bundleID, multi: multi)
        if inFlight?.reportedMissing == true {
            // A late arrival: re-run the cascade so it lands in its z position
            // instead of staying frontmost on top of the template.
            restoreStacking(multi: multi)
        } else if inFlight?.awaiting.isEmpty == true {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(multi: multi)
        }
    }

    private func reportMissing() {
        guard let flight = inFlight else { return }
        let missing = flight.awaiting.sorted()
        launchDeadline = nil
        guard !missing.isEmpty else {
            // Raced the deadline: everything arrived, finish normally.
            restoreStacking(multi: flight.multi)
            return
        }
        // Keep the flight alive: a slow launcher whose window shows up after
        // the deadline still needs placing and restacking.
        inFlight?.reportedMissing = true
        restoreStacking(multi: flight.multi)
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
        // Hard stop: stop waiting for stragglers two minutes after the report.
        let stop = DispatchWorkItem { [weak self] in self?.inFlight = nil }
        launchDeadline = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 120.0, execute: stop)
    }

    /// Restores stacking across apps and displays: activate member apps
    /// backmost-first (spaced so each activation lands), raising each app's own
    /// windows back-to-front as we go. The app owning the backmost window is
    /// activated first, so the frontmost one ends up on top.
    /// Excluded apps take part too — activation only, no frames touched.
    private func restoreStacking(multi: MultiApplyPlanner.MultiPlan) {
        // Done waiting, unless we're holding the flight open for late arrivals.
        if inFlight?.awaiting.isEmpty == true, inFlight?.reportedMissing == false {
            inFlight = nil
        }
        for (step, bundleID) in multi.appStackingOrder.enumerated() {
            let delay = Double(step) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.activateAndRaise(bundleID: bundleID, multi: multi)
            }
        }
    }

    /// Brings one member app forward, then raises its own windows
    /// backmost-first on each display so its internal order matches the layout.
    private func activateAndRaise(bundleID: String,
                                  multi: MultiApplyPlanner.MultiPlan) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where !app.isHidden {
            app.activate(options: [])
        }
        for item in multi.items {
            let records = item.plan.matchingRecords(forBundleID: bundleID)
            // Excluded app: it joins the cascade by activation alone, so we
            // never enumerate or raise its windows (PRD §9).
            guard !records.isEmpty else { continue }
            let windows = driver.windows(ofBundleID: bundleID)
            let candidates = windows.enumerated().map { index, window in
                WindowCandidate(id: window.id, title: window.title, order: index)
            }
            // Same count gate as placement, so raise order matches what was placed.
            let assignment = WindowMatcher.assign(
                records: records, to: candidates,
                allowOrderFallback: windows.count >= records.count)
            let placements = item.plan.placements.filter { $0.bundleID == bundleID }
            let backToFront = assignment
                .map { (windowID: $0.key,
                        zIndex: zIndex(ofSlot: $0.value.slot, in: placements)) }
                .sorted { $0.zIndex > $1.zIndex }
            for entry in backToFront {
                guard let handle = driver.handle(forWindowID: entry.windowID) else { continue }
                AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            }
        }
    }

    /// Template zIndex for a per-bundle slot; unknown slots raise first.
    private func zIndex(ofSlot slot: Int,
                        in placements: [TemplateApplyPlanner.Placement]) -> Int {
        slot < placements.count ? placements[slot].zIndex : Int.max
    }
}
```

- [ ] **Step 2: Update the coordinator**

```swift
    func applyLayout(_ layout: MonitorLayout) {
        templateLauncher.apply([layout], excludedBundleIDs: currentExcludedBundleIDs)
    }

    /// Launches every layout sharing this name — the whole workspace.
    func applyBundle(named name: String) {
        let layouts = layoutLibraryStore.load().layouts.filter { $0.name == name }
        guard !layouts.isEmpty else { return }
        templateLauncher.apply(layouts, excludedBundleIDs: currentExcludedBundleIDs)
    }
```

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 80 tests; bundle built. Behavior for a single-display launch must be unchanged (that is what `testSingleRequestMatchesSingleLayoutPlan` protects).

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM/TemplateLauncher.swift Sources/MacTLM/PersistenceCoordinator.swift
git commit -m "feat: apply layout sets as one operation"
```

---

### Task 5: LayoutShortcuts bridge

**Files:**
- Create: `Sources/MacTLM/LayoutShortcuts.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`

- [ ] **Step 1: Implement the bridge**

`Sources/MacTLM/LayoutShortcuts.swift`:
```swift
import AppKit
import KeyboardShortcuts
import MacTLMCore

/// Maps bundle names to global hotkeys. Shortcuts attach to the bundle NAME,
/// so one hotkey restores a whole workspace across every display (PRD §9).
/// KeyboardShortcuts persists each assignment in UserDefaults under its name.
enum LayoutShortcuts {
    /// Names must be stable across launches; the bundle name is the identity.
    static func name(forBundle bundleName: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("bundle-\(bundleName)")
    }

    /// (Re)registers key-up handlers for every bundle in the library.
    /// Safe to call repeatedly: handlers are cleared first.
    static func register(bundleNames: [String],
                         onTrigger: @escaping (String) -> Void) {
        KeyboardShortcuts.removeAllHandlers()
        for bundleName in bundleNames {
            KeyboardShortcuts.onKeyUp(for: name(forBundle: bundleName)) {
                onTrigger(bundleName)
            }
        }
    }

    /// Clears a bundle's assignment (used when a bundle is deleted).
    static func clear(bundleName: String) {
        KeyboardShortcuts.reset(name(forBundle: bundleName))
    }

    /// Moves an assignment when a bundle is renamed.
    static func migrate(from oldName: String, to newName: String) {
        let shortcut = KeyboardShortcuts.getShortcut(for: name(forBundle: oldName))
        KeyboardShortcuts.setShortcut(shortcut, for: name(forBundle: newName))
        KeyboardShortcuts.reset(name(forBundle: oldName))
    }

    static func shortcut(forBundle bundleName: String) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name(forBundle: bundleName))
    }
}
```

- [ ] **Step 2: Wire it into the coordinator**

In `PersistenceCoordinator`, add a method and call it from `start()` after the monitor is running:
```swift
    /// Re-reads the library and registers a hotkey handler per bundle.
    /// Call after any library mutation so new bundles become triggerable.
    func refreshShortcuts() {
        let names = layoutLibraryStore.load().bundles().map(\.name)
        LayoutShortcuts.register(bundleNames: names) { [weak self] bundleName in
            self?.applyBundle(named: bundleName)
        }
    }
```
Call `refreshShortcuts()` at the end of `start()`, and at the end of `saveCurrentArrangement(name:stageMode:)` and `deleteLayout(id:)`.

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 80 tests; bundle built.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM/LayoutShortcuts.swift Sources/MacTLM/PersistenceCoordinator.swift
git commit -m "feat: per-bundle global hotkeys"
```

---

### Task 6: Library mutation API for Preferences

Rename, delete, and stage-mode changes need to exist before the UI can call them.

**Files:**
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`
- Create: `Tests/MacTLMCoreTests/LayoutMutationTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutMutationTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutMutationTests: XCTestCase {
    private func layout(_ name: String, display: String,
                        stage: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: stage, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testRenameBundleRenamesEveryDisplaysLayout() {
        var library = LayoutLibrary(layouts: [
            layout("Old", display: "A"), layout("Old", display: "B"),
            layout("Other", display: "A"),
        ])
        library.renameBundle(from: "Old", to: "New")
        XCTAssertEqual(Set(library.layouts.map(\.name)), ["New", "Other"])
        XCTAssertEqual(library.layouts.filter { $0.name == "New" }.count, 2)
    }

    func testRenameToExistingNameMergesByReplacingCollisions() {
        var library = LayoutLibrary(layouts: [
            layout("Keep", display: "A"), layout("Rename", display: "A"),
        ])
        library.renameBundle(from: "Rename", to: "Keep")
        XCTAssertEqual(library.layouts.count, 1,
                       "same (name, displayID) collapses, newest wins")
        XCTAssertEqual(library.layouts[0].name, "Keep")
    }

    func testDeleteBundleRemovesEveryDisplaysLayout() {
        var library = LayoutLibrary(layouts: [
            layout("Gone", display: "A"), layout("Gone", display: "B"),
            layout("Stay", display: "A"),
        ])
        library.deleteBundle(named: "Gone")
        XCTAssertEqual(library.layouts.map(\.name), ["Stay"])
    }

    func testSetStageModeAppliesToWholeBundle() {
        var library = LayoutLibrary(layouts: [
            layout("W", display: "A"), layout("W", display: "B"),
        ])
        library.setStageMode(.clearStage, forBundleNamed: "W")
        XCTAssertTrue(library.layouts.allSatisfy { $0.stageMode == .clearStage })
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `renameBundle`.

- [ ] **Step 3: Implement**

Append to `Sources/MacTLMCore/LayoutModels.swift`:
```swift
public extension LayoutLibrary {
    /// Renames every layout in a bundle. If the new name collides on a display,
    /// the renamed layout wins (same rule as `upsert`).
    mutating func renameBundle(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        let renamed = layouts.filter { $0.name == oldName }.map { layout -> MonitorLayout in
            var copy = layout
            copy.name = newName
            return copy
        }
        guard !renamed.isEmpty else { return }
        layouts.removeAll { $0.name == oldName }
        upsert(renamed)
    }

    mutating func deleteBundle(named name: String) {
        layouts.removeAll { $0.name == name }
    }

    mutating func setStageMode(_ mode: StageMode, forBundleNamed name: String) {
        for index in layouts.indices where layouts[index].name == name {
            layouts[index].stageMode = mode
        }
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 84 total).

- [ ] **Step 5: Add coordinator wrappers**

```swift
    func renameBundle(from oldName: String, to newName: String) {
        var library = layoutLibraryStore.load()
        library.renameBundle(from: oldName, to: newName)
        try? layoutLibraryStore.save(library)
        LayoutShortcuts.migrate(from: oldName, to: newName)
        refreshShortcuts()
    }

    func deleteBundle(named name: String) {
        var library = layoutLibraryStore.load()
        library.deleteBundle(named: name)
        try? layoutLibraryStore.save(library)
        LayoutShortcuts.clear(bundleName: name)
        refreshShortcuts()
    }

    func setStageMode(_ mode: StageMode, forBundleNamed name: String) {
        var library = layoutLibraryStore.load()
        library.setStageMode(mode, forBundleNamed: name)
        try? layoutLibraryStore.save(library)
    }

    func loadBundles() -> [LayoutBundle] {
        layoutLibraryStore.load().bundles()
    }
```
Delete the now-unused `deleteLayout(id:)`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacTLMCore/LayoutModels.swift Sources/MacTLM/PersistenceCoordinator.swift Tests/MacTLMCoreTests/LayoutMutationTests.swift
git commit -m "feat: rename, delete, and stage-mode bundle mutations"
```

---

### Task 7: Preferences window (SwiftUI Layouts tab)

**Files:**
- Create: `Sources/MacTLM/PreferencesWindowController.swift`
- Create: `Sources/MacTLM/LayoutsPreferencesView.swift`
- Modify: `Sources/MacTLM/StatusMenuController.swift`

- [ ] **Step 1: Write the SwiftUI view**

`Sources/MacTLM/LayoutsPreferencesView.swift`:
```swift
import SwiftUI
import KeyboardShortcuts
import MacTLMCore

/// One row per saved workspace: hotkey recorder, stage toggle, rename, delete.
struct LayoutsPreferencesView: View {
    @ObservedObject var model: LayoutsPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.bundles.isEmpty {
                Text("No layouts saved yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.bundles, id: \.name) { bundle in
                    LayoutRow(bundle: bundle, model: model)
                }
                .listStyle(.inset)
            }
            Text("Displays: a layout is saved per monitor. One hotkey restores "
                 + "every display in the workspace.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { model.reload() }
    }
}

private struct LayoutRow: View {
    let bundle: LayoutBundle
    @ObservedObject var model: LayoutsPreferencesModel
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $draftName, onCommit: commitRename)
                        .frame(width: 180)
                } else {
                    Text(bundle.name).fontWeight(.medium)
                }
                Text(displaySummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Hide others", isOn: Binding(
                get: { bundle.layouts.first?.stageMode == .clearStage },
                set: { model.setClearStage($0, for: bundle.name) }))
                .toggleStyle(.checkbox)
            KeyboardShortcuts.Recorder("", name: LayoutShortcuts.name(forBundle: bundle.name))
            Button(isRenaming ? "Save" : "Rename") {
                if isRenaming { commitRename() } else {
                    draftName = bundle.name
                    isRenaming = true
                }
            }
            Button("Delete") { model.delete(bundleName: bundle.name) }
        }
        .padding(.vertical, 4)
    }

    private var displaySummary: String {
        let displays = bundle.layouts.map(\.displayName).joined(separator: ", ")
        let windows = bundle.layouts.reduce(0) { $0 + $1.entries.count }
        return "\(windows) windows · \(displays)"
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != bundle.name else { return }
        model.rename(from: bundle.name, to: trimmed)
    }
}

/// Bridges the AppKit coordinator to SwiftUI.
final class LayoutsPreferencesModel: ObservableObject {
    @Published var bundles: [LayoutBundle] = []
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        reload()
    }

    func reload() { bundles = coordinator.loadBundles() }

    func rename(from oldName: String, to newName: String) {
        coordinator.renameBundle(from: oldName, to: newName)
        reload()
    }

    func delete(bundleName: String) {
        coordinator.deleteBundle(named: bundleName)
        reload()
    }

    func setClearStage(_ on: Bool, for bundleName: String) {
        coordinator.setStageMode(on ? .clearStage : .leaveOthers,
                                 forBundleNamed: bundleName)
        reload()
    }
}
```

- [ ] **Step 2: Host it in a window**

`Sources/MacTLM/PreferencesWindowController.swift`:
```swift
import AppKit
import SwiftUI

/// Single reusable Preferences window. The app is an accessory (no Dock icon),
/// so it activates itself before showing the window.
final class PreferencesWindowController {
    private var window: NSWindow?
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = LayoutsPreferencesModel(coordinator: coordinator)
        let hosting = NSHostingController(rootView: LayoutsPreferencesView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacTLM Layouts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 3: Add the menu item**

In `StatusMenuController`: hold `private lazy var preferences = PreferencesWindowController(coordinator: coordinator)`, and in `menuNeedsUpdate` insert before the Quit separator:
```swift
        menu.addItem(actionItem("Layouts…", #selector(showPreferences)))
```
with:
```swift
    @objc private func showPreferences() { preferences.show() }
```

- [ ] **Step 4: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 84 tests; bundle built. Do not launch the app — Task 9 covers live checks.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLM/LayoutsPreferencesView.swift Sources/MacTLM/PreferencesWindowController.swift Sources/MacTLM/StatusMenuController.swift
git commit -m "feat: Layouts preferences window with hotkey recorders"
```

---

### Task 8: Menu shows bundles and their hotkeys

**Files:**
- Modify: `Sources/MacTLM/StatusMenuController.swift`
- Modify: `docs/BACKLOG.md`

- [ ] **Step 1: Add a bundles section**

In `menuNeedsUpdate`, above the per-display sections, add a section listing every bundle that spans multiple displays, plus shortcut display on all layout rows:
```swift
        let library = coordinator.layoutLibraryStore.load()
        let bundles = library.bundles()

        let multiDisplay = bundles.filter(\.spansMultipleDisplays)
        if !multiDisplay.isEmpty {
            menu.addItem(sectionHeader("Workspaces (all displays)"))
            for bundle in multiDisplay {
                let item = NSMenuItem(title: bundle.name,
                                      action: #selector(launchBundle(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = bundle.name as NSString
                if let shortcut = LayoutShortcuts.shortcut(forBundle: bundle.name) {
                    item.setShortcut(shortcut)
                }
                menu.addItem(item)
            }
        }
```
and the action:
```swift
    @objc private func launchBundle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        coordinator.applyBundle(named: name)
    }
```
In `layoutItem(_:indent:)`, also attach the shortcut when the layout's bundle has one AND the bundle is single-display (so a single-display workspace shows its hotkey on its only row):
```swift
        if let shortcut = LayoutShortcuts.shortcut(forBundle: layout.name) {
            item.setShortcut(shortcut)
        }
```
`setShortcut` comes from KeyboardShortcuts' `NSMenuItem` extension — import KeyboardShortcuts in this file.

- [ ] **Step 2: Record the multi-display residual**

Append to the "Accepted residuals" table in `docs/BACKLOG.md`:
```markdown
| One app with windows on two displays in a bundle | A window can be claimed by the wrong display's records | Each display's records are matched against all of that app's windows. Single-display setups are unaffected. Fix needs per-app merged placement with absolute target rects; deferred until there is a two-monitor setup to test against |
```

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 84 tests; bundle built.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM/StatusMenuController.swift docs/BACKLOG.md
git commit -m "feat: workspace bundle menu entries with hotkey display"
```

---

### Task 9: Live acceptance (user at keyboard)

- [ ] **Step 1:** Install the new build as the daily driver:
```bash
./scripts/install.sh
```
Confirm the menu-bar icon returns and `--login-status` still reports `enabled`.

- [ ] **Step 2:** Menu → **Layouts…**. The window lists `Design&Comms`, `SmokeScene`, `StageTest` with window counts and display names. Delete `SmokeScene` and `StageTest` here; confirm they vanish from the menu too.

- [ ] **Step 3:** In the Layouts window, record a hotkey for `Design&Comms` (e.g. ⌘⌥1). Confirm the menu row now shows that shortcut next to the layout name.

- [ ] **Step 4 (the PRD §9 acceptance, hotkey variant):** scramble several windows, then press the hotkey. Everything returns to place with correct stacking, without touching the menu.

- [ ] **Step 5:** Rename `Design&Comms` to `Design + Comms` in the Layouts window. Confirm: the menu shows the new name, the hotkey still triggers it (migration worked), and `layouts.json` has no leftover old-name entries.

- [ ] **Step 6:** Toggle "Hide others" off for the layout; launch it; confirm non-member apps are no longer hidden. Toggle back on if preferred.

- [ ] **Step 7:** Quit the layout's apps, then press the hotkey from a cold state. This also exercises the still-unverified late-arrival restacking (a slow app appearing after the 15s deadline must be pushed to its z-position rather than staying on top).

- [ ] **Step 8:** Tag:
```bash
git tag -a v0.3.0-m2b -m "M2b: bundles, per-bundle hotkeys, Layouts preferences"
```

---

## Plan self-review notes

- **Spec coverage:** PRD §3.2 bundles ✓ (T2, T4, T8), PRD §9 "one hotkey from a clean login" ✓ (T5, T9 steps 4 and 7), PRD §4 Preferences Layouts tab ✓ (T7) including rename/delete/stage-mode which were JSON-only before. Deferred to M2c: Apps tab (exclude list, pin rules), which PRD §4 also lists.
- **Regression guard:** `testSingleRequestMatchesSingleLayoutPlan` pins multi-apply to produce byte-identical results to the existing single-layout path, so Task 4 cannot silently change today's working behavior.
- **Type consistency:** `LayoutBundle`/`bundles()` (T2) consumed by T5, T6, T7, T8; `MultiApplyPlanner.plan(requests:runningBundleIDs:excludedBundleIDs:)` (T3) consumed by T4; `LayoutShortcuts.name(forBundle:)` (T5) consumed by T7's Recorder and T8's `setShortcut`; coordinator's `loadBundles`/`renameBundle`/`deleteBundle`/`setStageMode` (T6) consumed by T7's model.
- **Dependency risk:** KeyboardShortcuts 3.0.1 is pinned as the floor specifically because it fixes a release-build crash under Swift 6.3; `swift build -c release` is verified in Task 1 rather than only at install time.
- **Deliberate omission:** no unit tests for the SwiftUI view or the window controller — no headless surface. They are covered by Task 9's live protocol, consistent with how the AppKit layer has been treated since M1.

---

### Task 10 (amendment, added mid-execution): Archive instead of delete

Requested after Task 9 began: deleting a workspace was one irreversible click. Layouts are now **archived** (reversible, greyed out, hidden from the menu) and can only be permanently deleted from the archive, behind a confirmation.

**Archiving preserves the recorded hotkey** — the assignment lives in `UserDefaults` under the bundle name, and archiving merely stops registering a handler for it. Restoring re-registers the same shortcut.

**Files:**
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`
- Modify: `Sources/MacTLM/LayoutsPreferencesView.swift`
- Modify: `Sources/MacTLM/StatusMenuController.swift`
- Create: `Tests/MacTLMCoreTests/LayoutArchiveTests.swift`

#### CRITICAL: JSON backward compatibility

The user's live `layouts.json` has no archive key, and `LayoutLibraryStore.load()` is fail-soft — a decode failure silently yields an EMPTY library, and the next save would overwrite their real workspace with nothing. `archivedBundleNames` MUST therefore decode as absent-tolerant, and the test below MUST exist.

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutArchiveTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutArchiveTests: XCTestCase {
    private func layout(_ name: String, display: String = "A") -> MonitorLayout {
        MonitorLayout(id: UUID(), name: name, displayID: display,
                      displayName: "D\(display)",
                      displayMetrics: DisplayInfo(id: display, width: 1600,
                                                  height: 1000, scale: 2.0),
                      stageMode: .leaveOthers, entries: [],
                      createdAt: Date(timeIntervalSince1970: 0))
    }

    func testLegacyJSONWithoutArchiveKeyStillDecodes() throws {
        // Exactly the shape written before this task existed.
        let json = """
        {"layouts":[{"createdAt":"2026-08-19T00:00:00Z","displayID":"A",
        "displayMetrics":{"height":1000,"id":"A","scale":2,"width":1600},
        "displayName":"DA","entries":[],"id":"AAAAAAAA-0000-0000-0000-000000000001",
        "name":"Design&Comms","stageMode":"leaveOthers"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(LayoutLibrary.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(library.layouts.count, 1, "legacy file must not decode as empty")
        XCTAssertTrue(library.archivedBundleNames.isEmpty)
    }

    func testArchiveHidesFromActiveButKeepsLayout() {
        var library = LayoutLibrary(layouts: [layout("Work"), layout("Play")])
        library.archiveBundle(named: "Play")
        XCTAssertEqual(library.activeBundles().map(\.name), ["Work"])
        XCTAssertEqual(library.archivedBundles().map(\.name), ["Play"])
        XCTAssertEqual(library.layouts.count, 2, "archiving must not drop layouts")
    }

    func testRestoreBringsItBack() {
        var library = LayoutLibrary(layouts: [layout("Play")])
        library.archiveBundle(named: "Play")
        library.restoreBundle(named: "Play")
        XCTAssertEqual(library.activeBundles().map(\.name), ["Play"])
        XCTAssertTrue(library.archivedBundleNames.isEmpty)
    }

    func testDeleteBundleRemovesLayoutsAndArchiveEntry() {
        var library = LayoutLibrary(layouts: [layout("Play", display: "A"),
                                              layout("Play", display: "B")])
        library.archiveBundle(named: "Play")
        library.deleteBundle(named: "Play")
        XCTAssertTrue(library.layouts.isEmpty)
        XCTAssertTrue(library.archivedBundleNames.isEmpty,
                      "no orphan archive entry left behind")
    }

    func testSavingOverAnArchivedNameReactivatesIt() {
        var library = LayoutLibrary(layouts: [layout("Work")])
        library.archiveBundle(named: "Work")
        library.upsert([layout("Work")])
        XCTAssertEqual(library.activeBundles().map(\.name), ["Work"],
                       "re-saving an archived name brings it back")
    }

    func testArchiveRoundTripsThroughJSON() throws {
        var library = LayoutLibrary(layouts: [layout("Work")])
        library.archiveBundle(named: "Work")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LayoutLibrary.self,
                                         from: try encoder.encode(library))
        XCTAssertEqual(decoded.archivedBundleNames, ["Work"])
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `archivedBundleNames`.

- [ ] **Step 3: Implement in Core**

In `Sources/MacTLMCore/LayoutModels.swift`, extend `LayoutLibrary` with the archive set and absent-tolerant decoding:
```swift
public struct LayoutLibrary: Codable, Equatable {
    public var layouts: [MonitorLayout]
    /// Bundle names hidden from the menu and from hotkey registration.
    /// Archiving is reversible; only the archive can permanently delete.
    public var archivedBundleNames: Set<String>

    public init(layouts: [MonitorLayout] = [],
                archivedBundleNames: Set<String> = []) {
        self.layouts = layouts
        self.archivedBundleNames = archivedBundleNames
    }

    private enum CodingKeys: String, CodingKey {
        case layouts, archivedBundleNames
    }

    /// Absent-tolerant: files written before archiving existed have no
    /// `archivedBundleNames` key and MUST still decode (a failure here would
    /// make the fail-soft store load an empty library and lose real layouts).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try container.decodeIfPresent([MonitorLayout].self,
                                                forKey: .layouts) ?? []
        archivedBundleNames = try container.decodeIfPresent(
            Set<String>.self, forKey: .archivedBundleNames) ?? []
    }
}
```
Add the mutations and accessors:
```swift
public extension LayoutLibrary {
    /// Active (non-archived) bundles, and archived ones, both name-sorted.
    func activeBundles() -> [LayoutBundle] {
        bundles().filter { !archivedBundleNames.contains($0.name) }
    }

    func archivedBundles() -> [LayoutBundle] {
        bundles().filter { archivedBundleNames.contains($0.name) }
    }

    mutating func archiveBundle(named name: String) {
        guard layouts.contains(where: { $0.name == name }) else { return }
        archivedBundleNames.insert(name)
    }

    mutating func restoreBundle(named name: String) {
        archivedBundleNames.remove(name)
    }
}
```
Then: `deleteBundle(named:)` must also `archivedBundleNames.remove(name)`, `renameBundle(from:to:)` must carry an archived flag across the rename, and `upsert(_:)` must remove incoming names from `archivedBundleNames` (re-saving reactivates).

- [ ] **Step 4: Run `swift test`** — PASS (6 new; 90 total).

- [ ] **Step 5: Coordinator, menu, and hotkeys respect the archive**

- `PersistenceCoordinator`: add `archiveBundle(named:)` and `restoreBundle(named:)` (save, then `refreshShortcuts()`); keep `deleteBundle(named:)` as the permanent delete (it already clears the shortcut).
- `refreshShortcuts()` registers from `activeBundles()` only, so an archived workspace's hotkey stops firing while archived and works again after restore.
- `loadBundles()` returns active bundles; add `loadArchivedBundles()`.
- `StatusMenuController.menuNeedsUpdate` uses active bundles for both the Workspaces section and the per-display sections, so archived layouts vanish from the menu.

- [ ] **Step 6: Preferences UI**

In `LayoutsPreferencesView`: two `Section`s — "Layouts" (active) and "Archived" (only when non-empty). Active rows keep Rename plus a new **Archive** button (no confirmation — it is reversible). Archived rows are greyed (`.foregroundStyle(.secondary)`), hide the recorder and stage toggle, and offer **Restore** and **Delete Permanently**. Only Delete Permanently confirms, via an `NSAlert` (or `.confirmationDialog`) whose default button is Cancel:

> Delete "<name>" permanently? · This removes the saved window positions for every display in this workspace. This cannot be undone.

The model gains `archivedBundles`, `archive(bundleName:)`, `restore(bundleName:)`, and `deletePermanently(bundleName:)`, each reloading afterwards.

- [ ] **Step 7: Verify and commit**

`swift build` clean, `swift test` 90 passing, `./scripts/make-app.sh` succeeds.
```bash
git add -A Sources Tests docs
git commit -m "feat: archive layouts instead of deleting, delete only from archive"
```
