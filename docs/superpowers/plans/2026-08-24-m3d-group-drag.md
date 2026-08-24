# M3d — Group Drag and Drag-Away Un-mate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘-dragging any member of a magnet group carries the whole group live; plain-dragging a member away from its group removes its membership on release.

**Spec:** `docs/superpowers/specs/2026-08-24-group-drag-design.md` — read it first.

**Baseline:** `main` at `v0.8.0-m3c`, 202 tests passing.

---

## Task 1: `MagnetScale.isAdjacent` (Core, TDD)

**Files:** modify `Sources/MacTLMCore/MagnetScale.swift`, `Tests/MacTLMCoreTests/MagnetScaleTests.swift`.

- [ ] **Step 1: Add 3 tests** to the existing `MagnetScaleTests`:

```swift
    // MARK: - Adjacency (membership decisions ride the same geometry)

    func testFlushNeighboursAreAdjacent() {
        XCTAssertTrue(MagnetScale.isAdjacent(left, to: right),
                      "an 8pt-gap mate is adjacent on any edge")
    }

    func testDistantWindowsAreNotAdjacent() {
        let far = CGRect(x: 3000, y: 0, width: 500, height: 500)
        XCTAssertFalse(MagnetScale.isAdjacent(left, to: far))
    }

    func testCornerGrazeIsNotAdjacent() {
        // Diagonal neighbour: near in both axes but zero perpendicular overlap.
        let diagonal = CGRect(x: 1000, y: 1008, width: 500, height: 500)
        XCTAssertFalse(MagnetScale.isAdjacent(left, to: diagonal),
                       "touching corners is not being mated")
    }
```

- [ ] **Step 2: Run, watch them fail** ("has no member 'isAdjacent'")
- [ ] **Step 3: Implement** in `MagnetScale`, above `outerEdges`:

```swift
    /// True when any edge of `frame` is flush against `other` — the same
    /// adjacency semantics as resize propagation and outer-edge
    /// classification, exposed so membership decisions never re-derive
    /// geometry.
    public static func isAdjacent(_ frame: CGRect, to other: CGRect,
                                  gap: CGFloat = 8,
                                  tolerance: CGFloat = 12) -> Bool {
        let all: [MagnetMating.Edge] = [.left, .right, .top, .bottom]
        return all.contains {
            isFlush(frame, other, edge: $0, gap: gap, tolerance: tolerance)
        }
    }
```

- [ ] **Step 4: Run, watch them pass** (expect 205 tests, 0 failures)
- [ ] **Step 5: Commit** — `feat: public adjacency test for membership decisions`

---

## Task 2: Cluster mode and un-mate on release

**Files:** modify `Sources/MacTLM/MagnetDragSession.swift`, `Sources/MacTLM/PersistenceCoordinator.swift`.

No unit tests — mouse-driven session behavior has no headless surface; Task 3's live protocol covers it. Reuse existing code paths; never re-derive geometry, suppression, or write policy.

- [ ] **Step 1 — coordinator.** Add `func unmate(bundleID: String, slot: Int)`: find the group containing that member, `MagnetGroup.remove(bundleID:slot:)`, drop the group if `isDissolved`, `tracker.setMagnetGroups`. No-op when no group contains the member. Shaped like `ungroup(_:)`.
- [ ] **Step 2 — cluster capture.** Extend the move session's `Drag` struct with:

```swift
    struct Cluster {
        let draggedStart: CGRect
        /// Fellow live members and their frames at session start.
        let followers: [(member: PersistenceCoordinator.LiveMember, start: CGRect)]
    }
    let cluster: Cluster?
    /// The dragged window's frame at the most recent moved event, for the
    /// release-time adjacency test.
    var lastFrame: CGRect
```

  In `openDrag`, after the eligibility guard: if `NSEvent.modifierFlags.contains(.command)`, resolve the dragged window through `coordinator.slot(forWindowID:bundleID:)` → `magnetGroups()` → `liveMembers(of:)`; with ≥2 live members build `Cluster` (followers exclude the dragged window; `draggedStart` is the event frame). Otherwise `cluster = nil`. Trace session mode and follower count.
- [ ] **Step 3 — cluster follow.** In `handleMoved`, when the open session has a cluster: update `lastFrame`, then for each follower `write(follower.start.offsetBy(dx: now.minX - draggedStart.minX, dy: now.minY - draggedStart.minY), to: follower.member.window, bundleID: …)`. Skip `updateCandidate` entirely (no mating, no overlay) — hide the overlay defensively on cluster-session open. Plain sessions keep today's path byte-for-byte, plus the one-line `lastFrame` update.
- [ ] **Step 4 — release.** In `finishDrag`:
  - Cluster session: `endDrag()` and return — nothing to settle, no un-mate.
  - Plain session: keep the existing snap logic, then BEFORE `remember(…)`: resolve `(bundleID, slot)`; if a group contains it, adjacency-test the released frame (`candidate?.snapped ?? lastFrame`) against each fellow live member's current frame with `MagnetScale.isAdjacent`. Flush to none → `coordinator.unmate(bundleID:slot:)`, trace `"unmated <bundle>#<slot>: released away from its group"`. Then the existing `remember(…)` runs (a snap onto another group's window now joins that group cleanly instead of unioning).
