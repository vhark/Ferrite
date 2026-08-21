# M2d — Hashed Window Identity (Privacy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Never write window titles to disk again, while keeping the window-matching fidelity those titles provided.

**Why:** `layouts.json` and `configurations/*.json` stored window titles in plaintext — browser page titles among them (`"… - Etsy"`, `"Your Orders"`, `"shanghai tower"` were all present) — and PRD §7 explicitly designs those files to be git/Nextcloud-syncable. That put browsing history in a synced file. Titles were purged manually on 2026-08-20 (backup: `/tmp/mactlm-titles-backup-1787339395`), and the daemon was stopped because it re-persisted them from memory within seconds.

**Approach:** replace the stored `title` with `titleHash` — `SHA-256(salt ‖ title)`, truncated to 16 hex characters, where the salt is a per-install 32-byte random value. Disk gets opaque hex; matching keeps working because the same title hashes to the same value on the same machine.

**Honest limits of this scheme** (put in the README, not just here): a hash is derived from the title, so anyone holding both the data files *and* the salt can confirm a guessed title, though they cannot read titles out. The salt lives in `UserDefaults` (`~/Library/Preferences/dev.mactlm.MacTLM.plist`), deliberately outside the Application Support directory users sync — so syncing layouts does not carry the salt. Keychain storage would be stricter and is noted as a future option.

**Architecture constraint:** `MacTLMCore` must stay Linux-portable, so it performs **no hashing**. Core stores and compares opaque `titleHash` strings; the app layer (CryptoKit) computes them. Live titles stay in memory for pin matching and UI display, and are never persisted.

**Tech Stack:** Swift 5.9 mode, XCTest, CryptoKit (app layer only), AppKit, SwiftUI.

**Also fixed here:** a live bug found during M2c acceptance — a pin set in the Apps tab never reached disk (zero pins in any of five namespace files). Task 6 diagnoses it with a real store, since the existing unit tests for that path pass and therefore do not cover whatever breaks.

**Spec:** amends PRD §3.1 and §7 (which specify a "title snapshot"); update the PRD in Task 8.

---

### Task 1: Salted hashing in the app layer

**Files:**
- Create: `Sources/MacTLM/WindowIdentity.swift`

- [ ] **Step 1: Implement**

