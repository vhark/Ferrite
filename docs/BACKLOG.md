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
| `v0.4.0-m2c` | Apps tab, entry editing | Preferences gains an Apps tab (exclude toggle, pin editing, Forget stale records) and per-entry editing in the Layouts tab; one workspace row per layout set with an explicit display submenu, replacing three identically-labelled rows; `--list-displays` and `--apply-bundle` diagnostics |
| `v0.5.0-m2d` | Hashed window identity | Window titles are never persisted; records and layout entries carry a salted per-install `titleHash`; live titles shown in Preferences only; legacy plaintext scrubbed from every namespace at startup; pin edits fixed to reach every namespace holding the slot |

**PRD §9 acceptance: PASSED** live on 2026-08-19 — `Design&Comms` restored from a cold start (Illustrator, both Arcs, Paseo, Nextcloud Talk, Finder, Spotify, Obsidian, Rambox), apps relaunching into place one by one. The single defect it exposed (Illustrator covering the layout) is fixed in `v0.2.1-m2a` and re-verified.

Test suite: 136 unit tests over `MacTLMCore` (pure, Linux-portable). AppKit and SwiftUI layers are verified by live protocol, not unit tests.

**Multi-display validated 2026-08-20** — a second display (laptop built-in alongside the ultrawide) made the bundle path testable for the first time. `--apply-bundle` placed both laptop windows pixel-exact, confirming `MultiApplyPlanner` and the per-display `visibleArea` plumbing correct.

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
14. **Persisted window titles are a privacy leak, because the files are designed to be synced.** PRD §7 makes `layouts.json` and `configurations/*.json` git/Nextcloud-friendly, and titles captured browser page titles — i.e. browsing history — in plaintext. Fixed by storing `SHA-256(per-install salt ‖ title)` truncated to 16 hex chars. Matching fidelity is preserved because exact-window matching only ever needed *equality*, not the text. Untitled windows must hash to `nil`, never a shared constant, or every untitled window matches every other. Pins are unaffected: they are user-authored patterns tested against live titles in memory.
15. **A stopped-clock purge is not a purge.** Blanking titles on disk while the daemon ran was undone within seconds — the tracker holds records in memory and re-persists them. Any data-scrubbing operation has to either stop the writer first or ship in the writer itself.
16. **Namespace-scoped edits silently no-op.** `ConfigurationRecords.setPinPattern` guards on the record existing, so when the display configuration changed between the Preferences window rendering its rows and the user submitting a pin, the edit hit a namespace without that record and vanished with no error. Two lessons: a pin describes a *window*, not a monitor arrangement, so it now propagates to every namespace holding that bundle/slot; and any UI over per-configuration data needs a display-change hook to refresh (`PersistenceCoordinator.onConfigurationChanged`).
17. **Dead migration code is worse than none.** `LayoutLibraryStore.loadPurgingLegacyTitles()` shipped with no caller, so `layouts.json` kept 18 legacy `title` keys, and only the *loaded* namespace was ever scrubbed — 3 of 4 config files kept theirs. Verified by grepping for callers on the real files, not by trusting the unit test that covered the unreachable function.
18. **A guard that drops work needs a recovery path.** M2a added `guard configKey() == loadedKey else { return }` to `noteActivity` so records for one display arrangement never land in another's file. Because `loadedKey` only moved when `didChangeScreenParameters` fired, a single missed notification killed persistence *silently and permanently* until relaunch — observed live: the store froze for four minutes while the app looked healthy and a separate watcher proved AX events were flowing. The guard now migrates (flush under the old key, adopt the live one, continue the capture) and reports via `onConfigurationDrift`. Rule: never silently drop user work to protect an invariant; repair the invariant and continue.
19. **Wholesale capture destroyed the records of windows that were merely closed.** `capture` replaced `records.apps[bundleID]` with whatever was open at that instant, so reopening one document of a two-document app pruned the other's remembered frame — then order-fallback matching dragged the late window onto the survivor's position. Both documents ended up stacked at the same pixel. Capture now MERGES: matched records update in place, unmatched live windows append, and records with no live window are preserved (capped at 16 per app, never evicting a pinned or just-matched record). Found only by waiting 3s between reopening two documents; M1's acceptance passed because it opened both within a second.
20. **One identity path, not two.** `assignPins` duplicated pin resolution alongside `WindowMatcher`'s pin phase. The merge rewrite deleted it so capture and restore cannot disagree about which window is which.

## M2e / M3 (next)

- **PRD Phase 3 — magnet groups and the weighted treemap** (the headline remaining feature): drag-to-mate grouping, shared-edge resize with shrink/nudge, and preset reflows including the center/left/right-biased treemap. Now that a second display exists, Tier-2 structural reflow is testable too.
- **Per-app merged placement** — fix the residual below; now testable with two displays attached.
- **Target display choice** — when a layout's display is absent we always adapt onto the main display; offer a picker.
- **Keychain salt** — stricter storage for the window-identity salt than `UserDefaults`.
- **Re-hash on demand** — pre-M2d records carry `titleHash: nil` until their window moves again, so exact matching is degraded for them; a "relearn positions" action could refresh them deliberately.

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
