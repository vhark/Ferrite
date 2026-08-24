# M3c — Proportional Group Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A magnet group resizes like one combined window. Dragging a grouped window's outer edge scales the whole group along that axis on release; an outer corner scales both axes. Shared edges keep M3b's live Shrink/Nudge untouched.

**Spec:** `docs/superpowers/specs/2026-08-24-proportional-group-resize-design.md` — read it first; the gesture contract, settle-on-release rationale, and per-axis remap rules live there.

**Baseline:** `main` at `28c6af3` (tag `v0.7.0-m3b`), 190 tests passing.

**Design stance:** all geometry in `MacTLMCore` (Foundation + guarded CoreGraphics, no AppKit/CryptoKit). `Sources/MacTLM` contributes only the resize session: open, track, settle on mouse-up, through the existing suppression set.

---

## Task 1: `MagnetScale` — classification and per-axis settle (Core, TDD)

**Files:** create `Sources/MacTLMCore/MagnetScale.swift`, `Tests/MacTLMCoreTests/MagnetScaleTests.swift`.

- [ ] **Step 1: Write the tests first** (11 tests)

```swift
import XCTest
@testable import MacTLMCore

final class MagnetScaleTests: XCTestCase {
    // Two windows mated left|right with an 8pt gap; bbox (0,0,2000,1000).
    private let left = CGRect(x: 0, y: 0, width: 992, height: 1000)
    private let right = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
    private let floor = CGSize(width: 200, height: 200)

    // MARK: - Classification

    func testSharedEdgeIsNotOuter() {
        let outer = MagnetScale.outerEdges(of: left, among: [right])
        XCTAssertEqual(outer, [.left, .top, .bottom],
                       "the right edge has a flush mate and must not classify as outer")
    }

    func testCornerGrazeStaysOuter() {
        // Mate only 20pt of vertical overlap left... none: fully below.
        let below = CGRect(x: 1000, y: 1008, width: 1000, height: 500)
        let outer = MagnetScale.outerEdges(of: left, among: [below])
        XCTAssertTrue(outer.contains(.right),
                      "no perpendicular overlap means no shared edge")
    }

    func testFlushDetectionTolerates12pt() {
        let slightlyOff = CGRect(x: 1010, y: 0, width: 990, height: 1000) // 18pt gap ≈ 8+10
        let outer = MagnetScale.outerEdges(of: left, among: [slightlyOff])
        XCTAssertFalse(outer.contains(.right),
                       "within gap+tolerance is still flush")
    }

    // MARK: - Settle

    func testDraggedWindowKeepsOnlyItsProportionalShare() {
        // User drags the right window's right edge +500 → macOS gave it all 500.
        let release = CGRect(x: 1000, y: 0, width: 1500, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        // bbox 2000 → 2500, fx = 1.25
        XCTAssertEqual(result[2]!.width, 1250, accuracy: 0.5,
                       "the dragged window's share is proportional, not the full delta")
        XCTAssertEqual(result[1]!.width, 1240, accuracy: 0.5)
        XCTAssertEqual(result[1]!.minX, 0, accuracy: 0.5, "far side of the group is anchored")
        XCTAssertEqual(result[2]!.maxX, 2500, accuracy: 0.5, "dragged edge lands where the user put it")
    }

    func testGapScalesProportionally() {
        let release = CGRect(x: 1000, y: 0, width: 3000, height: 1000) // bbox ×2
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        let gap = result[2]!.minX - result[1]!.maxX
        XCTAssertEqual(gap, 16, accuracy: 0.5, "the 8pt gap doubles at ×2 — the one-window metaphor")
    }

    func testCornerScalesBothAxes() {
        let release = CGRect(x: 1000, y: 0, width: 1500, height: 1500)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.height, 1500, accuracy: 0.5)
        XCTAssertEqual(result[1]!.width, 1240, accuracy: 0.5)
    }

    func testUnscaledAxisKeepsReleaseValues() {
        // During the drag, live shared-edge propagation already shrank window 1
        // horizontally. The settle scales only the vertical axis and must NOT
        // undo that horizontal adjustment by remapping it from session start.
        let liveShrunk = CGRect(x: 0, y: 0, width: 900, height: 1000)
        let release = CGRect(x: 1000, y: 0, width: 1000, height: 1300) // bottom edge +300
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: liveShrunk, 2: release],
                                        changed: 2, outerEdges: [.top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.width, 900, accuracy: 0.5,
                       "the live-propagated horizontal result survives the settle")
        XCTAssertEqual(result[1]!.height, 1300, accuracy: 0.5)
    }

    func testLeftEdgeDeltaMovesOriginAndScales() {
        // Dragging the LEFT window's left edge -400 (outward): origin moves.
        let release = CGRect(x: -400, y: 0, width: 1392, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: release, 2: right],
                                        changed: 1, outerEdges: [.left, .top, .bottom],
                                        minimumSize: floor)
        // bbox 2000 → 2400, fx = 1.2
        XCTAssertEqual(result[1]!.minX, -400, accuracy: 0.5)
        XCTAssertEqual(result[2]!.maxX, 2000, accuracy: 0.5, "the far right edge is anchored")
        XCTAssertEqual(result[2]!.width, 1200, accuracy: 0.5)
    }

    func testShrinkClampsAtFloor() {
        // Two-window fixtures cannot reach the floor: the dragged window's own
        // shared edge bounds the shrink. Three in a row, with narrow leftmost
        // members, can — dragging the wide rightmost window's right edge from
        // 2000 down to 500 gives fx = 0.25, which would leave the 192pt
        // members at 48pt without the clamp.
        let a = CGRect(x: 0, y: 0, width: 192, height: 1000)
        let b = CGRect(x: 200, y: 0, width: 192, height: 1000)
        let c = CGRect(x: 400, y: 0, width: 1600, height: 1000)
        let release = CGRect(x: 400, y: 0, width: 100, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: a, 2: b, 3: c],
                                        releaseFrames: [1: a, 2: b, 3: release],
                                        changed: 3, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertEqual(result[1]!.width, floor.width, accuracy: 0.5,
                       "48pt of proportional share is clamped up to the floor")
        for frame in result.values {
            XCTAssertGreaterThanOrEqual(frame.width, floor.width - 0.5,
                                        "no member is crushed below usability")
        }
        // Overlap at extremes is accepted, same stance as GroupLayoutSolver.clamp.
    }

    func testNoOuterDeltaProducesNothing() {
        // Only the shared edge moved — that is live propagation's job.
        let release = CGRect(x: 900, y: 0, width: 1100, height: 1000)
        let result = MagnetScale.settle(startFrames: [1: left, 2: right],
                                        releaseFrames: [1: left, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertTrue(result.isEmpty,
                      "left-edge movement is not in outerEdges for window 2, and no outer edge moved")
    }

    func testDegenerateShrinkIsRefused() {
        // Dragged so far the extent would invert.
        let release = CGRect(x: 1000, y: 0, width: 10, height: 1000)
        let start = [1: CGRect(x: 990, y: 0, width: 10, height: 1000), 2: right]
        let result = MagnetScale.settle(startFrames: start,
                                        releaseFrames: [1: start[1]!, 2: release],
                                        changed: 2, outerEdges: [.right, .top, .bottom],
                                        minimumSize: floor)
        // Either clamped sane frames or an empty refusal — never inverted rects.
        for frame in result.values {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    func testSingleMemberSettlesNothing() {
        let result = MagnetScale.settle(startFrames: [2: right],
                                        releaseFrames: [2: right.insetBy(dx: -100, dy: 0)],
                                        changed: 2, outerEdges: [.left, .right, .top, .bottom],
                                        minimumSize: floor)
        XCTAssertTrue(result.isEmpty, "a group of one has nothing to scale")
    }
}
```

