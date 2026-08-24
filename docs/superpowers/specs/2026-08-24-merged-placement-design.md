# Per-App Merged Placement — Design

- **Date:** 2026-08-24 · **Status:** Approved design, pre-implementation
- **Baseline:** `v0.9.0-m3d` (205 tests). Retires the M2b accepted residual: "One app with windows on two displays in a bundle — a window can be claimed by the wrong display's records."

## 1. The defect, precisely

A bundle launch loops **per display item** (`TemplateLauncher.place()` :114-119), and each iteration matches that display's records against the app's **global** window list (`RestoreEngine.restore` :22, `MacWindowDriver.windows(ofBundleID:)` has no display filter). Three composing faults:

1. Display A's records get first claim on display B's windows of the same app.
2. `TemplateApplyPlanner.matchingRecords` (:41-52) re-slots pseudo-records from 0 per display, so slots collide across displays.
3. The order-fallback gate (`RestoreEngine` :30) compares global window count against per-display record count.

`activateAndRaise` (:199-201) repeats the per-display assign for raising. The automatic restore path is symmetric (one assign per app, one area) and has no residual — it stays untouched.

## 2. Contract

**One assignment per app per bundle launch.** All display items' placements for a bundleID merge into a single record set with globally unique pseudo-slots, matched once against the app's global window list. Each placement carries its **absolute** target rect (already computed per display at `TemplateApplyPlanner` :92 and currently discarded) — placement never re-denormalizes against a single display's visible area.

**Display-aware order fallback.** Pin and titleHash matching stay display-blind (identity is identity). The order-fallback phase gains one signal: unmatched live windows are bucketed by their *current* display (`SnapshotPlanner.assign` semantics — center containment, nearest-center fallback), each display's remaining records zip against that display's windows first in stable order, and leftovers zip by global order. Effect: adopt-running windows stay on the display where the user left them; freshly launched windows (no meaningful current position) degrade to today's global order. The count gate becomes global records vs global windows.

**Single identity path (finding 20).** The display-aware fallback is an extension *inside* `WindowMatcher.assign` — an optional affinity parameter, `nil` for every existing call site — never a second matcher.

**Raising follows the merged assignment.** `activateAndRaise` consumes the same per-app assignment computed for placement instead of re-assigning per display.

## 3. Shape

- `MultiApplyPlanner` (already the merge point for stacking) additionally emits per-app merged placements: `[bundleID: [MergedPlacement{slot, targetRect, zIndex, titleHash, pinPattern, displayID}]]`, slots unique across the bundle.
- `WindowMatcher.assign` gains `affinity: Affinity? = nil` where `Affinity{recordDisplays: [slot: displayID], windowDisplays: [windowID: displayID]}`; used only by the order-fallback phase.
- `RestoreEngine` gains an absolute-rect placement entry (same set / read-back / one-retry / accept policy) used by the template path; the normalized `restore` stays for the automatic path.
- `TemplateLauncher.place` iterates **apps**, not displays; `activateAndRaise` takes the merged assignment.

## 4. Testing

All logic is Core-pure: two-display fixtures run in unit tests on a single-display machine. Required coverage: the cross-display claim regression (pre-fix, display A's records claim B's window; post-fix each lands home), slot uniqueness across items, global count gating, adopt-running affinity, fresh-launch fallback to global order, absolute rects surviving with no denormalization, existing single-display behavior byte-identical (`affinity: nil` path unchanged).

**Live acceptance requires the second display awake** (laptop lid open). Protocol: one app (Arc) with a window on each display saved in a bundle; quit; relaunch via hotkey; each window lands on its own display. Until then the residual moves from "accepted" to "pending verification" — never silently dropped.

## 5. Deliberate omissions

- No change to capture, automatic restore, groups, gestures, UI, or store format.
- No affinity in pin/hash phases: certain identity outranks geometry by design.
- No cross-Space or cross-machine awareness — same scope as everything else.
