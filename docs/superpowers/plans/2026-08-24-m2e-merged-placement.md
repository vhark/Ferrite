# M2e — Per-App Merged Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** retire the M2b residual — an app with windows on two displays in a bundle gets exactly one window assignment per launch, with absolute target rects and display-aware order fallback.

**Spec:** `docs/superpowers/specs/2026-08-24-merged-placement-design.md` — read it first. The defect anatomy (three composing faults with file:line) and the contract live there.

**Baseline:** `main` at `v0.9.0-m3d`, 205 tests passing.

Unlike prior plans, this one specifies contracts and tests rather than verbatim code: the touched files have evolved across four milestones, so read the actual sources at the spec's file:line anchors before writing. The tests below are the contract; if an implementation detail conflicts with a test, the test wins.

---

## Task 1: Core — merged placements and display-aware fallback (TDD)

**Files:** modify `Sources/MacTLMCore/MultiApplyPlanner.swift`, `Sources/MacTLMCore/WindowMatcher.swift`, `Sources/MacTLMCore/RestoreEngine.swift`; tests in `Tests/MacTLMCoreTests/MergedPlacementTests.swift` (new) and additions to `WindowMatcherTests` if that file exists (check).

- [ ] **Step 1 — write the tests first.** Two-display fixtures: displays `"A"` (visibleArea x 0-2000) and `"B"` (x 2000-4000), one app `"arc"` with one saved entry per display. Required tests, names indicative:
  1. `testMergedPlacementsCarryAbsoluteRectsAndUniqueSlots` — `MultiApplyPlanner.plan` output for two items with one `arc` entry each: `placements["arc"]` has 2 entries, slots unique, each `targetRect` inside its own display's visibleArea (the absolute rect from that display's denormalization).
  2. `testCrossDisplayClaimRegression` — the residual itself. Two live `arc` windows, one centered on each display, records with `titleHash: nil` (uncertain identity). Pre-fix behavior (per-display assign against the global list) claims B's window for A. Post-fix: single assign with affinity → the window currently on A gets A's record, B's gets B's. Assert both target rects land on the window's own display.
  3. `testAffinityOnlyAffectsOrderFallback` — a titleHash match pointing "across" displays must still win over affinity (identity outranks geometry).
  4. `testFreshLaunchFallsBackToGlobalOrder` — both windows centered on display A (just-launched cascade), records for A and B: assignment degrades to stable global order, both windows assigned, no crash, no window left unmatched while a record goes begging.
  5. `testGlobalCountGate` — 2 records (one per display), 1 live window, `allowOrderFallback` honoring the global count gate: order fallback withheld (1 < 2), pin/hash still allowed — same gate semantics as today but with global totals.
  6. `testNilAffinityIsByteCompatible` — `WindowMatcher.assign(records:to:allowOrderFallback:)` with no affinity produces identical results to before (guard: run an existing scenario from the current tests through both call shapes).
  7. `testAbsolutePlacementUsesTheEngineClampPolicy` — the new `RestoreEngine` absolute-rect entry sets, reads back, retries once, then accepts, per existing policy (FakeDriver clamp scenario mirroring the existing restore tests).
  8. `testWindowsBucketByCenterWithNearestFallback` — the affinity bucketing helper: center containment, nearest-center for a straddling window (reuse `SnapshotPlanner.assign` — do NOT duplicate it; if it needs exposing, expose it).
- [ ] **Step 2 — run, watch them fail.**
- [ ] **Step 3 — implement.**
  - `MultiApplyPlanner.plan` additionally emits `placements: [String: [MergedPlacement]]` (`MergedPlacement{slot, targetRect, zIndex, titleHash, pinPattern, displayID}`), slots globally unique in item order. Reuse the absolute rect `TemplateApplyPlanner` already computes (:92) — thread it through rather than recomputing.
  - `WindowMatcher.assign` gains `affinity: Affinity? = nil` (`Affinity{recordDisplays: [Int: String], windowDisplays: [Int: String]}`). ONLY the order-fallback phase consults it: same-display record/window pairs zip first (stable order), leftovers zip globally. Pin and hash phases untouched. This stays the single identity path (BACKLOG finding 20) — no new matcher type.
  - `RestoreEngine` gains an absolute placement entry (suggested `place(assignments: [(window: DriverWindow, target: CGRect)])` or equivalent) sharing the existing clamp policy — extract, don't duplicate.
