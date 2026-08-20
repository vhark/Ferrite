# MacTLM — Backlog and Platform Findings

Living notes. Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.

## Shipped

| Tag | Milestone | Contents |
|---|---|---|
| `v0.1.0-m1` | Position persistence | Automatic per-app window capture, restore on launch / login / display change, exclude list, pin rules (JSON), menu bar app |
| `v0.2.0-m2a` | Workspace templates (engine + menu) | Whole-desktop snapshots per display, adopt-running/launch-missing, frame + cross-app stacking restore, stage modes, adaptive launch onto another display, dynamic per-monitor menu |
| `v0.2.1-m2a` | Stacking correctness | Excluded and late-launching apps join the template z-order cascade; apps launch backmost-first |
| `v0.2.2-m2a` | Install + login item | `scripts/install.sh` puts the daily driver in `/Applications` and registers it for Launch at Login; the menu now reports registration failures and the `requiresApproval` state instead of failing silently; `--login-status/--login-register/--login-unregister` probes |
| `v0.3.0-m2b` | Bundles, hotkeys, Preferences | Same-name layouts across displays form a workspace bundle launched as one operation; per-bundle global hotkeys (KeyboardShortcuts 3.0.1); SwiftUI Layouts window with rename, stage toggle, hotkey recorder, and archive; archive replaces delete, permanent delete only from the archive behind a confirmation |

**PRD §9 acceptance: PASSED** live on 2026-08-19 — `Design&Comms` restored from a cold start (Illustrator, both Arcs, Paseo, Nextcloud Talk, Finder, Spotify, Obsidian, Rambox), apps relaunching into place one by one. The single defect it exposed (Illustrator covering the layout) is fixed in `v0.2.1-m2a` and re-verified.

Test suite: 90 unit tests over `MacTLMCore` (pure, Linux-portable). AppKit and SwiftUI layers are verified by live protocol, not unit tests.

**PRD §9 hotkey acceptance: PASSED** live on 2026-08-20 — one recorded hotkey (⌘⌥⌥1-style combo) restores the whole workspace, the shortcut is displayed on its menu row, and renaming the workspace migrates the shortcut with it.

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
9. **The Accessibility grant follows the signature, not the path.** Copying the signed bundle to `/Applications` and running it there needed no re-approval — verified 2026-08-20 by installing while the grant was live. Corollary: the grant also survived the macOS 26.6.2 update untouched. This is only true while a stable signing identity is used (see finding 6).
10. **`SMAppService.mainApp` registration is not a LaunchAgent.** Do not probe it with `launchctl print gui/$UID/<bundleid>` — that reports nothing even when registration is active. Use `--login-status` (which reads `SMAppService.mainApp.status`). Registration survives a `make-app.sh` rebuild of the same path, but the app should still live in `/Applications` (see `scripts/install.sh`) so wiping `build/` cannot break it.
11. **Adding a Codable field to a fail-soft store can destroy user data.** `LayoutLibraryStore.load()` returns an empty library on any decode error, and the next save writes that empty library back. So a new non-optional field on `LayoutLibrary` would have silently wiped a real `layouts.json` written before the field existed. Every new field needs an absent-tolerant `init(from:)` using `decodeIfPresent`, plus a test that decodes a literal legacy-shaped payload (`testLegacyJSONWithoutArchiveKeyStillDecodes`). Back up the live file before touching the format.
12. **KeyboardShortcuts 3.0.1 is `@MainActor`** (its `Package.swift` sets `.defaultIsolation(MainActor.self)`), while `PersistenceCoordinator` is nonisolated. Void-returning calls hop via `DispatchQueue.main.async`; the value-returning `shortcut(forBundle:)` is annotated `@MainActor` instead, since a hop would change its signature and `MainActor.assumeIsolated` needs macOS 14 (we target 13). Menu code that reads shortcuts needs `@MainActor` on the specific method — `NSMenuDelegate` callbacks are already isolated, so no cascade.
13. **Dynamic `KeyboardShortcuts.Name`s work and survive renames.** Names are built at runtime from the bundle name (`"bundle-<name>"`), and assignments live in `UserDefaults` under that name — so archiving a workspace keeps its hotkey (we simply stop registering a handler), and renaming migrates it with `getShortcut`/`setShortcut`/`reset`.

## M2c (next milestone)

- **Apps tab in Preferences** — edit the exclude list and pin rules from the UI. Both are JSON-edit-only today (the exclude list also has the menu's "Exclude Frontmost App"), and `optional` entry flags remain JSON-only.
- **Target display choice** — when a layout's own display is absent we always adapt onto the main display; offer a picker.
- **Per-app merged placement** — needed to fix the two-displays-one-app residual below, once a second monitor exists to test against.
- **Entry-level editing** — reorder or drop individual windows within a saved layout (today: re-snapshot).

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
| One app with windows on two displays in a bundle | A window can be claimed by the wrong display's records | Each display's records are matched against all of that app's windows. Single-display setups are unaffected. Fix needs per-app merged placement with absolute target rects; deferred until there is a two-monitor setup to test against |

## Linux port (post-M2)

`MacTLMCore` holds all schema, matching, planning, and solver logic with no AppKit import — that is the entire porting strategy. A Linux build needs a new `WindowDriving` implementation (sway/Hyprland IPC on Wayland, EWMH on X11). Approximately none of `Sources/MacTLM` is portable.