- [ ] **Step 2: Run the tests, watch them fail** (`swift test` — "cannot find 'MagnetScale' in scope")

- [ ] **Step 3: Implement** `Sources/MacTLMCore/MagnetScale.swift`

```swift
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Scales a magnet group as one combined window when an outer edge is dragged.
///
/// Settle-on-release: during the drag macOS gives the dragged window the full
/// delta; correcting it mid-drag fights the user's grip. On mouse-up every
/// member — the dragged window included — is remapped to its proportional
/// share of the new bounding box. Per-axis: an axis participates only when an
/// outer edge on it moved, and non-participating axes keep their release-time
/// values so a live shared-edge adjustment made during the same drag survives.
public enum MagnetScale {
    private static let epsilon: CGFloat = 0.5

    /// Edges of `frame` that no mate is flush against. Same adjacency
    /// semantics as `MagnetResize`: facing edges within `gap + tolerance` and
    /// overlapping perpendicular extents.
    public static func outerEdges(of frame: CGRect, among mates: [CGRect],
                                  gap: CGFloat = 8,
                                  tolerance: CGFloat = 12) -> Set<MagnetMating.Edge> {
        let all: [MagnetMating.Edge] = [.left, .right, .top, .bottom]
        return Set(all.filter { edge in
            !mates.contains { isFlush(frame, $0, edge: edge, gap: gap, tolerance: tolerance) }
        })
    }

    private static func isFlush(_ subject: CGRect, _ mate: CGRect,
                                edge: MagnetMating.Edge,
                                gap: CGFloat, tolerance: CGFloat) -> Bool {
        let facing: CGFloat
        switch edge {
        case .right: facing = abs(mate.minX - subject.maxX - gap)
        case .left: facing = abs(subject.minX - mate.maxX - gap)
        case .bottom: facing = abs(mate.minY - subject.maxY - gap)
        case .top: facing = abs(subject.minY - mate.maxY - gap)
        }
        guard facing <= tolerance else { return false }
        if edge == .left || edge == .right {
            return min(subject.maxY, mate.maxY) - max(subject.minY, mate.minY) > 0
        }
        return min(subject.maxX, mate.maxX) - max(subject.minX, mate.minX) > 0
    }

    /// Frames that must move so the group scales as one window. `changed` may
    /// itself appear in the result: its proportional share is smaller than the
    /// full delta macOS gave it during the drag.
    public static func settle(startFrames: [Int: CGRect],
                              releaseFrames: [Int: CGRect],
                              changed: Int,
                              outerEdges: Set<MagnetMating.Edge>,
                              minimumSize: CGSize = CGSize(width: 240, height: 160))
        -> [Int: CGRect] {
        guard startFrames.count > 1,
              let start = startFrames[changed],
              let release = releaseFrames[changed] else { return [:] }

        var bbox = start
        for frame in startFrames.values { bbox = bbox.union(frame) }

        // Outer-edge deltas only; shared edges belong to live propagation.
        let dLeft = outerEdges.contains(.left) ? release.minX - start.minX : 0
        let dRight = outerEdges.contains(.right) ? release.maxX - start.maxX : 0
        let dTop = outerEdges.contains(.top) ? release.minY - start.minY : 0
        let dBottom = outerEdges.contains(.bottom) ? release.maxY - start.maxY : 0
        let scaleX = abs(dLeft) > epsilon || abs(dRight) > epsilon
        let scaleY = abs(dTop) > epsilon || abs(dBottom) > epsilon
        guard scaleX || scaleY else { return [:] }

        let newWidth = bbox.width + dRight - dLeft
        let newHeight = bbox.height + dBottom - dTop
        // A window cannot invert. Refuse a degenerate extent outright rather
        // than emitting negative frames; per-member floors handle mere shrinks.
        guard newWidth > minimumSize.width, newHeight > minimumSize.height else { return [:] }
        let fx = newWidth / bbox.width
        let fy = newHeight / bbox.height

        var result: [Int: CGRect] = [:]
        for (id, startFrame) in startFrames {
            let current = releaseFrames[id] ?? startFrame
            var target = current
            if scaleX {
                target.origin.x = bbox.minX + dLeft + (startFrame.minX - bbox.minX) * fx
                target.size.width = max(minimumSize.width, startFrame.width * fx)
            }
            if scaleY {
                target.origin.y = bbox.minY + dTop + (startFrame.minY - bbox.minY) * fy
                target.size.height = max(minimumSize.height, startFrame.height * fy)
            }
            let moved = abs(target.minX - current.minX) > epsilon
                || abs(target.minY - current.minY) > epsilon
                || abs(target.width - current.width) > epsilon
                || abs(target.height - current.height) > epsilon
            if moved { result[id] = target }
        }
        return result
    }
}
```

