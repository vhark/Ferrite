# M2a — Workspace Templates: Engine + Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save the current window arrangement as a named layout and launch it from the menu bar — adopting running apps, launching missing ones, restoring frames and cross-app stacking order, with per-template stage modes and adaptive launch onto a different display.

**Architecture:** Pure planning logic in `MacTLMCore` (models, library store, snapshot planner, apply planner, z-order matcher — all TDD). macOS integration in `MacTLM` (CGWindowList z-order capture, snapshot builder, template launcher wired through the coordinator's settle machinery, dynamic menu). M2b (not this plan): bundles, hotkeys, Layouts prefs tab.

**Tech Stack:** Swift 5.9 mode, XCTest, AppKit, CoreGraphics (CGWindowList), UserNotifications. No new dependencies.

**Scope boundaries:** `optional` and `pinPattern` entry flags are honored but JSON-edit-only (no UI — M1 pin precedent). Excluded apps (e.g. Illustrator) are launched but never placed (PRD §9). Single-display use is the degenerate case of per-display decomposition; bundle linking of multi-display saves is M2b.

**Z-order convention (whole plan):** `zIndex 0 = frontmost`, larger = further back (CGWindowList's natural order). Restore raises backmost-first so the frontmost window is raised last.

**Spec:** PRD §3.2, §4, §7, §9 in `docs/superpowers/specs/2026-08-19-mactlm-prd-design.md`.

---

### Task 1: Layout models and LayoutLibraryStore

**Files:**
- Create: `Sources/MacTLMCore/LayoutModels.swift`
- Create: `Sources/MacTLMCore/LayoutLibraryStore.swift`
- Create: `Tests/MacTLMCoreTests/LayoutLibraryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutLibraryStoreTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutLibraryStoreTests: XCTestCase {
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func sampleLayout() -> MonitorLayout {
        MonitorLayout(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            name: "Design + Comms",
            displayID: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            displayName: "Built-in Retina Display",
            displayMetrics: DisplayInfo(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                                        width: 1600, height: 1000, scale: 2.0),
            stageMode: .leaveOthers,
            entries: [
                LayoutEntry(bundleID: "company.thebrowser.Browser", title: "Work",
                            frame: NormalizedFrame(x: 0.22, y: 0.05, w: 0.25, h: 0.90),
                            zIndex: 1, pinPattern: nil, optional: false),
                LayoutEntry(bundleID: "sh.paseo.desktop", title: "Paseo",
                            frame: NormalizedFrame(x: 0.48, y: 0.20, w: 0.25, h: 0.60),
                            zIndex: 0, pinPattern: nil, optional: true),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLoadMissingFileReturnsEmptyLibrary() {
        XCTAssertEqual(LayoutLibraryStore(url: url).load(), LayoutLibrary())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = LayoutLibraryStore(url: url)
        let library = LayoutLibrary(layouts: [sampleLayout()])
        try store.save(library)
        XCTAssertEqual(store.load(), library)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        try Data("nope{".utf8).write(to: url)
        XCTAssertEqual(LayoutLibraryStore(url: url).load(), LayoutLibrary())
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'MonitorLayout' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/LayoutModels.swift`:
```swift
import Foundation

/// What happens to windows NOT in the layout when it launches (PRD §3.2).
public enum StageMode: String, Codable, Equatable {
    case leaveOthers   // template only places its own apps
    case clearStage    // non-members get hidden
}

/// One window slot in a saved layout. zIndex 0 = frontmost.
public struct LayoutEntry: Codable, Equatable {
    public var bundleID: String
    public var title: String          // snapshot title, improves adopt matching
    public var frame: NormalizedFrame
    public var zIndex: Int
    public var pinPattern: String?    // JSON-editable, like WindowRecord pins
    public var optional: Bool         // skipped when adapting to a smaller display

    public init(bundleID: String, title: String, frame: NormalizedFrame,
                zIndex: Int, pinPattern: String?, optional: Bool) {
        self.bundleID = bundleID; self.title = title; self.frame = frame
        self.zIndex = zIndex; self.pinPattern = pinPattern; self.optional = optional
    }
}

/// A saved arrangement for ONE display (PRD §4: templates decompose per monitor).
public struct MonitorLayout: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var displayID: String        // display UUID at capture time
    public var displayName: String      // human name for menu sections
    public var displayMetrics: DisplayInfo
    public var stageMode: StageMode
    public var entries: [LayoutEntry]
    public var createdAt: Date

    public init(id: UUID, name: String, displayID: String, displayName: String,
                displayMetrics: DisplayInfo, stageMode: StageMode,
                entries: [LayoutEntry], createdAt: Date) {
        self.id = id; self.name = name; self.displayID = displayID
        self.displayName = displayName; self.displayMetrics = displayMetrics
        self.stageMode = stageMode; self.entries = entries; self.createdAt = createdAt
    }
}

/// Every saved layout. Bundles (multi-display linking) arrive in M2b.
public struct LayoutLibrary: Codable, Equatable {
    public var layouts: [MonitorLayout]

    public init(layouts: [MonitorLayout] = []) {
        self.layouts = layouts
    }
}
```

`Sources/MacTLMCore/LayoutLibraryStore.swift`:
```swift
import Foundation

/// JSON persistence for the layout library at a single file URL.
/// Same posture as LayoutStore: fail-soft load, atomic deterministic save.
public final class LayoutLibraryStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> LayoutLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? decoder.decode(LayoutLibrary.self, from: data)
        else { return LayoutLibrary() }
        return library
    }

    public func save(_ library: LayoutLibrary) throws {
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (3 new; 43 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/LayoutModels.swift Sources/MacTLMCore/LayoutLibraryStore.swift Tests/MacTLMCoreTests/LayoutLibraryStoreTests.swift
git commit -m "feat: layout models and library store"
```

---

### Task 2: ZOrderMatcher

Pure matching of CGWindowList entries (pid + frame, front-to-back) to AX windows (id + pid + frame). Runs in Core so it's testable; the CGWindowList call itself is mac-side (Task 6).

**Files:**
- Create: `Sources/MacTLMCore/ZOrderMatcher.swift`
- Create: `Tests/MacTLMCoreTests/ZOrderMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/ZOrderMatcherTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class ZOrderMatcherTests: XCTestCase {
    func testAssignsFrontToBackIndices() {
        let ax = [
            ZOrderMatcher.AXRef(id: 10, pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            ZOrderMatcher.AXRef(id: 11, pid: 200, frame: CGRect(x: 50, y: 50, width: 400, height: 300)),
        ]
        let cg = [ // front-to-back
            ZOrderMatcher.CGRef(pid: 200, frame: CGRect(x: 50, y: 50, width: 400, height: 300)),
            ZOrderMatcher.CGRef(pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
        ]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(z[11], 0, "pid 200 window is frontmost")
        XCTAssertEqual(z[10], 1)
    }

    func testToleratesSmallFrameDrift() {
        let ax = [ZOrderMatcher.AXRef(id: 10, pid: 100,
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        let cg = [ZOrderMatcher.CGRef(pid: 100,
                                      frame: CGRect(x: 1.5, y: -1.0, width: 401, height: 299))]
        XCTAssertEqual(ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)[10], 0)
    }

    func testUnmatchedWindowsGetBackAppendedIndices() {
        let ax = [
            ZOrderMatcher.AXRef(id: 10, pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            ZOrderMatcher.AXRef(id: 11, pid: 100, frame: CGRect(x: 900, y: 900, width: 100, height: 100)),
        ]
        let cg = [ZOrderMatcher.CGRef(pid: 100, frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(z[10], 0)
        XCTAssertEqual(z[11], 1, "unmatched window appended behind matched ones")
    }

    func testSameFrameSamePidWindowsConsumeCGEntriesInOrder() {
        // Two identical windows (same pid, same frame): each CG entry may claim
        // only one AX window and vice versa.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ax = [ZOrderMatcher.AXRef(id: 10, pid: 100, frame: frame),
                  ZOrderMatcher.AXRef(id: 11, pid: 100, frame: frame)]
        let cg = [ZOrderMatcher.CGRef(pid: 100, frame: frame),
                  ZOrderMatcher.CGRef(pid: 100, frame: frame)]
        let z = ZOrderMatcher.zIndices(axWindows: ax, cgFrontToBack: cg)
        XCTAssertEqual(Set(z.values), [0, 1])
        XCTAssertEqual(z.count, 2)
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'ZOrderMatcher' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/ZOrderMatcher.swift`:
```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Matches AX-enumerated windows to CGWindowList entries (front-to-back) to
/// recover global stacking order. zIndex 0 = frontmost.
public enum ZOrderMatcher {
    public struct AXRef {
        public let id: Int
        public let pid: Int32
        public let frame: CGRect
        public init(id: Int, pid: Int32, frame: CGRect) {
            self.id = id; self.pid = pid; self.frame = frame
        }
    }

    public struct CGRef {
        public let pid: Int32
        public let frame: CGRect
        public init(pid: Int32, frame: CGRect) {
            self.pid = pid; self.frame = frame
        }
    }

    public static let tolerance: CGFloat = 3.0

    /// Returns AX window id → zIndex. Unmatched AX windows are appended
    /// behind all matched ones, preserving their input order.
    public static func zIndices(axWindows: [AXRef],
                                cgFrontToBack: [CGRef]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var claimedAX = Set<Int>()
        var nextIndex = 0
        for cg in cgFrontToBack {
            guard let match = axWindows.first(where: { ax in
                !claimedAX.contains(ax.id) && ax.pid == cg.pid
                    && ax.frame.approximatelyEquals(cg.frame, tolerance: Self.tolerance)
            }) else { continue }
            claimedAX.insert(match.id)
            result[match.id] = nextIndex
            nextIndex += 1
        }
        for ax in axWindows where !claimedAX.contains(ax.id) {
            result[ax.id] = nextIndex
            nextIndex += 1
        }
        return result
    }
}
```
Note: `approximatelyEquals` already exists as an internal CGRect extension in `RestoreEngine.swift` — same module, reuse it.

- [ ] **Step 4: Run `swift test`** — PASS (4 new; 47 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/ZOrderMatcher.swift Tests/MacTLMCoreTests/ZOrderMatcherTests.swift
git commit -m "feat: ZOrderMatcher for global stacking capture"
```

---

### Task 3: SnapshotPlanner

Pure function: captured windows + displays → per-display `MonitorLayout`s.

**Files:**
- Create: `Sources/MacTLMCore/SnapshotPlanner.swift`
- Create: `Tests/MacTLMCoreTests/SnapshotPlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/SnapshotPlannerTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class SnapshotPlannerTests: XCTestCase {
    let laptop = SnapshotPlanner.Display(
        info: DisplayInfo(id: "LAPTOP", width: 1600, height: 1000, scale: 2.0),
        name: "Built-in", visibleArea: CGRect(x: 0, y: 25, width: 1600, height: 975))
    let external = SnapshotPlanner.Display(
        info: DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0),
        name: "UltraWide", visibleArea: CGRect(x: 1600, y: 0, width: 3440, height: 1440))

    private func window(_ bundleID: String, x: CGFloat, y: CGFloat,
                        w: CGFloat = 400, h: CGFloat = 300, z: Int,
                        title: String = "") -> SnapshotPlanner.Window {
        SnapshotPlanner.Window(bundleID: bundleID, title: title,
                               frame: CGRect(x: x, y: y, width: w, height: h), zIndex: z)
    }

    func testAssignsWindowsToDisplayContainingCenter() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 100, y: 100, z: 0),
                      window("b", x: 2000, y: 100, z: 1)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 2)
        let laptopLayout = layouts.first { $0.displayID == "LAPTOP" }!
        let extLayout = layouts.first { $0.displayID == "EXT" }!
        XCTAssertEqual(laptopLayout.entries.map(\.bundleID), ["a"])
        XCTAssertEqual(extLayout.entries.map(\.bundleID), ["b"])
    }

    func testNormalizesFramesAgainstOwnDisplay() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 400, y: 268.75, w: 400, h: 487.5, z: 0)],
            displays: [laptop], date: Date(timeIntervalSince1970: 0))
        let entry = layouts[0].entries[0]
        XCTAssertEqual(entry.frame.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.w, 0.25, accuracy: 0.001)
        XCTAssertEqual(entry.frame.h, 0.5, accuracy: 0.001)
    }

    func testReindexesZPerDisplayPreservingOrder() {
        // Global z: b(0, ext), a(1, laptop), c(2, laptop)
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("b", x: 2000, y: 100, z: 0),
                      window("a", x: 100, y: 100, z: 1),
                      window("c", x: 200, y: 200, z: 2)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        let laptopLayout = layouts.first { $0.displayID == "LAPTOP" }!
        XCTAssertEqual(laptopLayout.entries.map(\.bundleID), ["a", "c"])
        XCTAssertEqual(laptopLayout.entries.map(\.zIndex), [0, 1],
                       "per-display z reindexed from 0 preserving global order")
    }

    func testOffscreenWindowFallsBackToNearestDisplay() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: -5000, y: -5000, z: 0)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0].displayID, "LAPTOP")
    }

    func testDisplaysWithoutWindowsProduceNoLayout() {
        let layouts = SnapshotPlanner.plan(
            name: "Test", stageMode: .leaveOthers,
            windows: [window("a", x: 100, y: 100, z: 0)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(layouts.count, 1)
    }

    func testAllLayoutsShareNameAndStageMode() {
        let layouts = SnapshotPlanner.plan(
            name: "Design + Comms", stageMode: .clearStage,
            windows: [window("a", x: 100, y: 100, z: 0),
                      window("b", x: 2000, y: 100, z: 1)],
            displays: [laptop, external], date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(layouts.allSatisfy { $0.name == "Design + Comms" })
        XCTAssertTrue(layouts.allSatisfy { $0.stageMode == .clearStage })
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'SnapshotPlanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/SnapshotPlanner.swift`:
```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns a captured set of windows into per-display MonitorLayouts (PRD §3.2).
public enum SnapshotPlanner {
    public struct Window {
        public let bundleID: String
        public let title: String
        public let frame: CGRect   // CG space
        public let zIndex: Int     // global, 0 = frontmost
        public init(bundleID: String, title: String, frame: CGRect, zIndex: Int) {
            self.bundleID = bundleID; self.title = title
            self.frame = frame; self.zIndex = zIndex
        }
    }

    public struct Display {
        public let info: DisplayInfo
        public let name: String
        public let visibleArea: CGRect  // CG space
        public init(info: DisplayInfo, name: String, visibleArea: CGRect) {
            self.info = info; self.name = name; self.visibleArea = visibleArea
        }
    }

    public static func plan(name: String, stageMode: StageMode,
                            windows: [Window], displays: [Display],
                            date: Date) -> [MonitorLayout] {
        guard !displays.isEmpty else { return [] }
        var byDisplay: [String: [Window]] = [:]
        for window in windows {
            let display = assign(window: window, displays: displays)
            byDisplay[display.info.id, default: []].append(window)
        }
        return displays.compactMap { display in
            guard let assigned = byDisplay[display.info.id], !assigned.isEmpty
            else { return nil }
            let ordered = assigned.sorted { $0.zIndex < $1.zIndex }
            let entries = ordered.enumerated().map { index, window in
                LayoutEntry(bundleID: window.bundleID,
                            title: window.title,
                            frame: NormalizedFrame(windowFrame: window.frame,
                                                   visibleArea: display.visibleArea),
                            zIndex: index,
                            pinPattern: nil,
                            optional: false)
            }
            return MonitorLayout(id: UUID(), name: name,
                                 displayID: display.info.id,
                                 displayName: display.name,
                                 displayMetrics: display.info,
                                 stageMode: stageMode,
                                 entries: entries,
                                 createdAt: date)
        }
    }

    private static func assign(window: Window, displays: [Display]) -> Display {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        if let containing = displays.first(where: { $0.visibleArea.contains(center) }) {
            return containing
        }
        // Off-screen fallback: nearest display center.
        return displays.min { a, b in
            distanceSquared(center, to: a.visibleArea) < distanceSquared(center, to: b.visibleArea)
        }!
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (6 new; 53 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/SnapshotPlanner.swift Tests/MacTLMCoreTests/SnapshotPlannerTests.swift
git commit -m "feat: SnapshotPlanner per-display layout capture"
```

---

### Task 4: TemplateApplyPlanner

Pure function: layout + world state → apply plan (who to launch, what to place where, what to hide, which optionals to skip).

**Files:**
- Create: `Sources/MacTLMCore/TemplateApplyPlanner.swift`
- Create: `Tests/MacTLMCoreTests/TemplateApplyPlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/TemplateApplyPlannerTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class TemplateApplyPlannerTests: XCTestCase {
    let capturedMetrics = DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0)
    let sameTarget = TemplateApplyPlanner.Target(
        info: DisplayInfo(id: "EXT", width: 3440, height: 1440, scale: 1.0),
        visibleArea: CGRect(x: 0, y: 0, width: 3440, height: 1415))
    let laptopTarget = TemplateApplyPlanner.Target(
        info: DisplayInfo(id: "LAPTOP", width: 1600, height: 1000, scale: 2.0),
        visibleArea: CGRect(x: 0, y: 25, width: 1600, height: 975))

    private func layout(entries: [LayoutEntry],
                        stageMode: StageMode = .leaveOthers) -> MonitorLayout {
        MonitorLayout(id: UUID(), name: "T", displayID: "EXT", displayName: "UltraWide",
                      displayMetrics: capturedMetrics, stageMode: stageMode,
                      entries: entries, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, optional: Bool = false,
                       z: Int = 0, title: String = "") -> LayoutEntry {
        LayoutEntry(bundleID: bundleID, title: title,
                    frame: NormalizedFrame(x: 0.25, y: 0.0, w: 0.5, h: 0.9),
                    zIndex: z, pinPattern: nil, optional: optional)
    }

    func testPartitionsRunningVsMissing() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("running.app"), entry("missing.app", z: 1)]),
            runningBundleIDs: ["running.app"], excludedBundleIDs: [],
            target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["missing.app"])
        XCTAssertEqual(Set(plan.placements.map(\.bundleID)), ["running.app", "missing.app"])
    }

    func testComputesTargetRects() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("a")]),
            runningBundleIDs: ["a"], excludedBundleIDs: [], target: sameTarget)
        let rect = plan.placements[0].targetRect
        XCTAssertEqual(rect.minX, 860, accuracy: 0.001)   // 0.25 * 3440
        XCTAssertEqual(rect.width, 1720, accuracy: 0.001) // 0.5 * 3440
        XCTAssertEqual(rect.height, 1273.5, accuracy: 0.001) // 0.9 * 1415
    }

    func testExcludedAppsAreLaunchedButNotPlaced() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("com.adobe.illustrator")]),
            runningBundleIDs: [], excludedBundleIDs: ["com.adobe.illustrator"],
            target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["com.adobe.illustrator"])
        XCTAssertTrue(plan.placements.isEmpty, "excluded apps launch-only (PRD §9)")
    }

    func testOptionalEntriesSkippedWhenAdaptingToSmallerDisplay() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("keep"), entry("skipme", optional: true, z: 1)]),
            runningBundleIDs: [], excludedBundleIDs: [], target: laptopTarget)
        XCTAssertTrue(plan.adapted)
        XCTAssertEqual(plan.placements.map(\.bundleID), ["keep"])
        XCTAssertEqual(plan.appsToLaunch, ["keep"], "skipped optionals aren't launched either")
    }

    func testOptionalEntriesKeptOnSameDisplay() {
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("keep"), entry("opt", optional: true, z: 1)]),
            runningBundleIDs: ["keep", "opt"], excludedBundleIDs: [], target: sameTarget)
        XCTAssertFalse(plan.adapted)
        XCTAssertEqual(plan.placements.count, 2)
    }

    func testLaunchListIsDeduplicatedAndOrdered() {
        // Two windows of the same missing app → one launch.
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: [entry("multi"), entry("multi", z: 1)]),
            runningBundleIDs: [], excludedBundleIDs: [], target: sameTarget)
        XCTAssertEqual(plan.appsToLaunch, ["multi"])
        XCTAssertEqual(plan.placements.count, 2)
    }

    func testMatchingRecordsCarrySlotTitlePin() {
        let entries = [
            LayoutEntry(bundleID: "arc", title: "Work",
                        frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                        zIndex: 0, pinPattern: "Work", optional: false),
            LayoutEntry(bundleID: "arc", title: "Personal",
                        frame: NormalizedFrame(x: 0.5, y: 0, w: 0.25, h: 0.9),
                        zIndex: 1, pinPattern: nil, optional: false),
        ]
        let plan = TemplateApplyPlanner.plan(
            layout: layout(entries: entries),
            runningBundleIDs: ["arc"], excludedBundleIDs: [], target: sameTarget)
        let records = plan.matchingRecords(forBundleID: "arc")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].slot, 0)
        XCTAssertEqual(records[0].title, "Work")
        XCTAssertEqual(records[0].pinPattern, "Work")
        XCTAssertEqual(records[1].title, "Personal")
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: `cannot find 'TemplateApplyPlanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/TemplateApplyPlanner.swift`:
```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Computes everything needed to apply a MonitorLayout to a target display.
public enum TemplateApplyPlanner {
    public struct Target {
        public let info: DisplayInfo
        public let visibleArea: CGRect
        public init(info: DisplayInfo, visibleArea: CGRect) {
            self.info = info; self.visibleArea = visibleArea
        }
    }

    public struct Placement: Equatable {
        public let bundleID: String
        public let entryIndex: Int      // index into layout.entries
        public let targetRect: CGRect
        public let zIndex: Int
        public let title: String
        public let pinPattern: String?
    }

    public struct ApplyPlan {
        public let adapted: Bool
        public let appsToLaunch: [String]       // deduped, entry order
        public let placements: [Placement]      // excluded apps carry none
        public let stageMode: StageMode
        public let memberBundleIDs: Set<String> // for clear-stage hiding

        /// Pseudo-records for WindowMatcher when adopting a running app's windows.
        public func matchingRecords(forBundleID bundleID: String) -> [WindowRecord] {
            placements.filter { $0.bundleID == bundleID }
                .enumerated()
                .map { slot, placement in
                    WindowRecord(slot: slot, title: placement.title,
                                 frame: NormalizedFrame(x: 0, y: 0, w: 0, h: 0),
                                 pinPattern: placement.pinPattern,
                                 lastSeen: Date(timeIntervalSince1970: 0))
                }
        }
    }

    public static func plan(layout: MonitorLayout,
                            runningBundleIDs: Set<String>,
                            excludedBundleIDs: Set<String>,
                            target: Target) -> ApplyPlan {
        let adapted = layout.displayID != target.info.id
            || layout.displayMetrics.width != target.info.width
            || layout.displayMetrics.height != target.info.height
        let targetSmaller = target.info.width * target.info.height
            < layout.displayMetrics.width * layout.displayMetrics.height
        let skipOptionals = adapted && targetSmaller

        let activeEntries = layout.entries.enumerated().filter { _, entry in
            !(skipOptionals && entry.optional)
        }

        var seenLaunch = Set<String>()
        var appsToLaunch: [String] = []
        var placements: [Placement] = []
        var members = Set<String>()

        for (index, entry) in activeEntries {
            members.insert(entry.bundleID)
            if !runningBundleIDs.contains(entry.bundleID),
               seenLaunch.insert(entry.bundleID).inserted {
                appsToLaunch.append(entry.bundleID)
            }
            guard !excludedBundleIDs.contains(entry.bundleID) else { continue }
            placements.append(Placement(bundleID: entry.bundleID,
                                        entryIndex: index,
                                        targetRect: entry.frame.rect(in: target.visibleArea),
                                        zIndex: entry.zIndex,
                                        title: entry.title,
                                        pinPattern: entry.pinPattern))
        }
        return ApplyPlan(adapted: adapted, appsToLaunch: appsToLaunch,
                         placements: placements, stageMode: layout.stageMode,
                         memberBundleIDs: members)
    }
}
```

- [ ] **Step 4: Run `swift test`** — PASS (7 new; 60 total).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/TemplateApplyPlanner.swift Tests/MacTLMCoreTests/TemplateApplyPlannerTests.swift
git commit -m "feat: TemplateApplyPlanner with adaptation and stage semantics"
```

---

### Task 5: Coordinator settle generalization

Mechanical refactor: `pendingRestores: [String: Debouncer]` becomes a map of settle actions with pluggable fire behavior, so template placement (Task 7) reuses the same suppress-capture machinery as record restore.

**Files:**
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`

- [ ] **Step 1: Refactor**

In `PersistenceCoordinator`:

1. Replace `private var pendingRestores: [String: Debouncer] = [:]` with:
```swift
    private struct PendingSettle {
        let debouncer: Debouncer
        let fire: () -> Void
    }
    /// bundleID → armed settle. Presence suppresses tracker capture.
    private var pendingSettles: [String: PendingSettle] = [:]
```

2. Add the arming primitive (replaces the inline arming in `onAppLaunched`, the startup loop, and serves Task 7):
```swift
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
```

3. `onActivity` routing becomes:
```swift
            if let settle = self.pendingSettles[bundleID] {
                settle.debouncer.call(settle.fire)
            } else {
                self.tracker.noteActivity(bundleID: bundleID)
            }
```

4. `onAppLaunched` arming becomes (template settles win — don't clobber one):
```swift
            guard self.pendingSettles[bundleID] == nil else { return }
            self.armSettle(bundleID: bundleID) { [weak self] in
                self?.restoreRecords(bundleID: bundleID)
            }
```
where `restoreRecords` is the old `fireRestore` minus the removal line (removal now happens in `armSettle`'s wrapper):
```swift
    private func restoreRecords(bundleID: String) {
        guard !isPaused, !excludeList.isExcluded(bundleID) else { return }
        let area = ScreenGeometry.cgVisibleAreaOfMainScreen
        guard area.width > 0, area.height > 0 else { return }
        engine.restore(records: tracker.recordsFor(bundleID: bundleID),
                       bundleID: bundleID, visibleArea: area)
    }
```

5. The startup arming loop calls `armSettle(bundleID:)` with the same `restoreRecords` fire.

6. `onAppTerminated` becomes:
```swift
            if let settle = self?.pendingSettles.removeValue(forKey: bundleID) {
                settle.debouncer.cancel()
            }
            self?.tracker.noteTermination(bundleID: bundleID)
```

7. Delete the old `fireRestore`.

- [ ] **Step 2: Verify** — `swift build` clean; `swift test` 60 passes (Core untouched); `./scripts/make-app.sh` succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTLM/PersistenceCoordinator.swift
git commit -m "refactor: generalize launch settles to pluggable fire actions"
```

---

### Task 6: ScreenGeometry displays + ZOrderCapture

**Files:**
- Modify: `Sources/MacTLM/ScreenGeometry.swift`
- Create: `Sources/MacTLM/ZOrderCapture.swift`

- [ ] **Step 1: Extend ScreenGeometry**

Add to `ScreenGeometry`:
```swift
    /// All connected displays with CG-space visible areas and human names.
    static var allDisplays: [SnapshotPlanner.Display] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let info = displayInfo(for: screen) else { return nil }
            let visible = screen.visibleFrame
            let cgArea = CGRect(x: visible.minX,
                                y: primary.frame.maxY - visible.maxY,
                                width: visible.width,
                                height: visible.height)
            return SnapshotPlanner.Display(info: info,
                                           name: screen.localizedName,
                                           visibleArea: cgArea)
        }
    }
```
Extract the existing per-screen `DisplayInfo` construction from `currentConfiguration` into a shared `private static func displayInfo(for screen: NSScreen) -> DisplayInfo?` and use it in both `currentConfiguration` and `allDisplays` (no logic change — pure extraction).

- [ ] **Step 2: Write ZOrderCapture**

`Sources/MacTLM/ZOrderCapture.swift`:
```swift
import AppKit
import MacTLMCore

/// Captures global front-to-back window order via CGWindowList.
/// Bounds/pid/layer need no extra permission (window *names* would).
enum ZOrderCapture {
    /// Front-to-back refs for normal-layer on-screen windows.
    static func frontToBack() -> [ZOrderMatcher.CGRef] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation:
                        boundsDict as CFDictionary as! CFDictionary)
            else { return nil }
            return ZOrderMatcher.CGRef(pid: pid, frame: bounds)
        }
    }
}
```
Compile note: `CGRect(dictionaryRepresentation:)` takes a `CFDictionary`; the cleanest cast is `let boundsDict = info[kCGWindowBounds as String] as! CFDictionary` guarded by an `as?` to `NSDictionary` first — use whichever compiles cleanly, e.g.:
```swift
                  let boundsAny = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsAny as! CFDictionary)