- [ ] **Step 5** Verify: `swift build` clean; `swift test` 205/0; `./scripts/make-app.sh` green (signing is silent). Do NOT launch the app or click menus.
- [ ] **Step 6: Commit** — `feat: command-drag carries the group; drag-away leaves it`

---

## Task 4 (amendment, added after live feedback): Ghost-outline carry

**Why:** Live acceptance confirmed the gesture but reported follower lag. Root cause: each follower update is a synchronous AX write into the target app's main thread, all sequential per moved event — one busy member (Illustrator) stalls every tick. macOS offers no API to freeze another app's rendering, so the honest equivalent of the user's "don't render contents until movement stops" is ghost outlines: zero mid-drag IPC, one real write per follower at release.

**Files:** create `Sources/MacTLM/MagnetGhostOverlay.swift`; modify `Sources/MacTLM/MagnetDragSession.swift`.

- [ ] **Step 1 — ghost overlay.** `MagnetGhostOverlay` manages one borderless, non-activating panel per follower (same panel recipe as `MagnetSnapOverlay`: clear, `ignoresMouseEvents`, `.floating`, `[.canJoinAllSpaces, .stationary]`). Each draws a rounded outline (2pt `controlAccentColor` stroke, ~10% alpha fill, 8pt corner radius). API: `show(frames: [CGRect])` (CG space; convert via `ScreenGeometry.nsRect(fromCG:)` — never re-derive the flip), `translate(to delta: CGVector)` repositioning every panel from its shown origin by the delta (absolute-from-start, no drift), `hide()`. Panels move with `setFrameOrigin` — window-server ops, no IPC.
- [ ] **Step 2 — cluster session rewiring.** At cluster-session open: show ghosts at the followers' start frames, record the base mouse location (`NSEvent.mouseLocation`), and install a global `.leftMouseDragged` monitor driving `ghosts.translate(to:)` from the mouse delta (Cocoa space end-to-end for ghosts — same-space deltas need no conversion; only frames cross spaces). Delete the per-moved-event follower `write()` loop; AX moved events in cluster mode now only update `lastFrame`.
- [ ] **Step 3 — release settle.** In `finishDrag` for cluster sessions: hide ghosts, remove both monitors, read the dragged window's released frame from the driver (source of truth — includes any OS clamping the mouse math would miss), delta = released.origin − draggedStart.origin, write each follower `start + delta` once through the existing suppressed `write()`. Trace `"cluster settle followers=<n> delta=<dx>,<dy>"`.
- [ ] **Step 4 — teardown.** The dragged monitor and ghosts are also torn down in `endDrag()` and `deinit` — a stuck ghost is worse than no ghost (same rule as the snap overlay).
- [ ] **Step 5** Verify: `swift build` clean; `swift test` 205/0; `./scripts/make-app.sh` green; app never launched.
- [ ] **Step 6: Commit** — `feat: ghost-outline cluster carry; followers settle once on release`

---

## Task 3: Live acceptance and tag (human-driven; do not attempt from an agent)

- [ ] **Step 1** `./scripts/install.sh`; daemon running, login item enabled.
- [ ] **Step 2 — cluster carry.** ⌘-drag a member by its title bar: the whole group follows live, arrangement intact, no blue overlay. Release anywhere; the group stays mated and the Groups menu row is unchanged.
- [ ] **Step 3 — solo pull-out.** Plain-drag a member well away and release: it leaves the group (Groups row shrinks or disappears at <2). Reflow afterwards must NOT include the departed window.
- [ ] **Step 4 — A→B move.** With two groups, drag a member of A onto a window of B: it joins B, leaves A, and the groups do not union.
- [ ] **Step 5 — slide along.** Drag a member a short distance so it stays flush with a fellow member: membership survives.
- [ ] **Step 6** Update `docs/BACKLOG.md` (shipped row, test count, acceptance, findings) and tag `v0.9.0-m3d`.

---

## Plan self-review notes

- **Spec coverage:** §1 gesture contract → Task 2 Steps 2–4; §2 mechanism → Steps 3–4; §3 Core addition → Task 1; omissions respected (no UI, no format change, no configurability).
- **Risk — modifier sampling:** `NSEvent.modifierFlags` is sampled once at session open; a ⌘ pressed mid-drag does not convert the session (deliberate: no mid-drag mode flips, same stance as classification-at-open in M3c).
- **Risk — follower identity:** followers come from `liveMembers` (certain identity). A member whose window cannot be certainly identified simply does not follow — honest degradation, traced by follower count at open.
- **Deliberate omission:** `lastFrame` for the adjacency test may trail the very last mouse movement by one event; the 12pt adjacency tolerance dwarfs that error.
