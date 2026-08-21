# MacTLM — Product Requirements Document

**Date:** 2026-08-19 · **Status:** Approved design, pre-implementation · **Working title:** MacTLM (rename freely)

## 1. Product definition

MacTLM is a free, open-source macOS menu-bar window layout manager. It is **not** a classic auto-tiler: windows remain free-floating and may overlap. The app remembers window positions, restores them automatically, launches whole workspaces from saved layouts, and lets windows behave as magnetized assemblies with one-action preset reflows — including a novel weighted-treemap layout family.

Linux support is a declared future goal ("Mac first"). The architecture isolates all macOS-specific code behind a driver seam so the layout logic ports unchanged (§6.2).

### Pillars (build order)

1. **Position persistence** — every app's window frames are remembered automatically and restored on app relaunch, login, and display-configuration changes.
2. **Workspace templates** — snapshot the current arrangement as a named, hotkey-launchable layout that launches missing apps and places everything.
3. **Magnet groups** — windows snap edge-to-edge into linked assemblies with shared-edge resizing and preset reflows (columns, rows, grid, main+side, weighted treemap, symmetric).

### Audience & distribution

Personal tool first — the author's daily workflow is the spec — published as open source (MIT) on GitHub, later a Homebrew cask with a notarized direct download. **Never the App Store**: the Accessibility API is incompatible with sandboxing.

### Success criteria

- The author's daily "Design + Comms" workspace (§9) launches from one hotkey after a clean login and lands pixel-faithful.
- Quitting and relaunching any daily app restores its windows without interaction.
- A stranger can install and onboard (grant one permission) without hand-holding.

## 2. Explicit non-goals

- Classic tiling tree (i3/yabai/AeroSpace style). Magnet groups are the tiling story, permanently.
- macOS Spaces integration or any SIP-disabling technique (yabai-style scripting additions).
- Window animations, focus-follows-mouse, app-content awareness.
- App Store distribution.
- v1 UI for editing layouts geometrically — layouts are edited by re-snapshotting.

## 3. Feature requirements

### 3.1 Phase 1 — Position persistence (M1)

- **Automatic for all apps**, with a user-editable exclude list. Ships with a default exclude list seeded from Rectangle's known-hostile set (apps that fight external frame changes).
- **Reapply triggers:** app launch, user login, and display-configuration change. Manual window moves are respected until the next reapply trigger; persistence is never continuously enforced (that behavior belongs to magnet groups, and only within a group).
- **Multi-window apps:** N remembered windows → N restored frames. Matching is heuristic (window count, window-identity hash, creation order). Optional **pin rules** map a title pattern to a specific remembered slot (e.g. an Arc profile name) when identity matters. Pin patterns are user-authored and matched against *live* titles at match time, so they work without any title being stored.
- Frames are captured on window move/resize (debounced ~2 s) and on app quit.

### 3.2 Phase 2 — Workspace templates (M2)

- **Capture = snapshot.** Arrange windows, choose *Save current arrangement as layout*. Captures: app bundle IDs, normalized frames, stacking order, display assignments. Edit by re-snapshot.
- **Per-monitor decomposition.** Saving with N displays connected writes N per-monitor layouts, filed in the menu under each monitor's name, linked as a **bundle**: one hotkey launches the full multi-monitor workspace; each per-monitor layout also launches individually.
- **Launch semantics:** adopt running apps (move their windows into slots — never spawn duplicates), launch missing apps, then place after settle (§6.4).
- **Stage mode (per template):** *leave others alone* or *clear the stage* (hide non-member windows).
- **Missing-display adaptation:** launching a layout whose display is absent applies it to the chosen active display via **Tier-1 proportional remap**: normalized fractions rescale to the target; each window clamps to its app minimum; overlap grows rather than windows becoming unusable. Default policy is **squeeze everything**; template entries may carry an **optional-member flag** (optional windows are skipped when space is tight). Tier-2 structural reflow arrives with Phase 3 (§3.3).
- Partial failure: apps that fail to launch within a timeout are skipped; everything that arrived is placed; one unobtrusive notification lists the missing.

### 3.3 Phase 3 — Magnet groups (M3)

