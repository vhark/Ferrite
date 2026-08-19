# M1 — Position Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar daemon that automatically remembers every app's window frames and restores them on app relaunch, login, and display-configuration changes.

**Architecture:** Two SPM targets. `MacTLMCore` is pure Swift (no AppKit): models, JSON store, matching heuristics, restore engine, tracker — all unit-tested and Linux-portable. `MacTLM` is the AppKit executable: Accessibility (AX) driver, NSWorkspace/AXObserver event wiring, status menu. Events flow up (AX → tracker → debounced store writes); commands flow down (trigger → restore engine → AX setFrame with clamp acceptance).

**Tech Stack:** Swift 5.9+, SPM, XCTest, AppKit, ApplicationServices (AX API), ServiceManagement (login item). No third-party dependencies in M1.

**M1 boundaries (from PRD §3.1, §10):** pin rules are honored from the JSON store but have no editing UI yet (hand-edit the JSON; UI arrives with M2 preferences). No templates, no magnets, no hotkeys.

**Spec:** `docs/superpowers/specs/2026-08-19-mactlm-prd-design.md`

---

## Coordinate-space convention (read before any task)

The AX API uses **CG space: origin at the top-left of the primary display, y grows downward**. `NSScreen` frames use origin bottom-left, y grows upward. **Every CGRect in Core (records, engine, tracker) is CG space.** The only conversion point is `ScreenGeometry.cgVisibleArea(of:)` in Task 10. If a window restores to the wrong vertical position, the bug is a missed conversion.

---