```

- [ ] **Step 3: Verify** — `swift build` clean; `swift test` 60 passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM/ScreenGeometry.swift Sources/MacTLM/ZOrderCapture.swift
git commit -m "feat: multi-display geometry and CGWindowList z-order capture"
```

---

### Task 7: MissingAppNotifier

**Files:**
- Create: `Sources/MacTLM/MissingAppNotifier.swift`

- [ ] **Step 1: Implement**

`Sources/MacTLM/MissingAppNotifier.swift`:
```swift
import Foundation
import UserNotifications

/// One unobtrusive notification listing template apps that failed to launch
/// (PRD §3.2). Falls back to NSLog when not running from a bundle (swift run)
/// or when notification permission is denied.
enum MissingAppNotifier {
    static func notify(missing: [String]) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("MacTLM: (no bundle) missing apps: %@", missing.joined(separator: ", "))
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MacTLM"
            content.body = "Didn't launch: \(missing.joined(separator: ", "))"
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
```

- [ ] **Step 2: Verify** — `swift build` clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTLM/MissingAppNotifier.swift
git commit -m "feat: missing-app notification with bundle-less fallback"
```

---

### Task 8: SnapshotBuilder and TemplateLauncher

**Files:**
- Create: `Sources/MacTLM/SnapshotBuilder.swift`
- Create: `Sources/MacTLM/TemplateLauncher.swift`
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift` (own the library + launcher)

