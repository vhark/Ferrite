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
| **Reflow this display / group** | A row of eight glyph buttons; each icon is drawn by the layout solver itself, so the picture *is* the behavior. Reflows the frontmost window's magnet group when it has one, otherwise every eligible window on the active display. See [Reflow presets](#reflow-presets). |
| **Groups** | One row per magnet group (e.g. "Arc ×2 + Paseo"), with a submenu: **Resize mode** (Shrink / Nudge), **Grow frontmost** / **Shrink frontmost** (weight ×1.25 / ×0.8, reapplies the group's last preset), **Ungroup**. Only groups with at least two open windows are listed. |
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
| **Drag a shared edge** (an edge two members meet at) | The mate follows live, per the group's **Resize mode**: **Shrink** — the mate resizes, far edge anchored; **Nudge** — the mate keeps its size and slides, pushing its own mates down the chain. |
| **Drag an outer edge** (no mate flush against it) | On release, the whole group **scales proportionally along that axis**, as if it were one combined window. |
| **Drag an outer corner** (two unshared edges) | Scales the group along both axes on release. A corner mixing one shared and one outer edge does both: live shrink/nudge on the shared axis, proportional settle on the outer one. |

**Weights.** Each member carries a rank (default 1). *Grow frontmost* / *Shrink frontmost* in the group's submenu scale the active member's weight ×1.25 / ×0.8 (clamped 0.25–8) and re-run the group's last preset so the change is visible immediately. Weights feed the weighted presets — see below.

**Persistence.** Groups (membership, resize mode, weights) are saved per display configuration and survive restarts. Adjacency, however, is always read from live geometry — a group whose members drifted apart scales as a loose cluster until re-mated.

**Minimums.** No gesture crushes a window below 240×160; extreme shrinks stop at the floor (members may overlap at the extreme, deliberately).

---

## Reflow presets

The glyph row at the top of the menu. Each button's icon is a miniature render of its preset, drawn by the same solver that will move your windows.

Scope: if the frontmost window belongs to a magnet group with 2+ open members, the preset reflows **that group inside its own bounding box** (header reads *Reflow this group*), using the members' weights. Otherwise it reflows **every eligible window on the active display** (header: *Reflow this display*), with weights taken from stacking order — frontmost heaviest — so the weighted presets work with zero setup.

| Preset | Behavior |
|---|---|
| **Treemap — heaviest in the centre / left / right** | Weight-proportional areas; the heaviest window takes the biased position, the rest fill around it. The signature layout: rank with *Grow frontmost*, or just focus what matters and let z-order rank for you. |
| **Symmetric — equal areas** | The treemap's equal-weights case: every window the same area, arranged compactly. |
| **Columns / Rows** | Even vertical / horizontal strips. |
| **Grid** | Near-square even grid. |
| **Main + side** | One large main window, the rest stacked in a side column. |

Reflow moves *eligible* windows only: standard, non-minimized windows of visible apps, never excluded apps, never Ferrite itself. A preset is a gesture, not a mode — nothing re-enforces it afterward.

---

## Preferences

**Layouts tab.** Every workspace: rename inline (renames migrate hotkeys), **Hide others** stage toggle, hotkey recorder, **Archive**. Expand a row to see each display's entries (z-order, live title, **Optional** flag, **Remove**). Archived workspaces keep everything and can be **Restore**d; **Delete Permanently** (double-confirmed) is only available from the archive — one-click irreversible deletion doesn't exist.

**Apps tab.** Every app with remembered windows, for the *current* display configuration: **Never move this app's windows** (the exclude toggle; default-excluded apps say why), per-slot **pin** fields, live titles (shown live, never stored), and **Forget** (drops the app's remembered positions until it's learned again — confirmed, destructive).

---

## Privacy

Ferrite's data files are designed to be synced (git, Nextcloud) without leaking what you do:

- **Window titles are never persisted.** Records and layout entries store `SHA-256(per-install salt ‖ title)` truncated to 16 hex chars — enough to recognize a window again, structurally incapable of reproducing the title. Untitled windows hash to nothing rather than to a shared value.
- **The salt lives outside the synced data** (`defaults` domain `dev.ferrite.Ferrite`, key `dev.ferrite.identitySalt`), deliberately not in `~/Library/Application Support/Ferrite/`. Honest limit: someone holding both your files *and* your salt could confirm a *guessed* title; they still cannot read titles out. Keychain storage for the salt is on the roadmap.
- **Pins are yours, not captured**: they're patterns you typed, matched against live titles in memory.
- Losing the salt (e.g. wiping defaults) doesn't lose data, but every stored hash goes stale — matching degrades to pins and order until windows are re-captured.

Data lives in `~/Library/Application Support/Ferrite/`: `layouts.json` (workspaces), `configurations/*.json` (per-display-set records and magnet groups), `exclude.json` (only written once you customize the list).

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

- `swift test` — 220 unit tests over `FerriteCore` (pure Foundation, Linux-portable; the AppKit layer is verified by live protocol, not unit tests).
- `./scripts/make-app.sh` — builds and signs `build/Ferrite.app` (dev builds).
- `./scripts/install.sh` — builds, installs to `/Applications`, registers Launch at Login. Also migrates state from a previous MacTLM install (one-shot, copy-never-delete) and retires the old app.

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