### Task 1: SPM scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/MacTLMCore/Placeholder.swift` (deleted in Task 2)
- Create: `Sources/MacTLM/main.swift`
- Create: `Tests/MacTLMCoreTests/PlaceholderTests.swift` (deleted in Task 2)

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTLM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MacTLMCore"),
        .executableTarget(name: "MacTLM", dependencies: ["MacTLMCore"]),
        .testTarget(name: "MacTLMCoreTests", dependencies: ["MacTLMCore"]),
    ]
)
```

- [ ] **Step 2: Write minimal sources**

`Sources/MacTLMCore/Placeholder.swift`:
```swift
public enum MacTLMCore {}
```

`Sources/MacTLM/main.swift`:
```swift
import MacTLMCore
print("MacTLM scaffold")
```

`Tests/MacTLMCoreTests/PlaceholderTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class PlaceholderTests: XCTestCase {
    func testScaffold() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Verify build and tests**

Run: `swift build && swift test`
Expected: `Build complete!` and `Test Suite 'All tests' passed`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: SPM scaffold with Core/App/Tests targets"
```

---

### Task 2: NormalizedFrame

Frames stored as fractions of a display's visible area (PRD §7). Same area → exact round trip; different area → proportional remap (Tier-1 adaptation groundwork).

**Files:**
- Create: `Sources/MacTLMCore/NormalizedFrame.swift`
- Create: `Tests/MacTLMCoreTests/NormalizedFrameTests.swift`
- Delete: `Sources/MacTLMCore/Placeholder.swift`, `Tests/MacTLMCoreTests/PlaceholderTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/NormalizedFrameTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class NormalizedFrameTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975) // laptop, menu bar cut

    func testRoundTripIsExactOnSameArea() {
        let original = CGRect(x: 320, y: 74, width: 400, height: 877)
        let normalized = NormalizedFrame(windowFrame: original, visibleArea: area)
        let restored = normalized.rect(in: area)
        XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
        XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
    }

    func testRemapToDifferentAreaScalesProportionally() {
        // Right half of the source area…
        let original = CGRect(x: 800, y: 25, width: 800, height: 975)
        let normalized = NormalizedFrame(windowFrame: original, visibleArea: area)
        // …must map to the right half of any target area.
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1415)
        let remapped = normalized.rect(in: ultrawide)
        XCTAssertEqual(remapped.minX, 1720, accuracy: 0.001)
        XCTAssertEqual(remapped.minY, 0, accuracy: 0.001)
        XCTAssertEqual(remapped.width, 1720, accuracy: 0.001)
        XCTAssertEqual(remapped.height, 1415, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let frame = NormalizedFrame(x: 0.25, y: 0.1, w: 0.5, h: 0.8)
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(NormalizedFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'NormalizedFrame' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/NormalizedFrame.swift`:
```swift
import Foundation

/// A window frame stored as fractions (0–1) of a display's visible area.
/// `windowFrame` and `visibleArea` must share one coordinate space (CG space
/// everywhere in MacTLM — see plan header).
public struct NormalizedFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public init(windowFrame: CGRect, visibleArea: CGRect) {
        precondition(visibleArea.width > 0 && visibleArea.height > 0)
        x = (windowFrame.minX - visibleArea.minX) / visibleArea.width
        y = (windowFrame.minY - visibleArea.minY) / visibleArea.height
        w = windowFrame.width / visibleArea.width
        h = windowFrame.height / visibleArea.height
    }

    public func rect(in visibleArea: CGRect) -> CGRect {
        CGRect(x: visibleArea.minX + x * visibleArea.width,
               y: visibleArea.minY + y * visibleArea.height,
               width: w * visibleArea.width,
               height: h * visibleArea.height)
    }
}
```

Delete `Placeholder.swift` and `PlaceholderTests.swift`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: NormalizedFrame with proportional remap"
```

---

### Task 3: DisplayConfiguration

All persistence is namespaced by display configuration (PRD §7) so a future monitor never corrupts today's layouts.

**Files:**
- Create: `Sources/MacTLMCore/DisplayConfiguration.swift`
- Create: `Tests/MacTLMCoreTests/DisplayConfigurationTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/DisplayConfigurationTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class DisplayConfigurationTests: XCTestCase {
    let laptop = DisplayInfo(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                             width: 1600, height: 1000, scale: 2.0)
    let ultrawide = DisplayInfo(id: "A46D2F5E-0000-0000-1A2B-0104B53F0000",
                                width: 3440, height: 1440, scale: 1.0)

    func testKeyIsStableAcrossDisplayOrdering() {
        let a = DisplayConfiguration(displays: [laptop, ultrawide])
        let b = DisplayConfiguration(displays: [ultrawide, laptop])
        XCTAssertEqual(a.key, b.key)
    }

    func testDifferentConfigurationsGetDifferentKeys() {
        let solo = DisplayConfiguration(displays: [laptop])
        let dual = DisplayConfiguration(displays: [laptop, ultrawide])
        XCTAssertNotEqual(solo.key, dual.key)
    }

    func testKeyIsFilesystemSafe() {
        let key = DisplayConfiguration(displays: [laptop, ultrawide]).key
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        XCTAssertNil(key.rangeOfCharacter(from: forbidden))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'DisplayInfo' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/DisplayConfiguration.swift`:
```swift
import Foundation

public struct DisplayInfo: Codable, Equatable, Comparable {
    public let id: String       // display UUID string
    public let width: Double    // points
    public let height: Double   // points
    public let scale: Double

    public init(id: String, width: Double, height: Double, scale: Double) {
        self.id = id; self.width = width; self.height = height; self.scale = scale
    }

    public static func < (a: DisplayInfo, b: DisplayInfo) -> Bool { a.id < b.id }
}

public struct DisplayConfiguration: Equatable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays.sorted()
    }

    /// Stable, filesystem-safe namespace key for this set of displays.
    public var key: String {
        displays
            .map { "\($0.id)_\(Int($0.width))x\(Int($0.height))@\($0.scale)" }
            .joined(separator: "+")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/DisplayConfiguration.swift Tests/MacTLMCoreTests/DisplayConfigurationTests.swift
git commit -m "feat: DisplayConfiguration namespace keys"
```

---

### Task 4: WindowRecord and ConfigurationRecords

**Files:**
- Create: `Sources/MacTLMCore/WindowRecord.swift`
- Create: `Tests/MacTLMCoreTests/WindowRecordTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/MacTLMCoreTests/WindowRecordTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class WindowRecordTests: XCTestCase {
    func testConfigurationRecordsCodableRoundTrip() throws {
        var records = ConfigurationRecords()
        records.apps["company.thebrowser.Browser"] = [
            WindowRecord(slot: 0, title: "Work",
                         frame: NormalizedFrame(x: 0.22, y: 0.05, w: 0.25, h: 0.90),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
            WindowRecord(slot: 1, title: "Personal",
                         frame: NormalizedFrame(x: 0.48, y: 0.05, w: 0.25, h: 0.90),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConfigurationRecords.self,
                                         from: try encoder.encode(records))
        XCTAssertEqual(decoded, records)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'ConfigurationRecords' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/WindowRecord.swift`:
```swift
import Foundation

/// One remembered window of an app, within one display configuration.
public struct WindowRecord: Codable, Equatable {
    public var slot: Int              // stable index within the app's windows
    public var title: String          // title snapshot at capture time
    public var frame: NormalizedFrame
    public var pinPattern: String?    // optional regex matched against titles
    public var lastSeen: Date

    public init(slot: Int, title: String, frame: NormalizedFrame,
                pinPattern: String?, lastSeen: Date) {
        self.slot = slot; self.title = title; self.frame = frame
        self.pinPattern = pinPattern; self.lastSeen = lastSeen
    }
}

/// Everything remembered for one display configuration: bundleID → window slots.
public struct ConfigurationRecords: Codable, Equatable {
    public var apps: [String: [WindowRecord]]

    public init(apps: [String: [WindowRecord]] = [:]) {
        self.apps = apps
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowRecord.swift Tests/MacTLMCoreTests/WindowRecordTests.swift
git commit -m "feat: WindowRecord and ConfigurationRecords models"
```

---

### Task 5: LayoutStore

Human-readable JSON, atomic writes, one file per display configuration (PRD §7).

**Files:**
- Create: `Sources/MacTLMCore/LayoutStore.swift`
- Create: `Tests/MacTLMCoreTests/LayoutStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/LayoutStoreTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LayoutStoreTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadMissingConfigReturnsEmpty() {
        XCTAssertEqual(store.load(configKey: "nope"), ConfigurationRecords())
    }

    func testSaveThenLoadRoundTrips() throws {
        var records = ConfigurationRecords()
        records.apps["com.apple.finder"] = [
            WindowRecord(slot: 0, title: "Downloads",
                         frame: NormalizedFrame(x: 0.02, y: 0.20, w: 0.16, h: 0.60),
                         pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        try store.save(records, configKey: "laptop")
        XCTAssertEqual(store.load(configKey: "laptop"), records)
    }

    func testCorruptFileLoadsAsEmptyInsteadOfCrashing() throws {
        let url = directory.appendingPathComponent("bad.json")
        try Data("not json{".utf8).write(to: url)
        XCTAssertEqual(store.load(configKey: "bad"), ConfigurationRecords())
    }

    func testSavedFileIsHumanReadableJSON() throws {
        try store.save(ConfigurationRecords(), configKey: "laptop")
        let text = try String(contentsOf: directory.appendingPathComponent("laptop.json"))
        XCTAssertTrue(text.contains("\"apps\""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'LayoutStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/LayoutStore.swift`:
```swift
import Foundation

/// JSON persistence: one `<configKey>.json` per display configuration.
/// Files are pretty-printed and sorted so they diff cleanly under git/Nextcloud.
public final class LayoutStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(configKey: String) -> ConfigurationRecords {
        guard let data = try? Data(contentsOf: url(for: configKey)),
              let records = try? decoder.decode(ConfigurationRecords.self, from: data)
        else { return ConfigurationRecords() }
        return records
    }

    public func save(_ records: ConfigurationRecords, configKey: String) throws {
        try encoder.encode(records).write(to: url(for: configKey), options: .atomic)
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/LayoutStore.swift Tests/MacTLMCoreTests/LayoutStoreTests.swift
git commit -m "feat: LayoutStore atomic JSON persistence"
```

---

### Task 6: Debouncer (with max-delay cap)

Serves two PRD needs with one class: debounced store writes (~2 s, §3.1) and launch-settle detection ("assert only after activity quiesces, capped", §6.3 — quiet 1.5 s, cap 10 s).

**Files:**
- Create: `Sources/MacTLMCore/Debouncer.swift`
- Create: `Tests/MacTLMCoreTests/DebouncerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/DebouncerTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class DebouncerTests: XCTestCase {
    func testOnlyLastCallFires() {
        let expectation = expectation(description: "fired once")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true
        let debouncer = Debouncer(delay: 0.05)
        var value = 0
        for i in 1...5 {
            debouncer.call { value = i; expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(value, 5)
    }

    func testMaxDelayCapFiresDespiteContinuousCalls() {
        let expectation = expectation(description: "fired despite churn")
        let debouncer = Debouncer(delay: 0.1, maxDelay: 0.25)
        // Re-call every 50 ms forever; without the cap this never fires.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            debouncer.call { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 2.0)
        timer.invalidate()
    }

    func testCancelPreventsFiring() {
        let debouncer = Debouncer(delay: 0.05)
        var fired = false
        debouncer.call { fired = true }
        debouncer.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertFalse(fired)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'Debouncer' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/Debouncer.swift`:
```swift
import Foundation

/// Coalesces bursts of calls into one, on the main queue.
/// With `maxDelay`, guarantees firing within `maxDelay` of the burst's first
/// call even under continuous churn (used for launch-settle detection).
public final class Debouncer {
    private let delay: TimeInterval
    private let maxDelay: TimeInterval?
    private var pending: DispatchWorkItem?
    private var burstStart: Date?

    public init(delay: TimeInterval, maxDelay: TimeInterval? = nil) {
        self.delay = delay
        self.maxDelay = maxDelay
    }

    public func call(_ action: @escaping () -> Void) {
        pending?.cancel()
        let now = Date()
        if burstStart == nil { burstStart = now }
        var effectiveDelay = delay
        if let maxDelay, let start = burstStart {
            effectiveDelay = min(delay, max(0, maxDelay - now.timeIntervalSince(start)))
        }
        let item = DispatchWorkItem { [weak self] in
            self?.burstStart = nil
            self?.pending = nil
            action()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: item)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        burstStart = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/Debouncer.swift Tests/MacTLMCoreTests/DebouncerTests.swift
git commit -m "feat: Debouncer with max-delay cap for settle detection"
```

---

### Task 7: WindowMatcher

The multi-window matching heuristics (PRD §3.1): pin rules claim first, exact titles second, creation order last. This is the highest-risk pure logic in M1 — test it hard.

**Files:**
- Create: `Sources/MacTLMCore/WindowMatcher.swift`
- Create: `Tests/MacTLMCoreTests/WindowMatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/WindowMatcherTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class WindowMatcherTests: XCTestCase {
    private func record(slot: Int, title: String, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, title: title,
                     frame: NormalizedFrame(x: Double(slot) * 0.1, y: 0, w: 0.2, h: 0.9),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testOrderFallbackWhenTitlesAllChanged() {
        let records = [record(slot: 0, title: "Old A"), record(slot: 1, title: "Old B")]
        let windows = [WindowCandidate(id: 10, title: "New X", order: 0),
                       WindowCandidate(id: 11, title: "New Y", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0)
        XCTAssertEqual(result[11]?.slot, 1)
    }

    func testExactTitleMatchBeatsOrder() {
        let records = [record(slot: 0, title: "Work"), record(slot: 1, title: "Personal")]
        // Reopened in swapped order — titles must win.
        let windows = [WindowCandidate(id: 10, title: "Personal", order: 0),
                       WindowCandidate(id: 11, title: "Work", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testPinPatternBeatsExactTitle() {
        // Record 0 pins "Work"; window 11's title contains it, window 10 has the
        // exact old title of record 1. Pin claims first.
        let records = [record(slot: 0, title: "Anything", pin: "Work"),
                       record(slot: 1, title: "Work — Arc")]
        let windows = [WindowCandidate(id: 10, title: "Work — Arc", order: 0),
                       WindowCandidate(id: 11, title: "My Work Tabs", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0, "pin pattern claims the first title match")
        XCTAssertEqual(result[11]?.slot, 1, "remaining record falls through by order")
    }

    func testExtraWindowsAreLeftUnassigned() {
        let records = [record(slot: 0, title: "Only")]
        let windows = [WindowCandidate(id: 10, title: "Only", order: 0),
                       WindowCandidate(id: 11, title: "Extra", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[11])
    }

    func testFewerWindowsThanRecordsAssignsSubset() {
        let records = [record(slot: 0, title: "A"), record(slot: 1, title: "B")]
        let windows = [WindowCandidate(id: 10, title: "B", order: 0)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result.count, 1)
    }

    func testInvalidPinRegexIsIgnoredNotCrashing() {
        let records = [record(slot: 0, title: "A", pin: "([")]
        let windows = [WindowCandidate(id: 10, title: "A", order: 0)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 0, "falls back to title/order matching")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'WindowCandidate' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/WindowMatcher.swift`:
```swift
import Foundation

/// A currently-open window as seen by the driver, reduced to matching inputs.
public struct WindowCandidate: Equatable {
    public let id: Int       // driver-stable identifier
    public let title: String
    public let order: Int    // enumeration order, 0 = frontmost

    public init(id: Int, title: String, order: Int) {
        self.id = id; self.title = title; self.order = order
    }
}

/// Assigns remembered records to open windows (PRD §3.1):
/// 1. pin patterns claim first, 2. exact titles, 3. remaining by order.
public enum WindowMatcher {
    public static func assign(records: [WindowRecord],
                              to windows: [WindowCandidate]) -> [Int: WindowRecord] {
        var result: [Int: WindowRecord] = [:]
        var freeRecords = records.sorted { $0.slot < $1.slot }
        var freeWindows = windows.sorted { $0.order < $1.order }

        // 1. Pin patterns (case-insensitive regex; invalid patterns ignored).
        for record in freeRecords where record.pinPattern != nil {
            guard let pattern = record.pinPattern,
                  (try? NSRegularExpression(pattern: pattern)) != nil,
                  let index = freeWindows.firstIndex(where: {
                      $0.title.range(of: pattern,
                                     options: [.regularExpression, .caseInsensitive]) != nil
                  })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
        }
        freeRecords.removeAll { candidate in result.values.contains(candidate) }

        // 2. Exact title matches.
        for record in freeRecords {
            guard let index = freeWindows.firstIndex(where: { $0.title == record.title })
            else { continue }
            result[freeWindows[index].id] = record
            freeWindows.remove(at: index)
        }
        freeRecords.removeAll { candidate in result.values.contains(candidate) }

        // 3. Remaining pairs by order.
        for (window, record) in zip(freeWindows, freeRecords) {
            result[window.id] = record
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowMatcher.swift Tests/MacTLMCoreTests/WindowMatcherTests.swift
git commit -m "feat: WindowMatcher pin/title/order heuristics"
```

---

### Task 8: ExcludeList

**Files:**
- Create: `Sources/MacTLMCore/ExcludeList.swift`
- Create: `Tests/MacTLMCoreTests/ExcludeListTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/ExcludeListTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class ExcludeListTests: XCTestCase {
    func testDefaultsExcludeKnownHostileApps() {
        XCTAssertTrue(ExcludeList.defaults.isExcluded("com.adobe.illustrator"))
        XCTAssertFalse(ExcludeList.defaults.isExcluded("com.apple.TextEdit"))
    }

    func testLoadMissingFileYieldsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        XCTAssertEqual(ExcludeList.load(from: url), ExcludeList.defaults)
    }

    func testSaveLoadRoundTripWithUserAddition() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var list = ExcludeList.defaults
        list.bundleIDs.insert("com.example.fighty")
        try list.save(to: url)
        XCTAssertEqual(ExcludeList.load(from: url), list)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'ExcludeList' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/ExcludeList.swift`:
```swift
import Foundation

/// Apps persistence never touches. Defaults seeded from Rectangle's
/// known-hostile set (apps that fight external frame changes).
public struct ExcludeList: Codable, Equatable {
    public static let defaults = ExcludeList(bundleIDs: [
        "com.adobe.illustrator",
        "com.adobe.AfterEffects",
        "com.mathworks.matlab",
    ])

    public var bundleIDs: Set<String>

    public init(bundleIDs: Set<String>) {
        self.bundleIDs = bundleIDs
    }

    public func isExcluded(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    public static func load(from url: URL) -> ExcludeList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ExcludeList.self, from: data)
        else { return .defaults }
        return list
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/ExcludeList.swift Tests/MacTLMCoreTests/ExcludeListTests.swift
git commit -m "feat: ExcludeList with Rectangle-seeded defaults"
```

---

### Task 9: WindowDriving protocol and RestoreEngine

The driver abstraction is the Linux seam (PRD §6.2). RestoreEngine implements clamp acceptance: set → read back → one retry → accept (PRD §6.3, "never fight an app").

**Files:**
- Create: `Sources/MacTLMCore/WindowDriving.swift`
- Create: `Sources/MacTLMCore/RestoreEngine.swift`
- Create: `Tests/MacTLMCoreTests/RestoreEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/RestoreEngineTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class FakeDriver: WindowDriving {
    var windowsByBundle: [String: [DriverWindow]] = [:]
    var setFrameCalls: [(id: Int, frame: CGRect)] = []
    /// When set, every setFrame result is clamped to this height (app minimum).
    var clampHeightTo: CGFloat?

    func windows(ofBundleID bundleID: String) -> [DriverWindow] {
        windowsByBundle[bundleID] ?? []
    }

    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect {
        setFrameCalls.append((window.id, frame))
        var achieved = frame
        if let clamp = clampHeightTo { achieved.size.height = min(achieved.height, clamp) }
        return achieved
    }
}

final class RestoreEngineTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975)

    private func record(slot: Int, title: String, frame: NormalizedFrame) -> WindowRecord {
        WindowRecord(slot: slot, title: title, frame: frame,
                     pinPattern: nil, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testRestoresTwoWindowsToTheirFrames() {
        let driver = FakeDriver()
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Work", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
            DriverWindow(id: 2, title: "Personal", frame: CGRect(x: 400, y: 25, width: 300, height: 300)),
        ]
        let records = [
            record(slot: 0, title: "Work", frame: NormalizedFrame(x: 0.0, y: 0.0, w: 0.25, h: 0.9)),
            record(slot: 1, title: "Personal", frame: NormalizedFrame(x: 0.5, y: 0.0, w: 0.25, h: 0.9)),
        ]
        let placed = RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "arc", visibleArea: area)
        XCTAssertEqual(placed, 2)
        XCTAssertEqual(driver.setFrameCalls.count, 2)
        let workCall = driver.setFrameCalls.first { $0.id == 1 }!
        XCTAssertEqual(workCall.frame.width, 400, accuracy: 0.001)   // 0.25 * 1600
        XCTAssertEqual(workCall.frame.height, 877.5, accuracy: 0.001) // 0.9 * 975
    }

    func testClampedFrameGetsExactlyOneRetryThenAcceptance() {
        let driver = FakeDriver()
        driver.clampHeightTo = 500
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 300, height: 300)),
        ]
        let records = [record(slot: 0, title: "W",
                              frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.9))]
        RestoreEngine(driver: driver)
            .restore(records: records, bundleID: "app", visibleArea: area)
        XCTAssertEqual(driver.setFrameCalls.count, 2, "one attempt + one retry, never a loop")
    }

    func testNoRecordsMeansNoDriverCalls() {
        let driver = FakeDriver()
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: .zero),
        ]
        let placed = RestoreEngine(driver: driver)
            .restore(records: [], bundleID: "app", visibleArea: area)
        XCTAssertEqual(placed, 0)
        XCTAssertTrue(driver.setFrameCalls.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'WindowDriving' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/WindowDriving.swift`:
```swift
import Foundation

/// A window as reported by a platform driver. Frames are CG space (top-left).
public struct DriverWindow: Equatable {
    public let id: Int       // stable for a window's lifetime
    public let title: String
    public let frame: CGRect

    public init(id: Int, title: String, frame: CGRect) {
        self.id = id; self.title = title; self.frame = frame
    }
}

/// Platform seam (PRD §6.2). macOS implements with AX; Linux later with
/// sway/Hyprland IPC or EWMH.
public protocol WindowDriving: AnyObject {
    /// Current windows of a running app, frontmost first.
    func windows(ofBundleID bundleID: String) -> [DriverWindow]
    /// Sets a frame and returns the frame the app actually accepted.
    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect
}
```

`Sources/MacTLMCore/RestoreEngine.swift`:
```swift
import Foundation

/// Applies remembered frames to an app's open windows.
/// Clamp policy (PRD §6.3): set → read back → one retry → accept. Never loop.
public final class RestoreEngine {
    public static let tolerance: CGFloat = 2.0
    private let driver: WindowDriving

    public init(driver: WindowDriving) {
        self.driver = driver
    }

    /// Returns the number of windows placed.
    @discardableResult
    public func restore(records: [WindowRecord], bundleID: String,
                        visibleArea: CGRect) -> Int {
        guard !records.isEmpty else { return 0 }
        let windows = driver.windows(ofBundleID: bundleID)
        let candidates = windows.enumerated().map { index, window in
            WindowCandidate(id: window.id, title: window.title, order: index)
        }
        let assignment = WindowMatcher.assign(records: records, to: candidates)
        var placed = 0
        for window in windows {
            guard let record = assignment[window.id] else { continue }
            let target = record.frame.rect(in: visibleArea)
            let achieved = driver.setFrame(target, of: window)
            if !achieved.approximatelyEquals(target, tolerance: Self.tolerance) {
                _ = driver.setFrame(target, of: window) // one retry, then accept
            }
            placed += 1
        }
        return placed
    }
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowDriving.swift Sources/MacTLMCore/RestoreEngine.swift Tests/MacTLMCoreTests/RestoreEngineTests.swift
git commit -m "feat: WindowDriving seam and RestoreEngine with clamp acceptance"
```

---

### Task 10: WindowTracker

Capture side: on any activity for an app, re-snapshot its windows into records; persist debounced (~2 s) and flush on termination (PRD §3.1). Empty snapshots never erase records (quit closes windows before termination fires).

**Files:**
- Create: `Sources/MacTLMCore/WindowTracker.swift`
- Create: `Tests/MacTLMCoreTests/WindowTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/WindowTrackerTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class WindowTrackerTests: XCTestCase {
    var directory: URL!
    var store: LayoutStore!
    var driver: FakeDriver!
    let area = CGRect(x: 0, y: 25, width: 1600, height: 975)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = try LayoutStore(directory: directory)
        driver = FakeDriver()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTracker(saveDelay: TimeInterval = 0.05) -> WindowTracker {
        WindowTracker(driver: driver, store: store,
                      configKey: { "test-config" },
                      visibleArea: { self.area },
                      excludeList: { .defaults },
                      saveDelay: saveDelay)
    }

    func testActivityCapturesWindowFrames() {
        driver.windowsByBundle["com.apple.TextEdit"] = [
            DriverWindow(id: 1, title: "Doc",
                         frame: CGRect(x: 400, y: 122.5, width: 400, height: 487.5)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "com.apple.TextEdit")
        let records = tracker.recordsFor(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].frame.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.y, 0.1, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.w, 0.25, accuracy: 0.001)
        XCTAssertEqual(records[0].frame.h, 0.5, accuracy: 0.001)
    }

    func testExcludedAppIsIgnored() {
        driver.windowsByBundle["com.adobe.illustrator"] = [
            DriverWindow(id: 1, title: "Art", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "com.adobe.illustrator")
        XCTAssertTrue(tracker.recordsFor(bundleID: "com.adobe.illustrator").isEmpty)
    }

    func testEmptySnapshotKeepsLastKnownRecords() {
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "app")
        driver.windowsByBundle["app"] = [] // all windows closed pre-quit
        tracker.noteActivity(bundleID: "app")
        XCTAssertEqual(tracker.recordsFor(bundleID: "app").count, 1)
    }

    func testTerminationFlushesToDiskImmediately() {
        driver.windowsByBundle["app"] = [
            DriverWindow(id: 1, title: "W", frame: CGRect(x: 0, y: 25, width: 800, height: 600)),
        ]
        let tracker = makeTracker(saveDelay: 60) // debounce far in the future
        tracker.noteActivity(bundleID: "app")
        tracker.noteTermination(bundleID: "app")
        let loaded = store.load(configKey: "test-config")
        XCTAssertEqual(loaded.apps["app"]?.count, 1)
    }

    func testCapturePreservesExistingPinPatterns() {
        driver.windowsByBundle["arc"] = [
            DriverWindow(id: 1, title: "Renamed", frame: CGRect(x: 0, y: 25, width: 400, height: 900)),
        ]
        var seeded = ConfigurationRecords()
        seeded.apps["arc"] = [
            WindowRecord(slot: 0, title: "Old",
                         frame: NormalizedFrame(x: 0, y: 0, w: 0.25, h: 0.9),
                         pinPattern: "Work", lastSeen: Date(timeIntervalSince1970: 0)),
        ]
        try? store.save(seeded, configKey: "test-config")
        let tracker = makeTracker()
        tracker.noteActivity(bundleID: "arc")
        XCTAssertEqual(tracker.recordsFor(bundleID: "arc")[0].pinPattern, "Work")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'WindowTracker' in scope`.

- [ ] **Step 3: Implement**

`Sources/MacTLMCore/WindowTracker.swift`:
```swift
import Foundation

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
        self.records = store.load(configKey: configKey())
    }

    /// Call on window created/moved/resized/title-changed for an app.
    public func noteActivity(bundleID: String) {
        guard !excludeList().isExcluded(bundleID) else { return }
        capture(bundleID: bundleID)
        saveDebouncer.call { [weak self] in self?.persist() }
    }

    /// Call when an app terminates — flush immediately (PRD §3.1 quit snapshot).
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
        records = store.load(configKey: configKey())
    }

    private func capture(bundleID: String) {
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { return } // keep last-known on close-all
        let area = visibleArea()
        guard area.width > 0, area.height > 0 else { return }
        let existing = records.apps[bundleID] ?? []
        records.apps[bundleID] = windows.enumerated().map { index, window in
            WindowRecord(slot: index,
                         title: window.title,
                         frame: NormalizedFrame(windowFrame: window.frame, visibleArea: area),
                         pinPattern: existing.first { $0.slot == index }?.pinPattern,
                         lastSeen: Date())
        }
    }

    private func persist() {
        try? store.save(records, configKey: configKey())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS. All Core tests green (Tasks 2–10).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore/WindowTracker.swift Tests/MacTLMCoreTests/WindowTrackerTests.swift
git commit -m "feat: WindowTracker capture with debounced persistence"
```

---

### Task 11: AX layer — permission, window handles, screen geometry, `--list-windows`

AppKit target begins. Not unit-testable (needs the Accessibility grant); verified by a debug subcommand.

**Files:**
- Create: `Sources/MacTLM/AXPermission.swift`
- Create: `Sources/MacTLM/AXWindowHandle.swift`
- Create: `Sources/MacTLM/ScreenGeometry.swift`
- Create: `Sources/MacTLM/MacWindowDriver.swift`
- Modify: `Sources/MacTLM/main.swift`

- [ ] **Step 1: Write AXPermission**

`Sources/MacTLM/AXPermission.swift`:
```swift
import ApplicationServices

enum AXPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt directing the user to System Settings.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
```

- [ ] **Step 2: Write AXWindowHandle**

`Sources/MacTLM/AXWindowHandle.swift`:
```swift
import ApplicationServices
import AppKit

/// Wrapper over one window's AXUIElement. Frames are CG space (top-left).
final class AXWindowHandle {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    /// Stable for the window's lifetime: AXUIElement copies for the same
    /// window are CFEqual and share a CFHash.
    var stableID: Int { Int(bitPattern: CFHash(element)) }

    var title: String {
        (copyValue(kAXTitleAttribute) as? String) ?? ""
    }

    var frame: CGRect? {
        guard let positionValue = copyValue(kAXPositionAttribute),
              let sizeValue = copyValue(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Rectangle's proven sequence: position, size, position again (apps may
    /// shift origin while applying the size). Returns the achieved frame.
    @discardableResult
    func setFrame(_ rect: CGRect) -> CGRect? {
        var point = rect.origin
        var size = rect.size
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        return frame
    }

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}

/// Wrapper over one running app's AX root element.
final class AXAppHandle {
    let element: AXUIElement
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
        element = AXUIElementCreateApplication(pid)
        // Electron apps expose windows only after this (PRD §6.3).
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    var windows: [AXWindowHandle] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array.map(AXWindowHandle.init)
    }
}
```

- [ ] **Step 3: Write ScreenGeometry — the single NS↔CG conversion point**

`Sources/MacTLM/ScreenGeometry.swift`:
```swift
import AppKit
import MacTLMCore

enum ScreenGeometry {
    /// The main screen's visible area (minus menu bar/Dock) in CG space —
    /// the coordinate space the AX API uses. THE only NS→CG conversion point.
    static var cgVisibleAreaOfMainScreen: CGRect {
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first
        else { return .zero }
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX,
                      y: primary.frame.maxY - visible.maxY,
                      width: visible.width,
                      height: visible.height)
    }

    /// Current display configuration from attached screens (PRD §7 keying).
    static var currentConfiguration: DisplayConfiguration {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let uuid: String
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, cfUUID) as String
            } else {
                uuid = String(number)
            }
            return DisplayInfo(id: uuid,
                               width: screen.frame.width,
                               height: screen.frame.height,
                               scale: screen.backingScaleFactor)
        }
        return DisplayConfiguration(displays: displays)
    }
}
```

- [ ] **Step 4: Write MacWindowDriver**

`Sources/MacTLM/MacWindowDriver.swift`:
```swift
import AppKit
import MacTLMCore

/// AX-backed implementation of the Core driver seam.
final class MacWindowDriver: WindowDriving {
    /// Handles cached by stableID so setFrame can reach the AXUIElement.
    /// Refreshed on every enumeration.
    private var handleCache: [Int: AXWindowHandle] = [:]

    func windows(ofBundleID bundleID: String) -> [DriverWindow] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        var result: [DriverWindow] = []
        for app in apps {
            let handle = AXAppHandle(pid: app.processIdentifier)
            for window in handle.windows {
                guard let frame = window.frame, frame.width > 1, frame.height > 1
                else { continue }
                handleCache[window.stableID] = window
                result.append(DriverWindow(id: window.stableID,
                                           title: window.title,
                                           frame: frame))
            }
        }
        return result
    }

    func setFrame(_ frame: CGRect, of window: DriverWindow) -> CGRect {
        guard let handle = handleCache[window.id] else { return window.frame }
        return handle.setFrame(frame) ?? window.frame
    }
}
```

- [ ] **Step 5: Wire the `--list-windows` debug command**

Replace `Sources/MacTLM/main.swift`:
```swift
import AppKit
import MacTLMCore

let arguments = CommandLine.arguments

if arguments.contains("--list-windows") {
    guard AXPermission.isGranted else {
        print("Accessibility permission not granted. Run once without flags to request it.")
        exit(1)
    }
    let driver = MacWindowDriver()
    let area = ScreenGeometry.cgVisibleAreaOfMainScreen
    print("Visible area (CG): \(area)")
    print("Config key: \(ScreenGeometry.currentConfiguration.key)")
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
        guard let bundleID = app.bundleIdentifier else { continue }
        let windows = driver.windows(ofBundleID: bundleID)
        guard !windows.isEmpty else { continue }
        print("\n\(bundleID)")
        for window in windows {
            print("  [\(window.id)] \"\(window.title)\" \(window.frame)")
        }
    }
    exit(0)
}

// Full app assembly arrives in Task 13.
if !AXPermission.isGranted { AXPermission.request() }
print("MacTLM: accessibility granted = \(AXPermission.isGranted)")
```

- [ ] **Step 6: Build and smoke-test**

Run: `swift build && swift run MacTLM` (grant Accessibility to your terminal when prompted — System Settings → Privacy & Security → Accessibility), then `swift run MacTLM --list-windows`.
Expected: every visible app listed with plausible window frames; a window at the top of the screen shows a small CG `y` (~25–40), NOT a large one — if `y` is large for a top window, the NS→CG conversion is broken.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: AX driver, screen geometry, --list-windows smoke command"
```

---

### Task 12: Event wiring — WorkspaceMonitor, AppObserver, `--watch`

Launch/quit via NSWorkspace; window events via per-pid AXObserver, registered on the app element. Handles the registration race: subscribe → enumerate once ("kickstart") → events flow (PRD §6.3).

**Files:**
- Create: `Sources/MacTLM/AppObserver.swift`
- Create: `Sources/MacTLM/WorkspaceMonitor.swift`
- Modify: `Sources/MacTLM/main.swift`

- [ ] **Step 1: Write AppObserver**

`Sources/MacTLM/AppObserver.swift`:
```swift
import AppKit
import ApplicationServices

/// Per-app AXObserver forwarding window created/moved/resized/title events.
final class AppObserver {
    let pid: pid_t
    let bundleID: String
    private var observer: AXObserver?
    private let appElement: AXUIElement
    private let onActivity: (String) -> Void

    private static let notifications = [
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
    ]

    init?(app: NSRunningApplication, onActivity: @escaping (String) -> Void) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.pid = app.processIdentifier
        self.bundleID = bundleID
        self.onActivity = onActivity
        self.appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let this = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            this.onActivity(this.bundleID)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success,
              let axObserver = created else { return nil }
        observer = axObserver

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(axObserver, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }

    /// Race handling: fire one synthetic activity so windows that existed
    /// before subscription get captured.
    func kickstart() {
        onActivity(bundleID)
    }

    deinit {
        if let observer {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
```

- [ ] **Step 2: Write WorkspaceMonitor**

`Sources/MacTLM/WorkspaceMonitor.swift`:
```swift
import AppKit

/// App lifecycle (NSWorkspace) + per-app window events (AppObserver).
final class WorkspaceMonitor {
    private var observers: [pid_t: AppObserver] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    var onAppLaunched: ((String) -> Void)?
    var onAppTerminated: ((String) -> Void)?
    var onActivity: ((String) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.attach(to: app)
                if let bundleID = app.bundleIdentifier {
                    self?.onAppLaunched?(bundleID)
                }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                self?.observers.removeValue(forKey: app.processIdentifier)
                if let bundleID = app.bundleIdentifier {
                    self?.onAppTerminated?(bundleID)
                }
        })
        // Attach to everything already running.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            attach(to: app)
        }
    }

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              observers[app.processIdentifier] == nil,
              let observer = AppObserver(app: app, onActivity: { [weak self] bundleID in
                  self?.onActivity?(bundleID)
              })
        else { return }
        observers[app.processIdentifier] = observer
        observer.kickstart()
    }
}
```

- [ ] **Step 3: Add `--watch` to main.swift**

Insert before the final assembly block in `Sources/MacTLM/main.swift` (after the `--list-windows` block):
```swift
if arguments.contains("--watch") {
    guard AXPermission.isGranted else {
        print("Accessibility permission not granted.")
        exit(1)
    }
    let monitor = WorkspaceMonitor()
    monitor.onAppLaunched = { print("LAUNCH \($0)") }
    monitor.onAppTerminated = { print("QUIT   \($0)") }
    monitor.onActivity = { print("EVENT  \($0)") }
    monitor.start()
    print("Watching window events. Ctrl-C to stop.")
    RunLoop.main.run()
}
```

- [ ] **Step 4: Build and smoke-test**

Run: `swift build && swift run MacTLM --watch`, then in another terminal `open -a TextEdit`; drag the TextEdit window; quit TextEdit.
Expected output sequence: `EVENT com.apple.…` burst at start (kickstarts), `LAUNCH com.apple.TextEdit`, `EVENT com.apple.TextEdit` on every drag tick, `QUIT com.apple.TextEdit`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: workspace and AX observers with race kickstart"
```

