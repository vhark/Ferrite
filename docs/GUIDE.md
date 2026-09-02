# Ferrite User Guide

Everything Ferrite does, how to drive it, and what to check when something surprises you.

- [Concepts](#concepts)
- [The menu](#the-menu)
- [Position persistence](#position-persistence)
- [Workspaces](#workspaces)
- [Magnet groups](#magnet-groups)
- [Reflow presets](#reflow-presets)
- [Preferences](#preferences)
- [Privacy](#privacy)
- [Command-line diagnostics](#command-line-diagnostics)
- [Building from source](#building-from-source)
- [Troubleshooting](#troubleshooting)
- [Limits and non-goals](#limits-and-non-goals)

---

## Concepts

Ferrite has three ideas, layered so each works alone:

1. **Persistence** — Ferrite continuously remembers where each app's windows are. When an app relaunches, its windows go back where they belong. Automatic, always on (unless paused), no configuration.
2. **Workspaces** — a named snapshot of an entire arrangement: which apps, which windows, where, in what stacking order, per display. Restoring one is a single action that adopts running apps and launches missing ones.
3. **Magnet groups** — windows you've stuck together by dragging their edges flush. A group behaves like one combined window: carry it, scale it, resize along shared edges, reflow it into presets.

Ferrite is **not an auto-tiler**. Nothing moves unless an app relaunches into its remembered spot, you invoke a workspace, or you use a magnet gesture. Overlapping, freeform layouts are first-class.

A fourth, invisible idea underlies the other three: **window identity**. Ferrite recognizes "the same window" across relaunches by a salted hash of its title, by your pin rules, and — only when counts make it safe — by window order. Titles themselves never touch disk (see [Privacy](#privacy)).

---

## The menu

The menu bar icon (a group-of-rectangles glyph) is the main surface. Top to bottom:

| Section | What it does |
|---|---|
| **Reflow this display** | Rows of glyph buttons (wrapping at eight per line); each icon is drawn by the layout solver itself, so the picture *is* the behavior. Clicking one reflows every eligible window on the display holding the frontmost window. Always present. See [Reflow presets](#reflow-presets). |
| **Keep magnet groups together** | Checkmark toggle indented under those glyphs. Off (the default): a display reflow places group members individually and dissolves the groups it touched. On: each intact group is placed as one tile with its formation preserved. The same setting as the toggle in Preferences → Reflows. |
| **Reflow this group** | Appears only when the frontmost window belongs to a magnet group with 2+ open members. The same glyphs, reflowing just that group inside its own bounding box, using the members' weights. |
| **Groups** | One row per magnet group (e.g. "Arc ×2 + Paseo"), with a submenu: **Resize mode** (Standard / Shrink / Nudge), **Grow frontmost** / **Shrink frontmost** (weight ×1.25 / ×0.8, reapplies the group's last preset), **Ungroup**, and a **Reflow** glyph row of its own — so a group that doesn't hold focus can be reflowed without focusing it first. Only groups with at least two open windows are listed. |
| **Workspaces** | One row per saved workspace. Click launches it on all displays; the submenu offers **All displays** or a single display's layout. Shows the recorded hotkey. Workspaces saved on displays that aren't attached appear under **Workspaces for other displays** and adapt onto the main display when launched. |
| **Save Current Arrangement as Layout…** | Snapshots the current desktop (per display) under a name. The dialog's **Hide other apps when launching** checkbox controls stage mode — see [Workspaces](#workspaces). Re-saving an existing name *replaces* that workspace. |
| **Restore All Window Positions** | Re-asserts every remembered frame for currently running apps. |
| **Pause Persistence** | Checkmark toggle. While paused, Ferrite neither captures nor restores. |
| **Exclude Frontmost App** | Adds the active app to the exclude list ("never move this app's windows"). Undo in Preferences → Apps. |
| **Launch at Login** | Checkmark when registered. Reads "(needs approval)" when macOS wants you to allow it under System Settings → General → Login Items; clicking offers to open that pane. |
| **Preferences… / Quit Ferrite** | The Preferences window (⌘, convention) and quit (⌘Q). |

---

## Position persistence

**What is captured.** Every ordinary window of every regular, non-hidden app: frame, stacking hint, and identity (salted title hash, slot). Minimized windows, hidden apps, tooltips, popovers, and desktop windows are ignored. Captures happen automatically a moment after windows move or resize (debounced ~2 s), and on app quit.

**When windows are restored.** Three triggers: an app launches, you log in, or the display configuration changes. Between triggers, your manual window moves are respected — persistence is not continuous enforcement.

**Per-display-configuration memory.** Records are keyed by the attached display set (identity + resolution + scale). Your ultrawide-only arrangement and your ultrawide-plus-laptop arrangement are separate memories; plugging the second display in switches namespaces without corrupting either.

**Multi-window apps.** N remembered windows → N restored frames. Matching order: pin rules first, then exact title-hash equality, then — only if at least as many windows exist as records — stable order. A relaunched app showing *fewer* windows than expected never has a transient dialog dragged into a slot.

**Pins.** A pin re-attaches a remembered position to the window whose title matches a pattern you write (regex or substring, tested case-insensitively against *live* titles in memory — pins are never hashed). Use them for identity-critical slots, e.g. distinguish two browser profiles: pin `Titan` to one slot so that conversation always lands in its spot. Edit pins in Preferences → Apps; a pin describes a *window*, not a monitor arrangement, so it applies across display configurations.

**Exclude list.** Excluded apps are never moved or resized by any Ferrite mechanism — but they still participate in workspace *stacking* (they're launched and layered, just not placed). Defaults are evidence-based: only apps measured to fight external moves ship excluded (currently After Effects and MATLAB, on Rectangle's authority until testable). Check any app yourself with `--probe-frame` (see [diagnostics](#command-line-diagnostics)).

Exclusion also covers the magnet gestures, which is usually the reason you want it: an excluded app's window cannot start a mate (no blue preview appears when you drag it), cannot be mated *onto* by another window, and never owns a magnet group. So excluding Finder — one click on **Exclude Frontmost App** while it's frontmost — takes it out of grouping entirely, not just out of placement. Reflows skip excluded apps too.

> **Known gap (mate-then-exclude ordering).** Exclusion is enforced when a gesture *starts*, not on windows already inside a group. If you mate an app into a group and exclude it afterwards, the stale membership survives, and ⌘-drag cluster carry, the group's own reflow row, and Grow/Shrink frontmost will still move that window. Excluding *before* mating behaves exactly as described above. The same applies if `exclude.json` syncs from another machine where the app was already grouped. Workaround until this is fixed: **Ungroup** the group (Groups ▸ its submenu), or re-mate without the excluded app. Tracked in `docs/BACKLOG.md`.

---

## Workspaces

**Saving.** *Save Current Arrangement as Layout…* snapshots every eligible window on every attached display. Each display gets its own layout; same-named layouts across displays form one **workspace bundle** that launches as a unit. Re-saving under the same name replaces the previous snapshot (it never duplicates).

**Stage mode.** The save dialog's **Hide other apps when launching** checkbox (also the **Hide others** toggle per row in Preferences → Layouts):
- *Off (leave others):* launching the workspace places its members and leaves everything else where it is.
- *On (clear stage):* every app that isn't a member is hidden (⌘H-style — windows return with one click, in place). Members-only focus.

**Launching.** Click the workspace row, press its hotkey, or use the row submenu for a single display. What happens:
1. Running member apps are **adopted**: their windows move to the saved frames.
2. Missing member apps are **launched** (backmost-first for a head start), and placed as their windows appear and settle. Apps that take longer than ~15 s still join the arrangement when they finally draw (up to 120 s).
3. **Stacking is restored**: apps are activated backmost-to-front so the final z-order matches the snapshot — excluded apps included (launched and layered, never resized).
4. An app with windows on several displays gets exactly one window-assignment pass across the whole bundle, so each window lands on its own display.

Windows that were minimized or hidden at save time are not part of the snapshot. Launching an app does not reopen its documents — a document app with nothing to show may present its Open dialog untouched.

**Missing displays.** A workspace saved for a display that isn't attached appears under *Workspaces for other displays* and, when launched, adapts proportionally onto the main display (frames are stored as fractions of their display, so nothing is lost — re-saving under the same name re-anchors them).

**Hotkeys.** Record one per workspace in Preferences → Layouts. One hotkey restores every display in the workspace. Renaming a workspace migrates its hotkey; archiving keeps the assignment dormant until restore.

**Entry editing** (Preferences → Layouts, expand a row): per-window **Optional** flag (an optional member that isn't open is skipped without complaint) and **Remove** (a removed entry returns on the next re-save). An empty layout is legal — re-saving refills it.

---

## Magnet groups

The gesture vocabulary. All gestures use plain window dragging — no modes, no commands, with one modifier (⌘) for carrying.

| Gesture | Result |
|---|---|
| **Drag a window until its edge nears another's facing edge** (within ~64 pt, edges overlapping at least a quarter of the shorter side) | A blue bar previews the mate; release and the window snaps flush with an 8 pt gap. Both windows are now a group. If the perpendicular edges were within 24 pt of level, they're aligned; larger offsets are respected as deliberate. |
| **Mate more windows onto a group** | They join it — groups merge transitively when clusters actually touch. |
| **Plain-drag a member away and release** (flush with no fellow member) | It **leaves the group**. Groups dissolve below two members. Dragging a member from group A onto group B moves it A→B. |
| **⌘-drag any member by its title bar** | Carries the **whole group**: the grabbed window moves live, the other members hold still while accent-colored outline ghosts glide in formation, and on release every member lands in one clean write. (Followers don't move live because writing into busy apps mid-drag lags; the ghosts are the honest, instant feedback.) |
| **Drag a shared edge** (an edge two members meet at) | Per the group's **Resize mode**: **Standard** — only the window you resize changes, the mates stay exactly where they are; **Shrink** — the mate follows live, resizing with its far edge anchored; **Nudge** — the mate follows live, keeping its size and sliding, pushing its own mates down the chain. |
| **Drag an outer edge** (no mate flush against it) | On release, the whole group **scales proportionally along that axis**, as if it were one combined window (except in **Standard**). |
| **Drag an outer corner** (two unshared edges) | Scales the group along both axes on release (except in **Standard**). A corner mixing one shared and one outer edge does both: live shrink/nudge on the shared axis, proportional settle on the outer one. |

**Standard mode.** In **Standard** neither the live propagation nor the proportional settle runs, so a shared edge, an outer edge and a corner all resize just the one window you grabbed. The group is still a group: ⌘-drag carries the cluster, and reflowing the group treats it as one, weights and all. Note that pulling a window well clear of its mates this way leaves it no longer touching them, so the next time you drag it and release it away from them, it leaves the group — dragging it back into contact keeps it (adjacency is live geometry, read at the release position, not a remembered fact).

**Weights.** Each member carries a rank (default 1). *Grow frontmost* / *Shrink frontmost* in the group's submenu scale the active member's weight ×1.25 / ×0.8 (clamped 0.25–8) and re-run the group's last preset so the change is visible immediately. Weights feed the weighted presets — see below.

**Persistence.** Groups (membership, resize mode, weights) are saved per display configuration and survive restarts. Adjacency, however, is always read from live geometry — a group whose members drifted apart scales as a loose cluster until re-mated. Two things end membership without you asking: a *display* reflow, under its default explode policy, dissolves the groups it scattered — see [Reflow presets](#reflow-presets) if you'd rather it kept them — and maximizing a member, below.

**Maximizing takes a window out of its group.** Double-click a member's title bar (when your system is set to zoom on that gesture rather than minimize or do nothing), or click its green maximize button, and that window drops out of the group. The other members are never disturbed: they keep exactly the sizes you gave them, and they stay grouped with *each other* (a two-member group simply dissolves, since one window is not a group). What protects them is not the timing of the drop-out but a firmer rule, described next: Ferrite only ever propagates a resize you are actively dragging. A maximize is just a resize as far as macOS is concerned, so left to itself it would haul the mates along a shared edge and squash them against the screen edges, and un-maximizing would not hand their sizes back. To put the window back, mate it again the normal way: drag it until its edge nears a member's facing edge and release.

**Only a resize you are dragging propagates.** Shrink and Nudge move a mate while your hand is on the edge. Anything else that resizes a grouped window (a maximize, a script, an app resizing its own window, or Ferrite's own reflow) never drags the mates along. The reason is that propagation is *relative*: it follows a shared edge, so it can shrink a mate but has no memory of the size it started from and cannot restore one. Refusing to propagate a resize nobody dragged is what keeps a one-off resize from permanently rearranging a group.

---

## Reflow presets

Rows of glyph buttons at the top of the menu. Each button's icon is a miniature render of its preset, drawn by the same solver that will move your windows — a preview cannot disagree with what clicking it does.

**Two explicit targets.** *Reflow this display* is always present and reflows **every eligible window on the display holding the frontmost window**, with weights taken from stacking order — frontmost heaviest — so the weighted presets work with zero setup. *Reflow this group* appears only when the frontmost window belongs to a magnet group with 2+ open members, and reflows **that group inside its own bounding box** using the members' own weights. Every group's submenu carries the same glyph row, so a group that doesn't hold focus is still reflowable without focusing it first. (One row used to serve both, silently retargeting itself according to where focus happened to sit; which of the two you get is now your choice, not an inference from your focus.)

| Preset | Behavior |
|---|---|
| **Columns** | Even vertical strips, one per window. |
| **Rows** | Even horizontal strips. |
| **Grid** | Near-square even grid; the cell count follows the window count. |
| **Symmetric — equal areas** | The treemap's equal-weights case: every window the same area, arranged compactly. |
| **Main + side** | One large main window taking 60% of the width on the **left**, the rest stacked in a side column on the right. The heaviest window is the main one. |
| **Main + side — main on the right** | The same layout flipped: the main window takes 60% on the **right**, the others stack down the left. For the display where your reference window belongs on the far side. |
| **Main in the centre** | The heaviest window centred at 60% of the width, the remainder split into two **equal** side columns; the rest deal out alternately — second window to the left, third to the right, and so on. The centre stays centred even when one side ends up empty. Make your own proportions with a custom preset (below). |
| **Split spiral** | A dwindling spiral: the frontmost window takes half the area, the next takes half of what remains, and so on, flipping between vertical and horizontal splits. Hyprland's default layout; splits are an even 50/50 and ignore weights. |
| **Treemap — heaviest in the centre / left / right** | Weight-proportional areas; the heaviest window takes the biased position, the rest fill around it. The signature layout: rank with *Grow frontmost*, or just focus what matters and let z-order rank for you. |
| **Cascade** | Every window at 70% of the area's width and height, staggered diagonally from the top-left, the frontmost deepest and on top. The step shrinks as the window count grows so the last one still fits. |
| **Monocle — all full size** | Every window at full size, one on top of another, in the stacking order they already had. |

**Cascade and Monocle overlap on purpose.** Every other preset carves the area into tiles that don't overlap. These two stack windows instead — Cascade offsets each window from the one behind it so the pile stays clickable, Monocle gives every window the whole area so you work on one at a time without losing the others. Nothing is hidden or minimized; it's a stack of real windows in their existing order.

Reflow moves *eligible* windows only: standard, non-minimized windows of visible apps, never excluded apps, never Ferrite itself. A preset is a gesture, not a mode — nothing re-enforces it afterward. A display or group holding just one eligible window is left alone: there is nothing to arrange, so nothing moves.

**Custom presets.** Preferences → Reflows lets you define your own, each with a name; they appear as extra glyphs at the end of every reflow row — the display row, the group row, and each group's submenu. Three kinds:

- **Columns(n)** — *n* fixed-width columns (1–12). Window *i* goes to column *i* % *n*, so windows deal out left to right and wrap; a column then splits its own height evenly among the windows that landed in it. Unlike the built-in Columns, the column count is yours, not the window count's.
- **Grid(cols × rows)** — an exact grid of fixed zones, up to 12 wide and 8 tall. Windows fill the cells row by row, frontmost first. See the fixed-zone note below: this is the one preset whose behavior surprises people, and deliberately so.
- **Main centre(fraction, per-side cap)** — the parameterized *Main in the centre*: the centre fraction is yours (20–90%), and the cap limits how many windows stack per side column. A cap of 0 means uncapped, one cell per window; beyond the cap, extra windows cycle back through the cells and stack.

**Grid zones are fixed, and that's the point.** Ask for 7×3 and you get 21 fixed cells of one size (subject only to the 240×160 floor every layout respects). With five windows open, five cells fill and the remaining sixteen **stay empty** — the five windows do *not* stretch to fill the display. That's how you get a stable, muscle-memory layout: a window lands the same size in the same place whether two windows are open or twenty. With more windows than cells, the extras cycle back through the cells and stack on top of the occupants rather than shrinking anything. If you want windows that grow to fill the area, use the built-in Grid, Columns or Symmetric instead. A fixed-zone glyph is drawn with its true cell count — 21 cells for a 7×3 — so the preview shows you exactly the division you asked for, not an approximation of it.

**What a display reflow does to your groups.** A display reflow finds magnet groups in its way, and the *Keep magnet groups together* checkmark under the display glyphs decides what happens to them. It's the same stored setting as the toggle in Preferences → Reflows, so the two can never disagree. The default is **off — explode**.

- **Off (explode).** Every member is placed as its own tile, exactly like an ungrouped window, and every group the reflow actually touched is then dissolved — the same outcome as clicking *Ungroup*. Be aware this dissolves a group even when only **one** of its members was on the reflowed display, while its other members sit on another monitor: the moment one member is torn out of the formation, the formation is gone, and membership with broken adjacency is worse than no membership (a group whose members no longer touch scales as a loose cluster). A group the reflow never touched — one living entirely on another display — is left completely alone.
- **On (keep).** Each intact group — two or more of its live members eligible on that display — is placed as a **single tile**: the solver positions the group's bounding box, and the mated formation is scaled into that cell, so the group keeps its shape and its internal proportions. Ungrouped windows tile alongside it as normal, and a group weighs exactly what its frontmost window would have weighed alone. If the display holds nothing *but* one group, that single tile is the whole display, so the group scales up to fill it. Honest limit: a group straddling two displays gets only its on-display members collapsed into the cell while the others stay where they are, which leaves the formation broken across the seam. Membership survives, so reflowing the group itself (the *Reflow this group* row, or the group's own submenu) puts it right.

---

## Preferences

**Layouts tab.** Every workspace: rename inline (renames migrate hotkeys), **Hide others** stage toggle, hotkey recorder, **Archive**. Expand a row to see each display's entries (z-order, live title, **Optional** flag, **Remove**). Archived workspaces keep everything and can be **Restore**d; **Delete Permanently** (double-confirmed) is only available from the archive — one-click irreversible deletion doesn't exist.

**Apps tab.** Every app with remembered windows, for the *current* display configuration: **Never move this app's windows** (the exclude toggle; default-excluded apps say why), per-slot **pin** fields, live titles (shown live, never stored), and **Forget** (drops the app's remembered positions until it's learned again — confirmed, destructive).

**Reflows tab.** Your custom reflow presets, and the group policy that applies to every display reflow:
- **Keep magnet groups together when reflowing a display** — the same setting as the menu checkmark under the display glyphs; either one moves both. Off by default (explode); see [Reflow presets](#reflow-presets) for what each policy does.
- **Custom presets** — **Add** appends a preset, the name field renames it inline, the trash button deletes it, and the kind picker chooses Columns / Grid / Main centre (switching kind loads that kind's defaults). Steppers set the parameters: column count, grid columns and rows, centre percentage, per-side cap. The glyph beside each row is a live preview rendered by the solver itself, so it updates as you step and always shows the layout you'll actually get. Presets are stored in `reflows.json`, and the menu picks them up the next time you open it — no restart.

---

## Privacy

Ferrite's data files are designed to be synced (git, Nextcloud) without leaking what you do:

- **Window titles are never persisted.** Records and layout entries store `SHA-256(per-install salt ‖ title)` truncated to 16 hex chars — enough to recognize a window again, structurally incapable of reproducing the title. Untitled windows hash to nothing rather than to a shared value.
- **The salt lives outside the synced data** (`defaults` domain `dev.ferrite.Ferrite`, key `dev.ferrite.identitySalt`), deliberately not in `~/Library/Application Support/Ferrite/`. Honest limit: someone holding both your files *and* your salt could confirm a *guessed* title; they still cannot read titles out. Keychain storage for the salt is on the roadmap.
- **Pins are yours, not captured**: they're patterns you typed, matched against live titles in memory.
- Losing the salt (e.g. wiping defaults) doesn't lose data, but every stored hash goes stale — matching degrades to pins and order until windows are re-captured.

Data lives in `~/Library/Application Support/Ferrite/`: `layouts.json` (workspaces), `configurations/*.json` (per-display-set records and magnet groups), `exclude.json` (only written once you customize the list), `reflows.json` (custom reflow presets and the group policy). None of them contains a window title.

---

## Command-line diagnostics

Run against the installed binary: `/Applications/Ferrite.app/Contents/MacOS/Ferrite <flag>`.

| Flag | What it tells you |
|---|---|
| `--list-windows` | Every app Ferrite can see with each window's title and frame — including zero-window apps with their raw AX error, which is how permission and enumeration problems are diagnosed. |
| `--list-displays` | Each attached display's identity, metrics, and coordinate areas, plus the current configuration key. |
| `--probe-frame <bundleID>` | Nudges the app's first window by (40, 20), reads back, restores, and prints an **ACCEPTS / REFUSES** verdict — the evidence-based way to decide if an app belongs on the exclude list. |
| `--login-status` / `--login-register` / `--login-unregister` | Launch-at-Login registration state and control, including the "needs approval" case macOS otherwise hides. |
| `--apply-bundle <name>` | Applies a saved workspace from the CLI — useful for scripting and for verifying placement without touching the menu. |

Gesture debugging: launch the binary with `FERRITE_TRACE_DRAG=1` in the environment and every drag/resize session logs its lifecycle — button state, mating candidates and near-misses with distances, suppression hits, settle deltas. All five gesture-engine bugs ever found were diagnosed with this trace.

---

## Building from source

Requirements: macOS 13+, Swift 5.9+ toolchain (Xcode or CLT).

- `swift test` — 253 unit tests over `FerriteCore` (pure Foundation, Linux-portable; the AppKit layer is verified by live protocol, not unit tests).
- `./scripts/make-app.sh` — builds and signs `build/Ferrite.app` (dev builds).
- `./scripts/install.sh` — builds, installs to `/Applications`, registers Launch at Login. Also migrates state from a previous MacTLM install (one-shot, copy-never-delete) and retires the old app.
- `./scripts/release.sh <version>` — cuts a public release: universal binary, Developer ID signing with hardened runtime, notarization, stapling, and the Homebrew cask bump. Operator runbook: [`docs/RELEASING.md`](RELEASING.md).

**Signing matters more than usual.** macOS binds the Accessibility grant to the code signature. Ad-hoc signing (`codesign -s -`) changes per build, silently killing the grant each rebuild while System Settings shows a stale enabled toggle. Create a self-signed **"Ferrite Dev"** identity once:

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=Ferrite Dev" -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out ferrite.p12 -passout pass:x
security import ferrite.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security find-certificate -c "Ferrite Dev" -p > cert.pem
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm key.pem cert.pem ferrite.p12
```

First signing pops a keychain dialog — click **Always Allow** so future builds are silent. `make-app.sh` prefers the identity and falls back to ad-hoc with the caveat above.

---

## Troubleshooting

**Nothing restores / menu shows no windows.** Accessibility permission. Run `--list-windows`: "Accessibility permission not granted" means System Settings → Privacy & Security → Accessibility. If the toggle *looks* enabled but nothing works, the entry is stale (a signature change did this): **remove it and re-add**, or `tccutil reset Accessibility dev.ferrite.Ferrite` — toggling a stale entry does nothing.

**An app's windows won't move.** Check Preferences → Apps for the exclude toggle. If it's not excluded, measure it: `--probe-frame <bundleID>`. REFUSES → the app fights external moves; exclude it. ACCEPTS → check whether the window is actually a standard window (`--list-windows` shows what Ferrite can see).

**Wrong window in the wrong spot after relaunch (multi-window apps).** The app's titles probably changed between quit and relaunch (browsers retitle constantly), so exact matching fell back to order. Give the identity-critical window a **pin** in Preferences → Apps — a stable word from its title is enough.

**Workspace hotkey does nothing.** Preferences → Layouts: is the recorder filled? Archived workspaces don't register hotkeys until restored.

**Ferrite doesn't start at login.** Menu shows *Launch at Login (needs approval)* → allow Ferrite under System Settings → General → Login Items. `--login-status` prints the true registration state.

**Mating feels grabby or won't trigger.** The reach is 64 pt with a quarter-overlap gate — a corner-to-corner graze never mates; near-parallel edges mate generously. If a gesture misbehaves, reproduce it once under `FERRITE_TRACE_DRAG=1` and read the candidate/miss lines; they name the failing requirement and the measured distances.

**A group scales strangely.** Its members probably drifted apart (adjacency is live geometry). Re-mate the stragglers or Ungroup and rebuild.

**Coming from MacTLM.** Everything migrated automatically on first launch (salt, layouts, records, groups, hotkeys, exclusions); the old `~/Library/Application Support/MacTLM/` directory and defaults domain were left untouched as a rollback and can be deleted once you're settled.

---

## Limits and non-goals

- **Current Space only.** The macOS Accessibility API cannot see windows on other Spaces; Ferrite never uses SIP-disabling hacks. No Spaces management.
- **One window server reality**: window animations, focus-follows-mouse, and app-content awareness are out of scope.
- **Second instances of an app are skipped** — snapshots deduplicate by bundle ID.
- **Documents aren't reopened** — launching a member app restores its windows only if the app itself restores them.
- **Reflow output with stacking-order weights changes as focus changes** — that's the zero-setup tradeoff; use group weights for stable ranks.
- **Excluded apps are launched and layered, never placed** — by definition.