- **Grouping:** dragging a window near another's edge (proximity threshold) shows a subtle highlight; release mates the edges. Groups are sets of windows plus adjacency edges.
- **Shared-edge resize:** dragging a mated edge resizes the neighbor: **shrink mode** (neighbor absorbs the delta) or **nudge mode** (neighbor translates). Mode is a per-group setting; ⌘-drag toggles it for the gesture. Free sizing of non-mated edges is always allowed.
- **Preset reflows** (one action reflows all members inside the group's bounding box):
  - columns · rows · grid · main+side
  - **weighted treemap** — each member gets area proportional to its weight; heaviest tile anchored **center** (default), **left**, or **right**; changing one weight rebalances every tile.
  - **symmetric** — the treemap's equal-weights case.
- **Weights:** manual rank in v1. Automatic "frecency" weighting (focus time + recency) is a stated later enhancement, not in M3 acceptance.
- **Tier-2 layout adaptation:** a template that recorded groups + weights re-runs the solver against a foreign display's bounds instead of scaling pixels — layouts *reflow* rather than squish.

### 3.4 Phase 4 — Public release (M4)

README with honest limitations (§8), Homebrew cask, notarization, issue templates, attribution to Rectangle for vendored code.

## 4. UI specification

- **Menu-bar app, no Dock icon.** Dropdown, top to bottom:
  1. **Group-preset glyph row** (Rectangle-style shaded miniatures: treemap C/L/R, symmetric, columns, rows, grid, main+side) applying to the focused magnet group. Hidden until Phase 3.
  2. **One section per connected monitor** (display name as header) listing its layouts with hotkeys.
  3. **Inactive monitor layouts** (collapsed): layouts belonging to disconnected displays, grouped by monitor name; selecting one applies it to the active display via adaptive remap.
  4. *Save current arrangement as layout…* · *Restore all window positions*
  5. *Preferences…* · *Quit*
- **Preferences** (3 tabs, Rectangle-simple): **Shortcuts** (hotkey list), **Apps** (exclude list, pin rules), **Layouts** (rename/delete/bundle, stage mode, optional-member flags).
- **Onboarding:** first launch requests Accessibility permission with a short explainer; the app is inert until granted.
- Hotkeys via MASShortcut (as Rectangle uses).
- Mockups from the design session persist in `.superpowers/brainstorm/` (dropdown structure, treemap presets, reference layout).

## 5. Build approach

**Greenfield Swift/AppKit app, cherry-picking Rectangle's MIT code.** Rectangle (rxhanson/Rectangle, MIT, verified 2026-08-19) contributes battle-tested pieces — `AccessibilityElement` AX wrappers with proposed-vs-result logging, the app-quirk ignore list, snap-overlay patterns, MASShortcut wiring — lifted verbatim with attribution. A fork was rejected: Rectangle is architected as stateless one-shot commands, while every MacTLM pillar is stateful and event-driven; retrofitting a daemon into it costs more than owning the plumbing. A Hammerspoon prototype was rejected as throwaway work that cannot validate magnet drag-feel.

## 6. Architecture

### 6.1 Layers

```
UI (menu bar · prefs · hotkeys · magnet drag overlay)        [AppKit]
Layout Core (schema · templates · groups · solvers)          [pure Swift — portable]
Window Tracker (identity records · matching · pin rules)     [pure Swift]
macOS Window Driver (AX · NSWorkspace · AXObserver)          [macOS-only]
```

Events flow up (window created/moved/quit → tracker → debounced store write). Commands flow down (launch template → core computes frames → driver asserts).

### 6.2 Portability seam

The Layout Core imports no AppKit. The Linux port (post-M4) reuses schema, solvers, tracker logic, and adds a new driver: sway/Hyprland IPC on Wayland or EWMH on X11. Research confirms ~0% of AX-based driver code is portable; the seam is the entire porting strategy.

### 6.3 macOS driver responsibilities

- Enumerate/manipulate windows via `AXUIElementCreateApplication` + `kAXWindowsAttribute`; set `kAXPosition`/`kAXSize`.
- App lifecycle via `NSWorkspace` didLaunch/didTerminate; window lifecycle via per-pid `AXObserver` (created, moved, resized, title changed, destroyed).
- **Registration race:** subscribe observer → enumerate existing windows → dedupe → bounded retries.
- **Frame clamping:** apps may "accept" a frame then clamp it. Set → read back → retry once → accept the clamp and log. Never loop-fight an app.
- **Launch settle:** macOS Resume means apps re-place their own windows after launch. Assert frames only after window activity quiesces (per-app settle timeout), then verify.
- Electron apps require setting `AXManualAccessibility`.

### 6.4 Known platform limits (accepted)

- AX sees only the current Space; cross-Space windows are invisible without private APIs. Out of scope by design.
- Some apps (notably Adobe's) are AX-hostile; they live on the exclude list. Illustrator restoring its own fullscreen window is acceptable — templates simply skip asserting excluded apps beyond launching them.
- macOS 15+ native tiling exposes no third-party API; irrelevant to this design.

## 7. Data model & storage

Human-readable JSON in `~/Library/Application Support/MacTLM/` (inspectable, hand-editable, git/Nextcloud-syncable). All frame data namespaced by **display configuration** (hash of connected displays' resolution + scale), so config changes never corrupt other configs' data.

- **Frames** are normalized `{x, y, w, h}` fractions of the assigned display's *visible* area, stored with the display's UUID and captured metrics (point size, aspect ratio). Same display → exact reproduction; different display → scalable.
- **WindowRecord:** bundle ID, normalized frame, window-identity hash, optional pin rule (title pattern → slot), z-order hint, last-seen timestamp.

**Window titles are never persisted (amended 2026-08-20, M2d).** The original design stored a title snapshot for matching, which put browser page titles — i.e. browsing history — into files this section designs to be syncable. Records and layout entries instead carry `titleHash`: `SHA-256(per-install salt ‖ title)` truncated to 16 hex characters, computed in the macOS layer (CryptoKit) so `MacTLMCore` stays portable. Exact-window matching survives as hash equality; untitled windows hash to `nil` and never match each other. The salt lives in `UserDefaults` (`~/Library/Preferences/`), deliberately outside the synced Application Support directory. Honest limit: a holder of both the files and the salt can confirm a guessed title, though not read titles out; Keychain storage is the stricter future option. Legacy plaintext keys are ignored on decode and scrubbed from every namespace at startup.
- **Layout (per-monitor):** name, hotkey, stage mode, display UUID + metrics, ordered entries `{bundleID, frame, zOrder, pinRule?, optional?}`.
- **Bundle:** named set of per-monitor layouts launched as one workspace.
- **MagnetGroup:** member window refs, adjacency edges, resize mode (shrink/nudge), active preset + per-member weights + bias.

Failure posture: no Accessibility permission → onboarding only; launch timeout → place what arrived, notify once; clamped frame → accept and log.

## 8. Competitive landscape & risks

**Landscape (researched 2026-08-19):** Rectangle Pro (closed) does saved layouts with app launching; Stay (proprietary) does automatic per-app frame persistence; Moom does explicit saved layouts. **No open-source tool does automatic persistence** — that is MacTLM's gap. AeroSpace/yabai/Amethyst are tiling trees (different product). Nothing anywhere does weighted-treemap group reflows.

**Risks:**

| Risk | Mitigation |
|---|---|
| Window-identity matching wrong for multi-window apps | Count-based restore is the contract; pin rules for identity-critical slots; heuristics unit-tested |
| Apps fight external placement | Default exclude list, clamp-acceptance, settle-then-assert; never loop |
| Magnet drag-feel is hard to get right | M3 budgeted for iteration; feel validated by hand, not tests |
| Treemap solver produces unusable slivers | App-minimum clamps; property-based tests (areas sum to bounds; weight monotonicity) |
| Scope creep toward full tiling WM | §2 non-goals are permanent |

## 9. Reference workspace (canonical acceptance test)

"Design + Comms" on a single laptop display, 16:10:

| Window | Frame (fractions of visible area) | Notes |
|---|---|---|
| Adobe Illustrator | fullscreen | bottom of stack; excluded app — launched, not placed |
| Arc #1 | w .25 × h .90, portrait | pair sits slightly **right** of center |
| Arc #2 | w .25 × h .90, portrait | right member of pair |
| Paseo | w .25 × h .60 | overlays Arc #2, **vertically centered** |
| Nextcloud Talk | w .16 × h .70 | far right |
| Finder | w .16 × h .60 | floating, **left side** |

**M2 acceptance:** from a clean login, one hotkey reproduces this table (Illustrator via launch-only), stacking order included.

## 10. Milestones & verification

- **M1 Persist:** driver + tracker + store. Tests: 2-window Arc quit/relaunch → both restored; reboot → restored; excluded app untouched; heuristics unit-tested; author soaks daily.
- **M2 Templates:** snapshot, per-monitor layouts + bundles, adopt-or-launch, stage modes, inactive-monitor Tier-1 remap. Acceptance: §9.
- **M3 Magnets:** grouping, shared-edge resize (both modes), preset reflows incl. weighted treemap C/L/R + symmetric, Tier-2 structural reflow. Solver property tests; drag-feel by hand.
- **M4 Public:** README, cask, notarization, issue templates, Rectangle attribution.

Each milestone is independently daily-usable.