- [ ] **Step 4 — run, watch them pass.** Expect 205 + your new tests, 0 failures; state the exact total.
- [ ] **Step 5 — Core purity:** `grep -rn "import AppKit\|import CryptoKit" Sources/MacTLMCore` empty.
- [ ] **Step 6 — commit:** `feat: merged per-app placement with display-aware matching`

---

## Task 2: Template path consumes the merge

**Files:** modify `Sources/MacTLM/TemplateLauncher.swift`; `Sources/MacTLM/PersistenceCoordinator.swift` only if a wiring signature forces it.

- [ ] **Step 1** `place()` iterates the merged `placements` per app: bucket live windows by display (the Task 1 helper), build the affinity, one `WindowMatcher.assign` per app, place via the absolute-rect engine entry. The per-display loop over `multi.items` remains only for whatever non-placement concerns it still carries (stage handling, launch bookkeeping) — read it and say what stayed.
- [ ] **Step 2** `activateAndRaise` consumes the same per-app assignment (compute once, pass through — no second assign). Raising semantics (backmost-first, ~60ms spacing, per-app raise order) unchanged.
- [ ] **Step 3** In-flight/settle handling (`InFlight`, launch deadlines, late-arrival restacking) must keep working for launched-missing apps: when a launched app's windows finally settle, the merged assignment path is what places them. Read the current settle flow before touching; report how the merged path plugs in.
- [ ] **Step 4** Verify: `swift build` clean; `swift test` all green (same count as Task 1); `./scripts/make-app.sh` green; do NOT launch the app.
- [ ] **Step 5 — commit:** `feat: bundle launches place each app once, across displays`

---

## Task 3: Live acceptance and tag (human-driven; requires the SECOND DISPLAY awake)

- [ ] **Step 1** Open the laptop lid / attach the second display; `./scripts/install.sh`.
- [ ] **Step 2** Arrange one app (Arc) with one window on each display plus the usual members; Save Current Arrangement as a bundle.
- [ ] **Step 3** Quit Arc. Launch the bundle from the menu/hotkey: each Arc window lands on its own display — the exact scenario the residual made unreliable.
- [ ] **Step 4** Repeat with Arc left running but both windows dragged to one display: bundle launch returns each to its home display (adopt-running affinity is only a fallback signal — hash/pin identity should drive this; note which phase matched, via trace or store inspection).
- [ ] **Step 5** Single-display regression: with the second display asleep, a normal bundle launch behaves exactly as before.
- [ ] **Step 6** `docs/BACKLOG.md`: move the residual out of *Accepted residuals*, shipped row, test count, acceptance note, any finding. Tag `v0.10.0-m2e`.

---

## Plan self-review notes

- **Test-contract stance:** code specifics are deliberately not verbatim here; the sources moved across four milestones. Tests 2, 3 and 6 are the load-bearing ones: the regression itself, identity-outranks-geometry, and the promise that every existing call site is untouched by default.
- **Risk — settle path:** launched-missing apps place on settle, not at launch; if the settle path still routes through the old per-display restore, the residual survives for launched apps while looking fixed for adopted ones. Task 2 Step 3 exists so this is confronted, not discovered live.
- **Risk — `SnapshotPlanner.assign` exposure:** it may be internal to the snapshot flow; exposing it must not fork the containment/nearest logic into two copies.
- **Deliberate omission:** no affinity for pin/hash phases, no automatic-restore changes, no UI.
