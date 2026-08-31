# Tiling parity research — Magnet / Rectangle / Hyprland (Omarchy) vs Ferrite

2026-08-25. Sources: Magnet App Store listing + site, Rectangle README (full
action list, primary source), Omarchy manual hotkeys page (Hyprland defaults,
primary source). Purpose: what *basic* tiling features Ferrite lacks for
parity, filtered through Ferrite's philosophy — **not an auto-tiler; windows
stay free-floating; structure is opt-in**.

> **Read as of 2026-08-25.** The gap table below is about **single-window snap
> actions** (placing one window at a screen fraction), which is still unbuilt
> and remains the M5 candidate. It is a different axis from *reflow*, which
> arranges every window on a display or in a group at once. M6 has since
> shipped a BSP dwindle spiral, cascade, monocle, main-centre, mirrored
> main+side, and user-defined X×Y grid presets as reflows — so two rows below
> ("auto-tiling layouts", "sixths/ninths/eighths") now describe only what
> Ferrite lacks as a *snap* action, not what it can arrange. Nothing else in
> the table has changed.

## The field, by philosophy

| Tier | Tools | Model |
|---|---|---|
| Manual snap | Magnet, Rectangle, Spectacle | Hotkey/drag places ONE window at a screen fraction; no persistent structure |
| Auto-tiler | Hyprland (Omarchy), AeroSpace, yabai, Amethyst, i3/sway | Every window forced into a tree/layout; workspaces are the unit |
| Ferrite | — | Persistence + workspace snapshots + opt-in magnet groups |

Ferrite's closest philosophical neighbors are the manual-snap tier. That tier
is the parity bar users will measure Ferrite against; the auto-tiler tier is
mostly a different religion.

## What Ferrite already has that they don't

- Automatic per-app position persistence (nobody in either tier has this).
- Whole-workspace snapshot/restore with app launching + z-order (Magnet: none;
  Hyprland: workspaces hold live windows, nothing survives a quit).
- Magnet groups: mated clusters that carry/scale/resize as one; weighted
  treemap and preset reflows of a display or group.

## Gap analysis — the parity table

Basic actions, presence in Magnet (M), Rectangle (R), Hyprland/Omarchy (H):

| Action | M | R | H | Ferrite | Fit |
|---|---|---|---|---|---|
| Snap ONE window: left/right/top/bottom half | ✓ | ✓ | ✓ | ✗ | **P1** |
| Quarters (4 corners) | ✓ | ✓ | — | ✗ | **P1** |
| Thirds, two-thirds (L/C/R) | ✓ | ✓ | — | ✗ | **P1** |
| Maximize (not macOS fullscreen) | ✓ | ✓ | ✓ | ✗ | **P1** |
| Drag-to-screen-edge snap w/ footprint preview | ✓ | ✓ | — | ✗ | **P1** |
| Restore pre-snap frame ("unsnap") | ✓ | ✓ | — | ✗ | **P1** |
| Center window | ✓ | ✓ | — | ✗ | P2 |
| Almost-maximize / maximize-height | — | ✓ | ✓ | ✗ | P2 |
| Move window to next/previous display | ✓ | ✓ | ✓ | ✗ | P2 |
| Incremental grow/shrink (single window) | — | ✓ | ✓ | groups only | P2 |
| Repeat-to-cycle (thirds cycle, traverse displays) | — | ✓ | — | ✗ | P2 |
| Sixths/ninths/eighths grid fractions | ✓ (6ths) | ✓ | — | ✗ | P3 |
| Focus window by direction | — | — | ✓ | ✗ | P3 |
| Swap windows by direction | — | — | ✓ | ✗ | P3 |
| Scratchpad / sticky window | — | — | ✓ | ✗ | P3 |
| Auto-tiling layouts (dwindle/scrolling), float toggle | — | — | ✓ | by design ✗ | non-goal |
| Spaces/workspace switching, move-to-Space | — | ✗ (Pro only) | ✓ | ✗ | **non-goal** (AX cannot see other Spaces — guide already documents this; Rectangle hits the same wall) |
| Window gaps (configurable) | — | ✓ (padding) | ✓ | fixed 8pt mate gap | P3 knob |

## Recommendation — M5 candidate: "Snap actions"

**P1 is one coherent milestone**: hotkey + drag-edge placement of a single
window at screen fractions, with restore. It is THE thing a Magnet/Rectangle
user reaches for in the first minute, and every piece of machinery exists:

- `GroupLayoutSolver` already computes fractional rects — a snap action is the
  degenerate 1-window case of a preset (halves/quarters/thirds are `columns`/
  `grid` cells).
- KeyboardShortcuts 3.0.1 is integrated (per-bundle hotkeys); fixed
  action hotkeys are the same registration path with static `Name`s.
- `MagnetSnapOverlay` already draws drag previews; edge snap areas reuse the
  footprint pattern (finding 22's measured-reach lesson applies to edge zones).
- `WindowDriving.setFrame` + per-window frame records give restore-pre-snap
  for free — we already remember frames; snap just needs to stash the
  pre-snap frame before writing.
- Interactions to design: a snapped window that is a magnet-group member
  (probably: snap detaches, like drag-away un-mate); snap vs persistence
  capture (a snap is a normal move — tracker records it, nothing special).

P2 items (center, next-display, almost-maximize, incremental resize, cycling)
are small additions on the same action plumbing — ship-with or fast-follow.

P3 and non-goals: leave documented. Spaces remains impossible without private
APIs (Rectangle's README concedes the same); auto-tiling contradicts the
product; focus/swap-by-direction is Hyprland culture that macOS's Cmd+Tab and
Ferrite's raise-on-restore mostly cover.

## Omarchy/Hyprland ideas worth stealing later (not parity, flavor)

- `Super + K`-style cheat sheet: a "Hotkeys…" menu item listing every
  registered Ferrite shortcut (workspaces + future snap actions).
- Save/restore window width (H: `Super + Alt/+ Home`) — trivially a 1-entry
  persistence read.
- Omarchy's "toggle window gaps" as a mate-gap preference knob.