---

### Task 13: App assembly — coordinator, status menu, triggers, login item, app bundle

Wires everything per PRD §3.1 triggers. **Critical routing rule:** while a restore is pending for a bundleID (launch settle in progress), activity events feed the settle debouncer, NOT the tracker — otherwise the app's own launch-time window placement overwrites the remembered frames before we assert them.

**Files:**
- Create: `Sources/MacTLM/PersistenceCoordinator.swift`
- Create: `Sources/MacTLM/StatusMenuController.swift`
- Create: `Sources/MacTLM/AppDelegate.swift`
- Modify: `Sources/MacTLM/main.swift`
- Create: `scripts/make-app.sh`

- [ ] **Step 1: Write PersistenceCoordinator**

`Sources/MacTLM/PersistenceCoordinator.swift`:
```swift
import AppKit
import MacTLMCore

/// Wires monitor → tracker/engine. Owns the launch-settle state machine.
final class PersistenceCoordinator {
    private let driver = MacWindowDriver()
    private let store: LayoutStore
    private let tracker: WindowTracker
    private let engine: RestoreEngine
    private let monitor = WorkspaceMonitor()
    private var excludeList: ExcludeList
    private let excludeURL: URL
    /// bundleID → settle debouncer. Presence means "restore pending".
    private var pendingRestores: [String: Debouncer] = [:]
    var isPaused = false

    init() throws {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTLM")
        store = try LayoutStore(directory: supportDir.appendingPathComponent("configurations"))
        excludeURL = supportDir.appendingPathComponent("exclude.json")
        excludeList = ExcludeList.load(from: excludeURL)
        let listProvider = { [unowned self] in self.excludeList }
        tracker = WindowTracker(
            driver: driver, store: store,
            configKey: { ScreenGeometry.currentConfiguration.key },
            visibleArea: { ScreenGeometry.cgVisibleAreaOfMainScreen },
            excludeList: listProvider)
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
            self?.pendingRestores.removeValue(forKey: bundleID)
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
```