- [ ] **Step 1: Write SnapshotBuilder**

`Sources/MacTLM/SnapshotBuilder.swift`:
```swift
import AppKit
import MacTLMCore

/// Captures the current arrangement into per-display MonitorLayouts.
enum SnapshotBuilder {
    static func snapshot(name: String, stageMode: StageMode) -> [MonitorLayout] {
        var axRefs: [ZOrderMatcher.AXRef] = []
        var meta: [Int: (bundleID: String, title: String, frame: CGRect)] = [:]
        var seenBundles = Set<String>()

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  seenBundles.insert(bundleID).inserted else { continue }
            let appHandle = AXAppHandle(pid: app.processIdentifier)
            for window in appHandle.windows {
                guard let frame = window.frame, frame.width > 1, frame.height > 1
                else { continue }
                let id = window.stableID
                axRefs.append(ZOrderMatcher.AXRef(id: id, pid: app.processIdentifier,
                                                  frame: frame))
                meta[id] = (bundleID, window.title, frame)
            }
        }

        let zIndices = ZOrderMatcher.zIndices(axWindows: axRefs,
                                              cgFrontToBack: ZOrderCapture.frontToBack())
        let windows = meta.compactMap { id, m -> SnapshotPlanner.Window? in
            guard let z = zIndices[id] else { return nil }
            return SnapshotPlanner.Window(bundleID: m.bundleID, title: m.title,
                                          frame: m.frame, zIndex: z)
        }
        return SnapshotPlanner.plan(name: name, stageMode: stageMode,
                                    windows: windows,
                                    displays: ScreenGeometry.allDisplays,
                                    date: Date())
    }
}
```

