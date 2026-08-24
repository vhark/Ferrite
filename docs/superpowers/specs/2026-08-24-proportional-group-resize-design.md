# Proportional Group Resize — Design

- **Date:** 2026-08-24 · **Status:** Approved design, pre-implementation
- **Baseline:** `v0.7.0-m3b` (190 tests). Extends the M3b magnet-group resize contract.

## 1. Gesture contract

A magnet group resizes like **one combined window**. For a grouped window with two or more live members:

- **Shared edge** (a live mate flush against it): unchanged — live Shrink/Nudge propagation, exactly as shipped in M3b.
- **Outer edge** (no mate flush against it): dragging it scales the whole group along that axis.
- **Outer corner** (two unshared perpendicular edges): scales the group along both axes.
- A corner mixing one shared and one outer edge does both: the shared axis propagates live, the outer axis scales the group.

Consequence, chosen deliberately: a member can no longer be resized individually by its outer edge. Members are adjusted via shared edges and weights only. Ungroup first to resize one window freely.

## 2. Mechanism — settle on release

When the user drags an outer edge, macOS gives the dragged window the **full** delta; its proportional share is smaller. Correcting it mid-drag fights the user's grip (macOS reasserts on the next pointer move — visible jitter, the oscillation class the suppression set exists to prevent). So:

- **During the drag:** the dragged window stretches freely (macOS default). Shared-edge propagation still runs live per event, as today.
- **On mouse-up:** compute the outer-edge deltas and remap every member — including the dragged window — to its proportional share. One write pass, back-to-front, through the existing suppression set.

Mirrors the mating gesture: act on release, never against the grip.

### Resize session

Symmetric with the M3b move session, living in `MagnetDragSession`:

- **Opens** on the first genuine (width/height actually changed) resize event of a grouped window, only while the left mouse button is held (programmatic resizes never open sessions). Captures at open: the window's session-start frame (`lastKnownFrame` before the event), the group's live members and their session-start frames, and the per-edge shared/outer classification — all from session-start geometry, never mid-drag.
- **Tracks** the dragged window's latest frame on subsequent events. Shared-edge live propagation continues untouched.
- **Closes** on mouse-up (global `.leftMouseUp` monitor, same pattern as mating): if any outer-edge delta exceeds 0.5pt, settle; then remove the monitor. A resize event for a *different* window replaces the session without settling (mirror of the move-session honesty rule). All settle writes are recorded in the suppression set, so their echoes cannot re-enter mating, propagation, or session-opening.

## 3. Core math — `MagnetScale` (pure, TDD)

```swift
// Sources/MacTLMCore/MagnetScale.swift
MagnetScale.outerEdges(of: CGRect, among: [CGRect],
                       gap: CGFloat = 8, tolerance: CGFloat = 12)
    -> Set<MagnetMating.Edge>      // reuses the one gesture-edge vocabulary

MagnetScale.settle(startFrames: [Int: CGRect],    // session-start, all live members
                   releaseFrames: [Int: CGRect],  // at mouse-up, post live propagation
                   changed: Int,
                   outerEdges: Set<MagnetMating.Edge>,
                   minimumSize: CGSize)
    -> [Int: CGRect]               // only members that must move; may include `changed`
```

**Per-axis remap.** An axis participates only if an outer edge on that axis moved more than 0.5pt (delta = `releaseFrames[changed]` vs `startFrames[changed]` on that edge). For a participating axis: old extent = the session-start bounding box; new extent = old with the outer-edge deltas applied; every member's session-start fractional position and size on that axis map into the new extent. For a non-participating axis, release-time values are kept untouched — this is what preserves a live shared-edge adjustment made during the same drag instead of undoing it.

- Width and height scale independently (a real corner drag is not aspect-locked).
- Gaps scale proportionally — the literal one-window metaphor; the 8pt gap drifts at extreme scales, accepted.
- Per-member floor: width/height clamped up to `minimumSize` at the remapped origin; overlap at extremes is accepted, same stance as `GroupLayoutSolver.clamp`.
- No outer delta → empty result. No weights involved: scaling preserves current fractions; weights remain a reflow concept.

**Edge classification** (`outerEdges(of:among:)`): an edge is shared when some mate's facing edge is within `gap + tolerance` and the perpendicular extents overlap; outer otherwise. Same adjacency semantics as `MagnetResize`, exposed publicly so the AppKit layer never re-derives geometry.

## 4. AppKit wiring

`MagnetDragSession` gains the resize session state (dragged window id, session-start frames, classification, mouse-up monitor). `handleResized` keeps its no-op guard (finding 23) and its live shared-edge propagation; it additionally opens/updates the resize session. The settle applies with the established write policy: set, read back, one retry, accept — back-to-front so stacking survives. Persistence needs nothing new: the tracker's coarse activity signal still fires for suppressed events, so settled frames are captured by the normal debounced save.

## 5. Testing

- **Core (TDD, ~10 tests):** proportional share for the dragged window (not the full delta); corner scales both axes; untouched-axis preservation with release ≠ start frames; left-edge (origin-moving) deltas; gap scaling; floor clamping; no-outer-delta → empty; classification shared/outer/corner-graze cases.
- **AppKit:** live protocol — no headless surface for mouse-up-terminated sessions. `MACTLM_TRACE_DRAG=1` (finding 23) already traces resize events and will trace session open/settle.

## 6. Deliberate omissions

- **No live preview of the new bounding box during the drag.** Candidate refinement if release-settle feels blind in live testing; the overlay pattern exists if wanted.
- **No modifier-key variant.** Rejected as an invisible mode; plain gesture per the request.
- **No aspect lock, no weight coupling, no persistence-format change.** Groups store nothing new; the gesture only moves windows.

## 7. Known limits

- At extreme shrinks, per-member floors compress the arrangement unevenly and may overlap — same behavior class as solver clamping.
- A keyboard/AppleScript resize while the button happens to be held is indistinguishable from a drag; the settle would still run. Harmless: it produces the same proportional result.
- Classification uses session-start geometry; a group whose members drifted apart (never re-mated) classifies everything as outer and scales as a loose cluster — the honest reading of its actual geometry, consistent with M3b's "adjacency is recomputed from live geometry" stance.
