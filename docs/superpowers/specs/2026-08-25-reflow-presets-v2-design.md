# Reflow presets v2 — design

2026-08-25. Approved in session. Research grounding:
`2026-08-25-tiling-parity-research.md` (Magnet/Rectangle/Hyprland survey).

## Goal

Grow the reflow system in three directions:

1. **Unambiguous targets.** Two glyph rows in the menu — "Reflow this
   display" (always) and "Reflow this group" (when the frontmost window is in
   an active group) — plus the same glyph row inside each group's Groups
   submenu. The current single row with a flipping header dies.
2. **New built-in presets** from the wider tiling world: main-center, mirrored
   main-side, BSP dwindle, cascade, monocle.
3. **Custom presets**, defined in Preferences and pinned to the menu rows:
   fixed column counts, fixed X×Y grids, parameterized main-center.

Non-goals: auto-tiling (nothing reflows without an explicit action), zone
editors with arbitrary rects (FancyZones-style canvas — future, the enum
representation below doesn't preclude it), per-display custom preset sets.

## Solver additions (`FerriteCore/GroupLayoutSolver`)

All pure geometry, Linux-portable, property-tested like the existing six.

### New built-in cases

| Case | Semantics | Weights |
|---|---|---|
| `mainCenter(fraction: Double, sideCapacity: Int?)` | Heaviest tile centered at `fraction` of width; the remaining `(1 − fraction)` splits into two equal-width side columns, `(1 − fraction)/2` each. Remaining tiles fill the side stacks alternating (2nd → left, 3rd → right, …). `sideCapacity` caps each stack; overflow cycles back through side cells z-stacked. `nil` = unlimited (stacks grow). Built-in glyph uses `(0.6, nil)`. | reads |
| `bsp` | Dwindle spiral: recursive half-splits alternating vertical/horizontal, first split vertical. Even 50/50 splits in v1; weighted split ratios are a noted extension, not scoped. Placement follows the caller's front-to-back tile order rather than sorting by weight — which is the same thing, since callers pass frontmost (heaviest) first. | ignores |
| `cascade` | Every tile sized to 70% of the bounds' width and height (≈49% of its area), staggered diagonally from top-left by a fixed step chosen so the last window's stagger still fits (step = remaining space / (count−1), capped at 40pt). Back-to-front placement; frontmost tile ends nearest bottom-right and on top. | ignores |
| `monocle` | Every tile = full bounds (minus gap). Z-order untouched. | ignores |

### Custom (parameterized) cases

| Case | Semantics |
|---|---|
| `fixedColumns(Int)` | n equal columns. Windows fill left-to-right; windows beyond n wrap into new rows within the columns (row count = ceil(count/n)). Always fills — no empty zones. |
| `fixedGrid(columns: Int, rows: Int)` | **Fixed zones** (FancyZones semantics). Cells are fixed fractions of bounds; windows fill cells row-major, front-to-back. Fewer windows than cells → trailing cells stay empty, cells never stretch. More windows than cells → cycle back through cells, z-stacked. |
| `mainCenter(fraction:sideCapacity:)` | Same case as the built-in; the editor exposes both parameters (e.g. the user's 66% center with 4-tall sides = `(0.66, 4)`). |

`Preset` becomes `Equatable + Codable` (needed by the custom-preset store and
by `lastGroupPreset` reapply, which already keys on `Preset`).

### Ordering invariant

Tile order in = placement order out, for every preset: callers pass tiles
front-to-back, so "frontmost gets the best cell" holds everywhere (existing
convention; fixed grids and cascade make it observable).

## Custom preset store

New file `~/Library/Application Support/Ferrite/reflows.json` —
`ReflowStore` in FerriteCore, same fail-soft pattern as `LayoutLibraryStore`
but a fresh file, so finding 11's decode-wipe risk doesn't apply (empty
default is correct for a store that starts empty).

```json
{ "customPresets": [ { "id": "…", "name": "Wall 7×3",
                       "preset": { "fixedGrid": { "columns": 7, "rows": 3 } } } ] }
```

Also holds the display-reflow group policy (below), so reflow behavior syncs
across machines with the rest of the App Support directory.

## Display reflow × magnet groups

Display reflow gains a policy, **set in Preferences, indicated and togglable
in the menu**:

- **Explode groups (default).** Group members participate individually AND
  their groups are dissolved (exact `ungroup` semantics — membership removed,
  same code path as the Groups menu's Ungroup). Never leave a "group" whose
  members are scattered: stale membership with broken adjacency is the
  troubleshooting footgun the guide already warns about. **Scoping (corrected
  during implementation):** a group is dissolved if and only if the reflow
  actually wrote at least one of its live member windows. Dissolving every
  group with two or more live members — as this spec originally implied —
  discarded membership for groups on *other* displays that the reflow never
  touched, which finding 18 forbids.
- **Keep groups.** Each intact group (≥2 eligible windows on that display) is
  one tile: the solver places its bounding box, and members remap into the
  assigned cell via `MagnetScale.remap` (M3c machinery). Ungrouped windows are
  tiles as before. **As built:** the group tile is keyed by its frontmost
  eligible member's window id and carries that member's z-derived weight, so
  the group weighs exactly what that window would have weighed alone — rather
  than the sum of member weights this spec first proposed, which would have
  made a group outrank every solo window purely by size of membership.

Indication: a checkmark menu item directly under the display glyph row —
"Keep magnet groups together" — reading and writing the same stored policy
(dual surface like Launch at Login). Group rows are unaffected by the policy
(they always target exactly one group).

## Menu

```
Reflow this display
[glyph rows: built-ins + pinned customs, wrapped, max 8 per line]
· Keep magnet groups together        (checkmark toggle)
Reflow this group                    (frontmost window in an active group only)
[same glyph rows]
Groups ▸ <each group's submenu>
    [same glyph rows targeting that group]
…
```

- Built-in order: columns, rows, grid, symmetric, mainSide, mainSideMirrored,
  mainCenter, bsp, treemap C/L/R, cascade, monocle — then customs in the
  user's Preferences order. 13 built-ins + customs wrap at 8 per line.
- `PersistenceCoordinator.reflowDisplay(preset)` splits into
  `reflowDisplay(preset)` (always display, honoring the group policy) and
  `reflowGroup(preset, group)` (explicit target). `DisplayGroupReflow.apply`
  loses its frontmost-group override; its explicit
  `apply(_:to:live:)` group path already exists.
- `lastGroupPreset` reapply (Grow/Shrink) keeps working unchanged — presets
  are still `Preset` values.

## Preferences — new "Reflows" tab

- List of custom presets: name, type picker (Columns / Grid / Main center),
  steppers for the parameters, live glyph preview (PresetGlyph renders any
  `Preset`, so the preview is the solver's own answer and cannot lie).
- Add / remove / reorder. Rename inline. No cap enforced; the menu wraps.
- The display-reflow group policy toggle (same storage as the menu checkmark).
- Refresh path: the store fires a change hook (same pattern as
  `onLayoutLibraryChanged`) so the menu and an open Preferences window never
  go stale (finding 16 corollary).

## Glyphs

`PresetGlyph` renders every new preset with no new drawing code — each glyph
is the solver's answer for a representative tile count inside the glyph box:

- Count-adaptive presets keep 5 tiles (existing).
- `fixedGrid(c,r)` draws `c×r` tiles (a 7×3 glyph is a legible 21-cell mini
  grid at 44×30).
- `fixedColumns(n)` draws n tiles; `mainCenter` draws 1 + min(sideCapacity,2)
  per side; `cascade` draws 3 staggered tiles; `monocle` draws 1 full tile
  with a double border to distinguish it from a lone-window glyph.
- Accent tile stays the frontmost tile (existing convention).

## Testing

- Solver: extend the exhaustive property suite — non-overlap (except cascade,
  monocle, and overflow z-stacks, which assert exact expected overlap
  instead), bounds containment, cell-count and fill-order assertions for
  fixed grids (row-major, front-to-back), overflow cycling, mainCenter
  alternating fill and capacity cap, bsp split recursion depth, cascade
  stagger monotonicity, tile-order invariant everywhere.
- `ReflowStore`: round-trip, empty-default, unknown-key tolerance (future
  fields), policy default = explode.
- Menu, Preferences tab, group-as-tile remap: live protocol, per convention —
  acceptance includes the user's 66%/4-tall custom preset on the ultrawide
  and an explode-vs-keep comparison with a live magnet group.

## Milestone

Ships as **M6 (reflow presets v2)** — independent of M5 (snap actions);
either can land first. Both consume `GroupLayoutSolver` additions, but no
shared code beyond it.