- [ ] **Step 2: Write TemplateLauncher**

`Sources/MacTLM/TemplateLauncher.swift`:
```swift
import AppKit
import MacTLMCore

/// Applies a MonitorLayout: hides non-members (clear-stage), places running
/// apps, launches missing ones and places them after settle, then restores
/// stacking order back-to-front.
final class TemplateLauncher {
    private let driver: MacWindowDriver
    private unowned let coordinator: PersistenceCoordinator
    private var launchDeadline: DispatchWorkItem?

    init(driver: MacWindowDriver, coordinator: PersistenceCoordinator) {
        self.driver = driver
        self.coordinator = coordinator
    }

    func apply(_ layout: MonitorLayout, excludedBundleIDs: Set<String>) {
        guard let target = resolveTarget(for: layout) else { return }
        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.activationPolicy == .regular ? $0.bundleIdentifier : nil })
        let plan = TemplateApplyPlanner.plan(layout: layout,
                                             runningBundleIDs: running,
                                             excludedBundleIDs: excludedBundleIDs,
                                             target: target)
        guard target.visibleArea.width > 0, target.visibleArea.height > 0 else { return }

        if plan.stageMode == .clearStage {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !plan.memberBundleIDs.contains(bundleID) else { continue }
                app.hide()
            }
        }

        // Place already-running members now.
        let runningMembers = Set(plan.placements.map(\.bundleID)).intersection(running)
        for bundleID in runningMembers {
            place(bundleID: bundleID, plan: plan)
        }

        // Launch missing members; place each after its settle.
        var awaited = Set<String>()
        for bundleID in plan.appsToLaunch {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("MacTLM: no app found for %@", bundleID)
                continue
            }
            awaited.insert(bundleID)
            coordinator.armSettle(bundleID: bundleID) { [weak self] in
                self?.awaitedDidSettle(bundleID: bundleID, plan: plan)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        self.awaitedLaunches = awaited
        self.activePlan = plan

        if !awaited.isEmpty {
            // Anything not arrived in 15s: place what came, report the rest.
            let deadline = DispatchWorkItem { [weak self] in self?.reportMissing() }
            launchDeadline?.cancel()
            launchDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: deadline)
        } else {
            restoreStacking(plan: plan)
        }
    }

    // MARK: - Private

    private var awaitedLaunches = Set<String>()
    private var activePlan: TemplateApplyPlanner.ApplyPlan?

    private func resolveTarget(for layout: MonitorLayout) -> TemplateApplyPlanner.Target? {
        let displays = ScreenGeometry.allDisplays
        if let own = displays.first(where: { $0.info.id == layout.displayID }) {
            return TemplateApplyPlanner.Target(info: own.info, visibleArea: own.visibleArea)
        }
        // Display missing: adapt onto the main display (PRD §3.2 Tier-1).
        guard let main = displays.first else { return nil }
        return TemplateApplyPlanner.Target(info: main.info, visibleArea: main.visibleArea)
    }

    private func place(bundleID: String, plan: TemplateApplyPlanner.ApplyPlan) {
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        let records = plan.matchingRecords(forBundleID: bundleID)
        let placementsForBundle = plan.placements.filter { $0.bundleID == bundleID }
        let assignment = WindowMatcher.assign(records: records, to: candidates)
        for window in windows {
            guard let record = assignment[window.id],
                  record.slot < placementsForBundle.count else { continue }
            let targetRect = placementsForBundle[record.slot].targetRect
            let achieved = driver.setFrame(targetRect, of: window)
            if !achieved.approximatelyEquals(targetRect, tolerance: RestoreEngine.tolerance) {
                _ = driver.setFrame(targetRect, of: window)
            }
        }
    }

    private func awaitedDidSettle(bundleID: String, plan: TemplateApplyPlanner.ApplyPlan) {
        awaitedLaunches.remove(bundleID)
        place(bundleID: bundleID, plan: plan)
        if awaitedLaunches.isEmpty {
            launchDeadline?.cancel()
            launchDeadline = nil
            restoreStacking(plan: plan)
        }
    }

    private func reportMissing() {
        let missing = awaitedLaunches.sorted()
        awaitedLaunches = []
        if let plan = activePlan {
            restoreStacking(plan: plan)
        }
        guard !missing.isEmpty else { return }
        NSLog("MacTLM: template apps failed to launch: %@", missing.joined(separator: ", "))
        MissingAppNotifier.notify(missing: missing)
    }

    /// Raise members backmost-first so the frontmost ends up on top.
    private func restoreStacking(plan: TemplateApplyPlanner.ApplyPlan) {
        let byBundle = Dictionary(grouping: plan.placements, by: \.bundleID)
        var raiseList: [(zIndex: Int, bundleID: String, slot: Int)] = []
        for (bundleID, placements) in byBundle {
            for (slot, placement) in placements.enumerated() {
                raiseList.append((placement.zIndex, bundleID, slot))
            }
        }
        for item in raiseList.sorted(by: { $0.zIndex > $1.zIndex }) {
            let windows = driver.windows(ofBundleID: item.bundleID)
            let candidates = windows.enumerated().map { index, window in
                WindowCandidate(id: window.id, title: window.title, order: index)
            }
            guard let plan = activePlan else { break }
            let records = plan.matchingRecords(forBundleID: item.bundleID)
            let assignment = WindowMatcher.assign(records: records, to: candidates)
            guard let (windowID, _) = assignment.first(where: { $0.value.slot == item.slot }),
                  let handle = driver.handle(forWindowID: windowID) else { continue }
            AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
        }
        activePlan = nil
    }
}
```