- [ ] **Step 2: Write StatusMenuController**

`Sources/MacTLM/StatusMenuController.swift`:
```swift
import AppKit
import ServiceManagement

final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength)
    private let coordinator: PersistenceCoordinator

    init(coordinator: PersistenceCoordinator) {
        self.coordinator = coordinator
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "MacTLM")

        let menu = NSMenu()
        menu.addItem(withTitle: "Restore All Window Positions",
                     action: #selector(restoreAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Persistence",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(withTitle: "Exclude Frontmost App",
                     action: #selector(excludeFrontmost), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacTLM",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func restoreAll() {
        coordinator.restoreAll()
    }

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

- [ ] **Step 3: Write AppDelegate and finalize main.swift**

`Sources/MacTLM/AppDelegate.swift`:
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PersistenceCoordinator?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXPermission.isGranted {
            AXPermission.request()
            // Poll until granted, then start (System Settings grant is async).
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard AXPermission.isGranted else { return }
                timer.invalidate()
                self?.startServices()
            }
        } else {
            startServices()
        }
    }

    private func startServices() {
        do {
            let coordinator = try PersistenceCoordinator()
            coordinator.start()
            self.coordinator = coordinator
            self.statusMenu = StatusMenuController(coordinator: coordinator)
        } catch {
            NSLog("MacTLM failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }
}
```

