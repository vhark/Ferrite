# MacTLM — Backlog and Platform Findings

Living notes. Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.

## Shipped

| Tag | Milestone | Contents |
|---|---|---|
| `v0.1.0-m1` | Position persistence | Automatic per-app window capture, restore on launch / login / display change, exclude list, pin rules (JSON), menu bar app |
| `v0.2.0-m2a` | Workspace templates (engine + menu) | Whole-desktop snapshots per display, adopt-running/launch-missing, frame + cross-app stacking restore, stage modes, adaptive launch onto another display, dynamic per-monitor menu |
| `v0.2.1-m2a` | Stacking correctness | Excluded and late-launching apps join the template z-order cascade; apps launch backmost-first |

**PRD §9 acceptance: PASSED** live on 2026-08-19 — `Design&Comms` restored from a cold start (Illustrator, both Arcs, Paseo, Nextcloud Talk, Finder, Spotify, Obsidian, Rambox), apps relaunching into place one by one. The single defect it exposed (Illustrator covering the layout) is fixed in `v0.2.1-m2a` and re-verified.

Test suite: 70 unit tests over `MacTLMCore` (pure, Linux-portable). AppKit layer is verified by live protocol, not unit tests.

## Pending verification

- **Late-arrival restacking (Fix C, `06a98d1`).** When the 15s launch deadline fires before a slow app draws a window, `inFlight` is now retained (`reportedMissing`) so the app rejoins the z-order when it finally settles, with a 120s hard stop. Only reachable on a cold launch of a slow app; not yet observed live. The next full quit-and-relaunch of `Design&Comms` exercises it.

## Platform findings (paid for in blood, do not regress)

1. **`AXManualAccessibility` must be applied lazily.** Setting it eagerly on every app poisons **Finder**: its `kAXWindowsAttribute` returns an empty array (AXError `.success`, zero windows) process-wide for the life of that Finder process. Finder was silently missing from every capture until this was found. It is now set only as a fallback when an app's first window query comes back empty (the Electron case it exists for). `AppObserver` must **not** set it either — the attribute is process-wide, so one eager write anywhere re-breaks Finder.
2. **Filter to the `AXStandardWindow` subrole.** Without it, enumerations include Finder's desktop window (full screen, empty title) and terminal tooltip/popup windows (~24×30). The old `> 1px` frame filter was far too weak.
3. **macOS gives no reliable "transient dialog" signal.** TextEdit's Open panel reports role `AXWindow`, subrole `AXStandardWindow`, `AXModal` false — indistinguishable from a document window. Mitigation: order-fallback matching is gated on `windows.count >= records.count`, so a relaunched app showing fewer windows than expected never has a transient window dragged into a slot. Title/pin matching still applies, which keeps apps whose titles drift (Arc) working.
4. **Minimized windows and hidden apps must be excluded from capture.** A minimized window keeps a plausible frame, becomes a layout member, and the raise pass un-minimizes it behind the user's back.
5. **Cross-app stacking needs app activation, not just `AXRaise`.** `AXRaise` orders windows *within* an app. Restoring a scene requires activating member apps backmost-first (spaced ~60ms so each activation lands), raising each app's own windows back-to-front inside its step.
6. **Ad-hoc signing re-keys TCC on every rebuild.** The Accessibility grant is bound to the code signature's designated requirement; `codesign -s -` changes the cdhash per build, so the grant silently dies and System Settings shows a stale enabled toggle. Fixed by signing with a self-signed **"MacTLM Dev"** identity (`scripts/make-app.sh` prefers it, falls back to ad-hoc). Toggling the grant while the app runs does not help; a stale entry must be removed and re-added, or reset with `tccutil reset Accessibility dev.mactlm.MacTLM`.
7. **`--list-windows` reports zero-window apps** with their raw AX window count and `AXError`. Findings 1 and 2 were both discovered through it; keep it.
8. **Excluded apps must still join the stacking cascade.** They are launch-only (frames never touched, PRD §9), so deriving activation order from `placements` silently omitted them — Illustrator launched last, activated itself, and covered the whole layout. `ApplyPlan.appStackingOrder` now ranks every active member by its frontmost window's zIndex, excluded ones included; `activateAndRaise` activates such an app without enumerating or raising its windows. Related: launch *start* order is not window *appearance* order, so launching backmost-first is a head start, never a guarantee — the cascade is what's authoritative.

## M2b (next milestone)

- **Bundles** — link the per-monitor layouts produced by one multi-display save so a single action launches the whole workspace.
- **Hotkeys** — per-layout shortcuts, completing the PRD §9 acceptance ("one hotkey from a clean login"). Needs a recorder UI; `MASShortcut` is not SPM-friendly, evaluate `sindresorhus/KeyboardShortcuts` (MIT).
- **Preferences window** — Shortcuts / Apps (exclude list, pin rules) / Layouts (rename, delete, stage mode, optional flags). Today pins and `optional` are JSON-edit-only and there is no delete affordance (`deleteLayout(id:)` exists, unused).
- **Target display choice** — when a layout's own display is absent, we always adapt onto the main display; offer a picker.

## Accepted residuals

| Item | Impact | Notes |
|---|---|---|
| `CFHash(AXUIElement)` as window id | Theoretical collision merges two windows | Cache is rebuilt per enumeration; revisit if ever observed |
| Clear-stage hides apps on *other* displays | Multi-display wart | Membership is per-display; resolve with bundles (M2b) |
| Snapshot dedupes by bundle ID | Second instance of one app is skipped | Rare; multi-instance support unscoped |
| Superseded template launch | Activation cascade for an abandoned plan can still fire within its ~60ms/app window | Inherent to spaced activation |
| ISO-8601 store dates | Sub-second precision truncated | Never compare live vs re-loaded records for equality |
| Login restore ordering | Startup sweep captures Resume-placed windows; arming settles for already-running remembered apps fixes the restore, but Resume still wins the first paint | Verified working; cosmetic |
| Launching an app does not reopen its documents | Document apps may come back empty (Open dialog) | Out of scope; finding 3 stops mis-placement |

## Linux port (post-M2)

`MacTLMCore` holds all schema, matching, planning, and solver logic with no AppKit import — that is the entire porting strategy. A Linux build needs a new `WindowDriving` implementation (sway/Hyprland IPC on Wayland, EWMH on X11). Approximately none of `Sources/MacTLM` is portable.