Add to `MacWindowDriver`:
```swift
    /// Live AX handle for a window id from the most recent enumeration.
    func handle(forWindowID id: Int) -> AXWindowHandle? {
        handleCache[id]
    }
```

- [ ] **Step 3: Wire into PersistenceCoordinator**

Add stored properties + accessors:
```swift
    let layoutLibraryStore: LayoutLibraryStore
    private(set) lazy var templateLauncher = TemplateLauncher(driver: driver, coordinator: self)

    var currentExcludedBundleIDs: Set<String> { excludeList.bundleIDs }
```
In `init`, after `excludeURL`: `layoutLibraryStore = LayoutLibraryStore(url: supportDir.appendingPathComponent("layouts.json"))`. Make `driver` accessible to the launcher (it is — same file/module, keep `private let driver` and pass it in the lazy initializer).

Add a convenience the menu calls:
```swift
    func saveCurrentArrangement(name: String, stageMode: StageMode) {
        let layouts = SnapshotBuilder.snapshot(name: name, stageMode: stageMode)
        guard !layouts.isEmpty else { return }
        var library = layoutLibraryStore.load()
        library.layouts.append(contentsOf: layouts)
        try? layoutLibraryStore.save(library)
    }

    func applyLayout(_ layout: MonitorLayout) {
        templateLauncher.apply(layout, excludedBundleIDs: currentExcludedBundleIDs)
    }

    func deleteLayout(id: UUID) {
        var library = layoutLibraryStore.load()
        library.layouts.removeAll { $0.id == id }
        try? layoutLibraryStore.save(library)
    }
```

