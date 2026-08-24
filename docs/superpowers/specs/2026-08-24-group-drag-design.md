# Group Drag and Drag-Away Un-mate — Design

- **Date:** 2026-08-24 · **Status:** Approved design, pre-implementation
- **Baseline:** `v0.8.0-m3c` (202 tests). Extends the M3b move-session contract.

## 1. Gesture contract

- **⌘ + title-bar drag on any group member** picks up the whole group: every other live member follows the drag live, keeping the cluster's internal arrangement pixel-for-pixel. macOS's own ⌘-drag semantics (move without activating) still apply to the window under the cursor; the behaviors compose. Consequence, accepted by the user over the recommended ⌥: a *grouped* window can no longer be ⌘-dragged solo. Ungrouped windows keep pure macOS behavior.
- **Plain title-bar drag** keeps today's meaning — move one window, blue preview, mate on release — plus one new consequence: releasing a member **flush against no fellow live member removes it from the group**. Groups dissolve below two members. This makes the user's existing mental model ("drag away = out of the group") real; previously membership silently survived and the next group reflow/scale yanked the runaway back.
- Un-mate runs **before** the mate step on release, so dragging a window from group A onto group B moves it A→B instead of unioning A∪B. Transitive merging now requires clusters to actually touch.

## 2. Mechanism

### Cluster mode (inside the existing move session)

- At session open, sample `NSEvent.modifierFlags.contains(.command)`; with ⌘ held and the dragged window resolving (certain identity) to a group with ≥2 live members, the session opens in cluster mode, capturing the dragged window's start frame and every follower's `(member, startFrame)`.
- Per moved event: each follower is written to `followerStart + (draggedNow.origin − draggedStart.origin)` — absolute from session start, no incremental drift — through the existing suppressed `write()`. Followers are not under the user's grip, so live translation cannot fight the mouse; the settle-on-release rationale from M3c does not apply here.
- Mating and the snap overlay are disabled in cluster mode. Mouse-up closes the session; nothing settles, no un-mate check (adjacency is preserved by construction).
- Contingency if live follow ever lags with many followers: throttle follower writes; never switch to settle.

### Un-mate on release (plain mode only)

- On mouse-up, after the snap decision but before `remember()`: resolve the dragged window's `(bundleID, slot)`; if it belongs to a group, test its released frame for adjacency against each fellow **live** member's current frame. Flush to none → remove membership via a new `PersistenceCoordinator.unmate(bundleID:slot:)` (mutate through the tracker, drop dissolved groups, immediate flush — never the store file). Flush to at least one → membership stands.
- Unresolvable identity → no membership change (honest degradation, as in M3b: geometry may move, memory only changes when identity is certain).

## 3. Core addition

`MagnetScale.isAdjacent(_:to:gap:tolerance:) -> Bool` — public any-edge flush test wrapping the existing private per-edge `isFlush`, so the membership decision uses the same adjacency semantics as resize propagation and outer-edge classification. TDD'd; the AppKit layer never re-derives geometry.

## 4. Deliberate omissions

- No persistence-format change, no menu change, no new UI. Membership edits ride the existing group store.
- No cluster-drag preview or ghosting — the followers moving live *is* the feedback.
- No modifier configurability; ⌘ is the contract until lived experience says otherwise.

## 5. Known limits

- ⌘-dragging a grouped window solo is impossible by design; pull it out (plain drag) first if needed.
- Cross-display cluster carry translates followers by the same delta; macOS may clamp followers that land off-screen, and the accepted frames stand (standard write policy).
- A follower whose app rejects mid-carry writes trails the cluster; the next moved event re-asserts it (absolute-from-start targets self-heal).