- [ ] **Step 4: Run the tests, watch them pass** (expect 201 tests, 0 failures)
- [ ] **Step 5:** Confirm Core purity: `grep -rn "import AppKit\|import CryptoKit" Sources/MacTLMCore` → empty
- [ ] **Step 6: Commit** — `feat: proportional group scaling math for outer-edge resizes`

---

## Task 2: Resize session in `MagnetDragSession`

**File:** modify `Sources/MacTLM/MagnetDragSession.swift`.

No unit tests — no headless surface for a mouse-up-terminated session; Task 3's live protocol covers it. Everything below threads through code that already exists; do not duplicate geometry, suppression, or write policy.

- [ ] **Step 1** Add session state, parallel to `Drag`:

```swift
private struct Resize {
    let windowID: Int
    let bundleID: String
    /// Frames of every live member at session start, keyed by window id —
    /// the dragged window's is its pre-gesture frame.
    let startFrames: [Int: CGRect]
    /// Live members at session start, for back-to-front application.
    let members: [PersistenceCoordinator.LiveMember]
    let outerEdges: Set<MagnetMating.Edge>
    let mouseUpMonitor: Any?
}
private var resize: Resize?
```

- [ ] **Step 2** Open the session inside `handleResized`, *after* the no-op guard and *after* the group/live-member resolution that already exists there (reuse `previous`, `group`, and `live` — do not resolve twice):
  - Only while `NSEvent.pressedMouseButtons & 1 != 0` (programmatic resizes never open sessions) and `live.count > 1`.
  - If a session for a *different* window is open, end it **without settling** (mirror of the move-session honesty rule), then open fresh.
  - If a session for the *same* window is already open, do nothing here — the release frame is read at mouse-up, not accumulated.
  - `startFrames` = each live member's current frame, with the dragged window's replaced by `previous`. `outerEdges` = `MagnetScale.outerEdges(of: previous, among: <other members' frames>, gap: Self.gap)`.
  - Install the `.leftMouseUp` global monitor calling `finishResize()`.
  - `trace("resize session open win=… outer=…")`.