- [ ] **Step 4: Verify** — `swift build` clean; `swift test` 60 passes; `./scripts/make-app.sh` succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: snapshot builder and template launcher with settle placement"
```

---


### Task 9: Dynamic menu

Per PRD §4: sections per connected monitor, layouts beneath, collapsed inactive-monitor section, save action.

**Files:**
- Modify: `Sources/MacTLM/StatusMenuController.swift`

- [ ] **Step 1: Rebuild StatusMenuController**

Replace the static menu with a delegate-built one. Full new file:
```swift
import AppKit
import ServiceManagement
import MacTLMCore

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength)
    private let coordinator: PersistenceCoordinator
    private var menuLayouts: [UUID: MonitorLayout] = [:]

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "MacTLM")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild on every open so layouts and displays stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuLayouts.removeAll()

        let library = coordinator.layoutLibraryStore.load()
        let connectedIDs = Set(ScreenGeometry.allDisplays.map(\.info.id))
        let byDisplay = Dictionary(grouping: library.layouts, by: \.displayID)

        // Sections per connected display.
        for display in ScreenGeometry.allDisplays {
            guard let layouts = byDisplay[display.info.id], !layouts.isEmpty else { continue }
            menu.addItem(sectionHeader(display.name))
            for layout in layouts.sorted(by: { $0.name < $1.name }) {
                menu.addItem(layoutItem(layout, indent: 1))
            }
        }

        // Inactive monitor layouts (collapsed submenu), adaptive launch.
        let inactive = library.layouts.filter { !connectedIDs.contains($0.displayID) }
        if !inactive.isEmpty {
            let parent = NSMenuItem(title: "Inactive Monitor Layouts",
                                    action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (displayName, layouts) in Dictionary(grouping: inactive, by: \.displayName)
                .sorted(by: { $0.key < $1.key }) {
                submenu.addItem(sectionHeader(displayName))
                for layout in layouts.sorted(by: { $0.name < $1.name }) {
                    submenu.addItem(layoutItem(layout, indent: 1))
                }
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if menu.items.isEmpty == false { menu.addItem(.separator()) }
        menu.addItem(actionItem("Save Current Arrangement as Layout…",
                                #selector(saveArrangement)))
        menu.addItem(actionItem("Restore All Window Positions", #selector(restoreAll)))
        menu.addItem(.separator())
        let pause = actionItem("Pause Persistence", #selector(togglePause))
        pause.state = coordinator.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(actionItem("Exclude Frontmost App", #selector(excludeFrontmost)))
        menu.addItem(.separator())
        let login = actionItem("Launch at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacTLM",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    // MARK: - Item builders

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func layoutItem(_ layout: MonitorLayout, indent: Int) -> NSMenuItem {
        let item = NSMenuItem(title: layout.name,
                              action: #selector(launchLayout(_:)), keyEquivalent: "")
        item.target = self
        item.indentationLevel = indent
        item.representedObject = layout.id as NSUUID
        menuLayouts[layout.id] = layout
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func launchLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let layout = menuLayouts[id] else { return }
        coordinator.applyLayout(layout)
    }

    @objc private func saveArrangement() {
        let alert = NSAlert()
        alert.messageText = "Save Current Arrangement"
        alert.informativeText = "Name this layout. Windows on each display are saved per monitor."
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        field.placeholderString = "Layout name"
        let clearStage = NSButton(checkboxWithTitle: "Hide other apps when launching",
                                  target: nil, action: nil)
        clearStage.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(clearStage)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        coordinator.saveCurrentArrangement(
            name: name,
            stageMode: clearStage.state == .on ? .clearStage : .leaveOthers)
    }

    @objc private func restoreAll() { coordinator.restoreAll() }

    @objc private func togglePause(_ sender: NSMenuItem) {
        coordinator.isPaused.toggle()
        sender.state = coordinator.isPaused ? .on : .off
    }

    @objc private func excludeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        coordinator.exclude(bundleID: bundleID)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                sender.state = .off
            } else {
                try service.register()
                sender.state = .on
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}
```
Note: `menu.autoenablesItems` defaults true; disabled headers work because they have no action. Layout items have target+action → enabled.

- [ ] **Step 2: Verify** — `swift build` clean; `swift test` 60 passes; `./scripts/make-app.sh`.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTLM/StatusMenuController.swift
git commit -m "feat: dynamic per-monitor layout menu with save flow"
```

---

### Task 10: Live acceptance (manual protocol, user at keyboard)

- [ ] **Step 1:** Rebuild + relaunch (`./scripts/make-app.sh && open build/MacTLM.app`). Stable identity → Accessibility grant persists.
- [ ] **Step 2:** Arrange a 3-app test scene (e.g. TextEdit + Finder + Safari, overlapping), menu → *Save Current Arrangement as Layout…* → name "SmokeScene". Verify `layouts.json` contains one MonitorLayout with entries carrying distinct zIndex and titles.
- [ ] **Step 3:** Scramble all three windows, launch "SmokeScene" from the menu → windows return, stacking order (who overlaps whom) matches the capture.
- [ ] **Step 4:** Quit one member app; launch the layout → the app launches and lands in its slot after settle.
- [ ] **Step 5:** Save a clear-stage layout; launch it with an extra non-member app visible → non-member hides.
- [ ] **Step 6 (the PRD §9 acceptance, menu-click variant):** With your real workspace arranged (Illustrator fullscreen, Arc ×2, Paseo, Nextcloud Talk, Finder), save "Design + Comms". Quit Arc, Paseo, Nextcloud Talk, Finder, Illustrator. Launch "Design + Comms" → everything launches and lands; Illustrator launches untouched (excluded).
- [ ] **Step 7:** Tag:
```bash
git tag -a v0.2.0-m2a -m "M2a: workspace templates — engine and menu"
```

---

## Plan self-review notes

- **Spec coverage (PRD §3.2 minus M2b):** snapshot capture incl. stacking + display assignment ✓ (T2/T3/T6/T7), adopt-running/launch-missing ✓ (T4/T7), settle-gated placement reusing capture suppression ✓ (T5/T7), stage modes ✓ (T4/T7/T9), per-monitor decomposition ✓ (T3), inactive-monitor adaptive launch (Tier-1 remap, optional-member skip) ✓ (T4/T7/T9), partial-failure notification ✓ (T7/T8), menu per PRD §4 items 2-4 ✓ (T9). Deferred to M2b: bundles, hotkeys, prefs Layouts tab, glyph row (Phase 3).
- **Placement matching:** adopt-time window matching reuses WindowMatcher with pseudo-records (slot = per-bundle placement order); matcher's frame field is unused for matching, zero-frame placeholder is safe.
- **Type consistency:** `SnapshotPlanner.Display` consumed by `ScreenGeometry.allDisplays` (T6) and `SnapshotBuilder` (T7); `armSettle(bundleID:fire:)` defined T5, consumed T7; `driver.handle(forWindowID:)` added T7 where used.
- **Known accepted residuals:** raise pass re-enumerates per window (O(n·apps) AX calls, fine at menu-action frequency); template launch onto a *specific* non-main display when the layout's own display is missing always picks main (choice UI is M2b); `restoreStacking` interleaves per-bundle raises by global zIndex but cross-app raise ordering can still be perturbed by app activation — acceptable, verified live in T10.