Replace the trailing assembly block in `Sources/MacTLM/main.swift` (keep the `--list-windows` and `--watch` blocks above it):
```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
```

- [ ] **Step 4: Write the app-bundle script**

`scripts/make-app.sh`:
```bash
#!/bin/bash
# Builds MacTLM.app — a stable bundle ID keeps the Accessibility grant
# across rebuilds (TCC keys off the bundle, not the binary).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/MacTLM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacTLM "$APP/Contents/MacOS/MacTLM"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.mactlm.MacTLM</string>
  <key>CFBundleName</key><string>MacTLM</string>
  <key>CFBundleExecutable</key><string>MacTLM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x scripts/make-app.sh`

- [ ] **Step 5: Build and launch**

Run: `swift build && ./scripts/make-app.sh && open build/MacTLM.app`
Expected: menu-bar icon appears (rectangles symbol), no Dock icon; first launch triggers the Accessibility prompt; after granting in System Settings, the menu's items are enabled. Add `build/` and `.build/` to `.gitignore`.

- [ ] **Step 6: Commit**

```bash
printf 'build/\n.build/\n' >> .gitignore
git add Sources/MacTLM scripts/make-app.sh .gitignore
git commit -m "feat: app assembly — coordinator, status menu, login item, bundle script"
```

---