```swift
import CryptoKit
import Foundation

/// Turns a window title into an opaque, per-install identity.
///
/// Titles are never persisted: browser titles are browsing history, and the
/// data files are designed to be syncable (PRD §7). The hash preserves
/// exact-window matching without storing readable text.
///
/// The salt lives in UserDefaults, i.e. `~/Library/Preferences/`, which is
/// deliberately OUTSIDE the Application Support directory users sync — so a
/// synced layout file does not carry the value needed to test guesses.
enum WindowIdentity {
    private static let saltKey = "dev.mactlm.identitySalt"

    /// 32 random bytes, created once per install.
    private static var salt: Data {
        if let existing = UserDefaults.standard.data(forKey: saltKey),
           existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = Data(bytes)
        UserDefaults.standard.set(fresh, forKey: saltKey)
        return fresh
    }

    /// Opaque identity for a title, or nil for an empty title (nothing to
    /// match on, and hashing "" would make every untitled window equal).
    static func hash(_ title: String) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(title.utf8))
        return hasher.finalize()
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
```
The empty-title guard matters: several apps expose untitled windows (Finder's desktop before the subrole filter, terminal popups), and a shared hash for `""` would make them all match each other.

- [ ] **Step 2: Verify**

Run: `swift build`
Expected: clean. Confirm `import CryptoKit` appears only in `Sources/MacTLM` — never in Core: `grep -r CryptoKit Sources/MacTLMCore` must be empty.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacTLM/WindowIdentity.swift
git commit -m "feat: salted per-install window identity hashing"
```

---

### Task 2: Core stores hashes, not titles

**Files:**
- Modify: `Sources/MacTLMCore/WindowRecord.swift`
- Modify: `Sources/MacTLMCore/LayoutModels.swift`
- Modify: `Sources/MacTLMCore/WindowMatcher.swift`
- Modify: `Sources/MacTLMCore/SnapshotPlanner.swift`
- Modify: `Sources/MacTLMCore/TemplateApplyPlanner.swift`
- Create: `Tests/MacTLMCoreTests/WindowIdentityMatchingTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MacTLMCoreTests/WindowIdentityMatchingTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class WindowIdentityMatchingTests: XCTestCase {
    private func record(slot: Int, hash: String?, pin: String? = nil) -> WindowRecord {
        WindowRecord(slot: slot, titleHash: hash,
                     frame: NormalizedFrame(x: 0, y: 0, w: 0.5, h: 0.5),
                     pinPattern: pin, lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testMatchesByTitleHashNotTitleText() {
        let records = [record(slot: 0, hash: "aaaa1111"),
                       record(slot: 1, hash: "bbbb2222")]
        // Reopened in swapped order; hashes must still pair correctly.
        let windows = [WindowCandidate(id: 10, title: "irrelevant",
                                       titleHash: "bbbb2222", order: 0),
                       WindowCandidate(id: 11, title: "irrelevant",
                                       titleHash: "aaaa1111", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[10]?.slot, 1)
        XCTAssertEqual(result[11]?.slot, 0)
    }

    func testNilHashesDoNotMatchEachOther() {
        let records = [record(slot: 0, hash: nil), record(slot: 1, hash: nil)]
        let windows = [WindowCandidate(id: 10, title: "", titleHash: nil, order: 0),
                       WindowCandidate(id: 11, title: "", titleHash: nil, order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        // Falls through to order pairing, never hash-equality on nil.
        XCTAssertEqual(result[10]?.slot, 0)
        XCTAssertEqual(result[11]?.slot, 1)
    }

    func testPinsStillMatchAgainstLiveTitle() {
        // Pins are user-authored patterns tested against the LIVE title, which
        // is in memory only — so pinning still works with titles unpersisted.
        let records = [record(slot: 0, hash: "zzzz9999", pin: "Titan"),
                       record(slot: 1, hash: "yyyy8888")]
        let windows = [WindowCandidate(id: 10, title: "Koa (Health Coach)",
                                       titleHash: "nope0000", order: 0),
                       WindowCandidate(id: 11, title: "Titan (Coach)",
                                       titleHash: "nope1111", order: 1)]
        let result = WindowMatcher.assign(records: records, to: windows)
        XCTAssertEqual(result[11]?.slot, 0, "pin claims by live title")
        XCTAssertEqual(result[10]?.slot, 1)
    }

    func testRecordCodableHasNoTitleKey() throws {
        let records = ConfigurationRecords(apps: ["a": [record(slot: 0, hash: "abcd1234")]])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(records), as: UTF8.self)
        XCTAssertFalse(json.contains("\"title\""),
                       "no title key may ever be written to disk")
        XCTAssertTrue(json.contains("titleHash"))
    }

    func testLegacyRecordsWithPlaintextTitleDecodeAndDropIt() throws {
        // Files written before this change carry "title"; it must be ignored,
        // not crash, and must not survive a re-encode.
        let json = """
        {"apps":{"a":[{"frame":{"h":0.5,"w":0.5,"x":0,"y":0},
        "lastSeen":"2026-08-19T00:00:00Z","slot":0,"title":"Secret Page Title"}]}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConfigurationRecords.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(decoded.apps["a"]?.count, 1)
        XCTAssertNil(decoded.apps["a"]?[0].titleHash)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("Secret Page Title"),
                       "legacy plaintext must not be rewritten")
    }

    func testLayoutEntryCodableHasNoTitleKey() throws {
        let entry = LayoutEntry(bundleID: "a", titleHash: "abcd1234",
                                frame: NormalizedFrame(x: 0, y: 0, w: 1, h: 1),
                                zIndex: 0, pinPattern: nil, optional: false)
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertFalse(json.contains("\"title\""))
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL (no `titleHash` parameter).

- [ ] **Step 3: Implement**

Mechanical rename with absent-tolerant decoding (finding 11 in `docs/BACKLOG.md`):

1. `WindowRecord`: replace `public var title: String` with `public var titleHash: String?`; update the memberwise init. Add explicit `CodingKeys` covering `slot, titleHash, frame, pinPattern, lastSeen` — deliberately omitting `title`, so the legacy key is ignored on decode and never re-encoded. Add `init(from:)` using `decodeIfPresent` for `titleHash` and `pinPattern`.
2. `LayoutEntry`: same treatment — `title` becomes `titleHash: String?`, with CodingKeys omitting `title` and absent-tolerant decoding.
3. `WindowCandidate`: gains `titleHash: String?`; keeps `title` (live, in-memory only — used for pin matching and UI).
4. `WindowMatcher.assign`: phase 2 becomes hash equality, and must skip nil hashes entirely:
   ```swift
   for record in freeRecords {
       guard let hash = record.titleHash,
             let index = freeWindows.firstIndex(where: { $0.titleHash == hash })
       else { continue }
   ```
   Phase 1 (pins) is unchanged: it matches `pinPattern` against `$0.title`, the live value.
5. `SnapshotPlanner.Window`: gains `titleHash: String?` and keeps `title` for pin matching during capture; `plan(...)` writes `titleHash` into each `LayoutEntry`.
6. `TemplateApplyPlanner`: `Placement.title` becomes `Placement.titleHash`; `matchingRecords` passes `titleHash:` through.

- [ ] **Step 4: Run `swift test`** — PASS. Every previously title-based test needs its literal updated; expected total 113 (107 + 6 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacTLMCore Tests/MacTLMCoreTests
git commit -m "feat: store opaque window identity hashes instead of titles"
```

---

### Task 3: App layer computes hashes

**Files:**
- Modify: `Sources/MacTLM/MacWindowDriver.swift`
- Modify: `Sources/MacTLM/SnapshotBuilder.swift`
- Modify: `Sources/MacTLM/TemplateLauncher.swift`
- Modify: `Sources/MacTLMCore/WindowDriving.swift`

- [ ] **Step 1: Carry both values through the driver seam**

`DriverWindow` gains `titleHash: String?` alongside its existing live `title`. `MacWindowDriver.windows(ofBundleID:)` sets `titleHash: WindowIdentity.hash(window.title)`.

- [ ] **Step 2: Update the consumers**

Everywhere a `WindowCandidate` is built from a `DriverWindow` — `RestoreEngine.restore`, `TemplateLauncher.activateAndRaise` — pass both `title:` and `titleHash:`. `SnapshotBuilder` sets `titleHash` on each `SnapshotPlanner.Window`. `WindowTracker.capture` writes `titleHash` into records (it already receives `DriverWindow`s).

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh`
Expected: clean; 113 tests; bundle built. Then confirm no plaintext leaks:
```bash
grep -rn "\.title" Sources/MacTLMCore || echo "Core has no title usage"
```
Core may legitimately reference `WindowCandidate.title` for pin matching — verify each remaining hit is pin-related and in memory only, never written to a record or entry.

- [ ] **Step 4: Commit**

```bash
git add Sources
git commit -m "feat: compute window identity hashes in the driver layer"
```

---

### Task 4: UI shows live titles, never stored ones

**Files:**
- Modify: `Sources/MacTLM/PersistenceCoordinator.swift`
- Modify: `Sources/MacTLM/AppsPreferencesView.swift`
- Modify: `Sources/MacTLM/LayoutsPreferencesView.swift`

- [ ] **Step 1: Supply live titles to the UI**

`AppRecordSummary` gains `liveTitles: [Int: String]` — for each remembered slot, the title of the window currently matched to it, obtained by asking the driver for the app's live windows and running the same `WindowMatcher.assign`. When the app is not running, the map is empty.

- [ ] **Step 2: Render**

Apps tab slot rows show the live title when known, otherwise `"Window \(slot + 1)"` in secondary style. Layout entry rows do the same (they have `titleHash` only, so an unmatched entry shows `"Window \(index + 1)"`). Add a one-line footnote to the Apps tab: *"Window titles are shown live and never saved to disk."*

- [ ] **Step 3: Verify**

Run: `swift build && swift test && ./scripts/make-app.sh` — clean; 113 tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacTLM
git commit -m "feat: show live window titles in preferences, never stored text"
```

---

### Task 5: Purge-on-load safety net

Even with legacy keys ignored, a user's existing file keeps its plaintext until something rewrites it. Make the first load rewrite it.

**Files:**
- Modify: `Sources/MacTLMCore/LayoutLibraryStore.swift`
- Modify: `Sources/MacTLMCore/WindowTracker.swift`
- Create: `Tests/MacTLMCoreTests/LegacyTitlePurgeTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/MacTLMCoreTests/LegacyTitlePurgeTests.swift`:
```swift
import XCTest
@testable import MacTLMCore

final class LegacyTitlePurgeTests: XCTestCase {
    func testLoadingALegacyLibraryRewritesItWithoutTitles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"layouts":[{"createdAt":"2026-08-19T00:00:00Z","displayID":"A",
        "displayMetrics":{"height":1000,"id":"A","scale":2,"width":1600},
        "displayName":"DA","entries":[{"bundleID":"b","frame":{"h":1,"w":1,"x":0,"y":0},
        "optional":false,"title":"Private Page","zIndex":0}],
        "id":"AAAAAAAA-0000-0000-0000-000000000001","name":"W",
        "stageMode":"leaveOthers"}]}
        """
        try Data(legacy.utf8).write(to: url)
        let store = LayoutLibraryStore(url: url)
        _ = store.loadPurgingLegacyTitles()
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Private Page"),
                       "loading must scrub legacy plaintext from disk")
        XCTAssertTrue(onDisk.contains("bundleID"), "the layout itself survives")
    }
}
```

- [ ] **Step 2: Run `swift test`** — expect FAIL: no member `loadPurgingLegacyTitles`.

- [ ] **Step 3: Implement**

Add to `LayoutLibraryStore`:
```swift
    /// Loads, and if the file still contains a legacy plaintext `title` key,
    /// immediately rewrites it without one. Titles were never meant to be at
    /// rest (PRD §7 files are syncable), so the scrub happens on first read.
    public func loadPurgingLegacyTitles() -> LayoutLibrary {
        let library = load()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              text.contains("\"title\"") else { return library }
        try? save(library)   // re-encodes without the dropped key
        return library
    }
```
`url` is currently private — keep it private and add this method in the same file. Do the equivalent for the per-configuration store: `WindowTracker.init` calls a `LayoutStore.loadPurgingLegacyTitles(configKey:)` with the same shape.

- [ ] **Step 4: Run `swift test`** — PASS (1 new; 114 total).

- [ ] **Step 5: Point the callers at it**

`WindowTracker.init` and `reloadForCurrentConfiguration` use the purging loader. `PersistenceCoordinator.loadBundles`/`loadArchivedBundles`/`applyBundle` and `StatusMenuController` keep using plain `load()` — one purging read at startup is enough.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacTLMCore Tests/MacTLMCoreTests
git commit -m "feat: scrub legacy plaintext titles on first load"
```

---

### Task 6: Diagnose and fix the pin-write bug

A pin set through the Apps tab during M2c acceptance never reached disk — zero `pinPattern` values across all five namespace files — while `testSetPinPatternPersistsImmediately` passes. So the unit tests do not cover the live failure.

**Files:**
- Create: `Tests/MacTLMCoreTests/PinPersistenceIntegrationTests.swift`
- Modify: whichever file the diagnosis implicates

- [ ] **Step 1: Reproduce against a real store, not a fake**

`Tests/MacTLMCoreTests/PinPersistenceIntegrationTests.swift` — build a real `LayoutStore` in a temp directory and a real `WindowTracker` (with `FakeDriver` for windows only), then:
1. capture a window so a record exists,
2. `setPinPattern("Titan", bundleID:, slot: 0)`,
3. construct a **second** `WindowTracker` over the same directory and config key (simulating the next launch) and assert the pin is visible from it.

That third step is the one the existing tests skip — they only re-read through `store.load`, never through a fresh tracker.

- [ ] **Step 2: Run it.** If it passes, the Core path is sound and the fault is in the app layer; instrument `PersistenceCoordinator.setPinPattern` and the SwiftUI commit path with `NSLog`, rebuild, and have the human set a pin while `log stream` runs. Prime suspects, in order:
  1. the Apps tab passing an array index where `record.slot` is expected (silent no-op via the guard),
  2. `.onSubmit` not firing for the focused field,
  3. the tracker's debounced capture overwriting the pinned record from a stale in-memory copy (the very hazard M2c's Task 2 was meant to close),
  4. a config-key change between the edit and the flush, writing to a different namespace.
- [ ] **Step 3:** Fix the implicated layer. Add the regression test that would have caught it.
- [ ] **Step 4: Verify** — `swift build && swift test` (115+), `./scripts/make-app.sh`.
- [ ] **Step 5: Commit** with a message naming the actual root cause.

---

### Task 7: Live acceptance (user at keyboard)

- [ ] **Step 1:** `./scripts/install.sh`, confirm the daemon is back and `--login-status` is `enabled`.
- [ ] **Step 2 (the point of this milestone):** move some windows, wait 5s, then check the data files contain **no readable titles**:
  ```bash
  jq -r '[.. | objects | select(has("titleHash")) | .titleHash] | length' \
    ~/Library/Application\ Support/MacTLM/configurations/*.json
  grep -oiE "etsy|orders|http|\.com" ~/Library/Application\ Support/MacTLM/*.json \
    ~/Library/Application\ Support/MacTLM/configurations/*.json || echo "no readable titles"
  ```
  Expected: hashes present, no readable strings, and the salt present in `~/Library/Preferences/dev.mactlm.MacTLM.plist`.
- [ ] **Step 3:** Confirm matching still works: open two TextEdit documents, place them in distinct corners, quit, reopen in the opposite order. Each must return to its own corner — that is hash matching doing what titles used to.
- [ ] **Step 4:** Confirm Preferences still identifies windows: the Apps tab shows live titles for running apps and `Window N` for others.
- [ ] **Step 5:** Set a pin (Nextcloud Talk or Finder — apps with stable titles) and verify it appears in the JSON immediately.
- [ ] **Step 6:** Re-run the workspace hotkey and confirm restore still lands correctly on both displays.
- [ ] **Step 7:** Tag:
```bash
git tag -a v0.5.0-m2d -m "M2d: hashed window identity, no titles at rest"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-mactlm-prd-design.md`
- Modify: `docs/BACKLOG.md`

- [ ] **Step 1:** Amend the PRD: §3.1's `WindowRecord` and §7's storage description say "title snapshot"; replace with the hashed-identity design, state that titles are never persisted, and record why (syncable files must not carry browsing history).
- [ ] **Step 2:** Add to `docs/BACKLOG.md`: a `v0.5.0-m2d` shipped row; a finding that persisted window titles are a privacy leak in syncable files and that hashing preserves matching; and the honest limitation that the salt lives in `UserDefaults` so a determined holder of both files can confirm guessed titles, with Keychain noted as the stricter option.
- [ ] **Step 3: Commit**

```bash
git add docs
git commit -m "docs: hashed window identity replaces stored titles"
```

---

## Plan self-review notes

- **Threat actually addressed:** readable browsing history at rest in syncable files. Not addressed: an attacker with local code execution (who can read live titles from the AX API anyway), or one holding both files and the salt who wants to confirm a specific guess.
- **Fidelity preserved:** exact-window matching survives as hash equality (Task 2 tests prove pairing still works when windows reopen swapped). Pins keep working because they match user-authored patterns against live titles, never stored text.
- **Nil-hash hazard:** untitled windows must hash to `nil`, never to a shared constant, or every untitled window would match every other. Covered by `testNilHashesDoNotMatchEachOther` and the guard in `WindowIdentity.hash`.
- **Migration:** legacy `title` keys are ignored on decode (explicit `CodingKeys` omitting them) and scrubbed from disk on first load (Task 5). A manual purge already ran on this machine; the code path exists for other installs and for files restored from backup.
- **Portability:** CryptoKit stays in `Sources/MacTLM`; Core only compares opaque strings, so the Linux seam is intact. Task 3 Step 3 verifies this by grep.
- **Known follow-up:** the salt is not portable between machines, so a synced layout file's hashes are meaningless on a second Mac — matching there degrades to pins plus order until that machine re-captures. Acceptable; note it in `docs/BACKLOG.md`.