- [ ] **Step 3** Keep the existing live shared-edge propagation in `handleResized` byte-for-byte — it runs per event regardless of the session. The move-session kill (`ending session … really resized`) also stays.
- [ ] **Step 4** `finishResize()`:
  - Remove the monitor; clear `resize` (safe to call twice, like `endDrag`).
  - Build `releaseFrames`: for each session member, `monitor.lastKnownFrame(ofWindow:)`, falling back to a fresh `driver.windows(ofBundleID:)` lookup, falling back to its start frame.
  - `MagnetScale.settle(startFrames:releaseFrames:changed:outerEdges:)`. Empty → trace and return.
  - Apply back-to-front (`PersistenceCoordinator.backToFront`) through the existing `write(_:to:bundleID:)`, which already records suppression — settle echoes must not re-enter mating, propagation, or session-opening.
  - `trace("resize settle moved=… of=…")`.
- [ ] **Step 5** `deinit` also tears down the resize monitor.
- [ ] **Step 6** Verify: `swift build` clean; `swift test` 201/0 (Core untouched by this task); `./scripts/make-app.sh` green. Do NOT launch the app.
- [ ] **Step 7: Commit** — `feat: settle outer-edge resizes by scaling the group as one window`

---

## Task 3: Live acceptance and tag (human-driven; do not attempt from an agent)

- [ ] **Step 1** `./scripts/install.sh`; daemon running, login item enabled.
- [ ] **Step 2 — outer edge.** Mate two windows side by side. Drag the pair's outermost right edge outward and release: on release both windows widen proportionally and the gap grows slightly. The far (left) side of the group must not move.
- [ ] **Step 3 — outer corner.** Drag an outer corner diagonally: both axes scale on release.
- [ ] **Step 4 — mixed corner.** Drag the corner between a shared and an outer edge: the mate follows the shared axis live (Shrink/Nudge), and the outer axis settles on release without undoing the live adjustment.
- [ ] **Step 5 — floor.** Shrink brutally: members stop at the 240×160 floor; nothing inverts or oscillates.
- [ ] **Step 6 — non-group.** Resize an ungrouped window: perfectly ordinary macOS behavior, no settle.
- [ ] **Step 7** Update `docs/BACKLOG.md` (shipped row, test count, acceptance note, any new platform finding) and tag `v0.8.0-m3c`.

---

## Plan self-review notes

- **Spec coverage:** gesture contract §1 → Tasks 1–2; settle-on-release §2 → Task 2; per-axis math §3 → Task 1 (`testUnscaledAxisKeepsReleaseValues` is the load-bearing test — it proves the settle composes with live propagation instead of undoing it); omissions §6 respected (no preview, no modifier, no persistence change).
- **Risk — release frames:** `lastKnownFrame` may trail the final AX event by one notification. The driver fallback bounds the error; if Task 3 shows a systematic one-event lag, read the dragged window's frame directly from the driver at mouse-up.
- **Risk — suppression interplay:** settle writes mates *and* the just-released window. The window under the cursor is no longer gripped after mouse-up, so correcting it cannot fight the drag; its echo is suppressed like any other write.
- **Deliberate omission:** no session persistence, no UI. A resize session is pure gesture state and dies with the process.