### Task 14: End-to-end acceptance (manual smoke protocol)

This is M1's acceptance test from PRD §10. Run every step; all must pass before tagging.

**Files:** none (protocol only)

- [ ] **Step 1: Relaunch restore, single window**

1. `open build/MacTLM.app` (Accessibility granted).
2. Open TextEdit with one document window; drag it to the bottom-right corner.
3. Wait 3 s (debounce), quit TextEdit (⌘Q).
4. Verify `~/Library/Application Support/MacTLM/configurations/<key>.json` contains `com.apple.TextEdit` with one record.
5. Reopen TextEdit.
Expected: within ~2 s of the window appearing (settle), it returns to the bottom-right corner.

- [ ] **Step 2: Multi-window restore**

1. In TextEdit open two documents titled `alpha.txt` and `beta.txt`; place alpha top-left, beta bottom-right; wait 3 s; quit.
2. Reopen both documents.
Expected: alpha returns top-left, beta bottom-right (title matching), even if reopened in the opposite order.

- [ ] **Step 3: Exclusion**

1. Focus TextEdit → menu-bar icon → *Exclude Frontmost App*.
2. Move the TextEdit window somewhere new; quit; reopen.
Expected: window does NOT get moved by MacTLM; `exclude.json` contains `com.apple.TextEdit`. Remove it from `exclude.json` afterward.

- [ ] **Step 4: Manual restore-all**

1. Drag the TextEdit window away from its remembered spot.
2. Menu-bar icon → *Restore All Window Positions*.
Expected: window snaps back to the remembered frame.

- [ ] **Step 5: Pause**

1. Toggle *Pause Persistence* on; move the TextEdit window; wait 3 s; toggle off; *Restore All*.
Expected: window returns to the pre-pause position (moves while paused were not captured).

- [ ] **Step 6: Login trigger**

1. Enable *Launch at Login*; log out and back in (or reboot).
Expected: menu-bar icon present without manual launch; ~5 s after login, remembered running apps are re-asserted.

- [ ] **Step 7: Daily-driver soak begins**

Leave MacTLM running through normal work (Arc, Paseo, Nextcloud Talk, Finder). Illustrator is on the default exclude list — confirm it is never touched.

- [ ] **Step 8: Tag the milestone**

```bash
git tag -a v0.1.0-m1 -m "M1: automatic window position persistence"
```

---

## Plan self-review notes

- **Spec coverage (PRD §3.1):** automatic capture ✓ (T10, T12), exclude list ✓ (T8, T13), launch trigger with settle ✓ (T13), login trigger ✓ (T13 grace-period restore + login item), display-config trigger ✓ (T13 notification → reload + restore), debounced capture + quit flush ✓ (T6, T10), N-window restore ✓ (T7, T9), pin rules honored ✓ (T7; editing UI deferred to M2 per plan header).
- **Known M1 rough edge (accepted):** `CFHash(AXUIElement)` collisions are theoretically possible; the cache is refreshed on every enumeration so a collision misplaces at most one window once. Revisit only if observed in soak.
- **Type consistency verified:** `WindowDriving`/`DriverWindow` (T9) match `FakeDriver` usage in T9/T10 and `MacWindowDriver` in T11; `Debouncer(delay:maxDelay:)` (T6) matches T13 usage.
