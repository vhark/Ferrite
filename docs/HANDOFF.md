# MacTLM — Session Handoff (2026-08-19)

State saved before a machine restart + macOS update. Working tree clean at `842ef10`.

## Where things stand

| | |
|---|---|
| Branch | `main`, clean, nothing uncommitted |
| Tags | `v0.1.0-m1`, `v0.2.0-m2a`, `v0.2.1-m2a` (latest) |
| Tests | 70 unit tests over `MacTLMCore`, all passing |
| App | `build/MacTLM.app`, signed with the self-signed **MacTLM Dev** identity |
| Docs | PRD `docs/superpowers/specs/2026-08-19-mactlm-prd-design.md`; plans in `docs/superpowers/plans/`; findings + backlog `docs/BACKLOG.md` |

Shipped and verified live: automatic window-position persistence (M1) and workspace templates with a per-monitor menu (M2a), including the full PRD §9 acceptance run.

## Saved user data (survives the update)

`~/Library/Application Support/MacTLM/`
- `layouts.json` — 3 layouts, all bound to display `5836EAC1-3D33-4B6C-B122-72B55ABBB379` (Odyssey G95NC):
  - `Design&Comms` — 9 entries, `clearStage` (the real working layout)
  - `SmokeScene` — 10 entries, `leaveOthers` (test scaffold, delete whenever)
  - `StageTest` — 10 entries, `clearStage` (test scaffold, delete whenever)
- `configurations/5836EAC1-…_7680x2160@1.0.json` — per-app window records for the current display setup
- `exclude.json` — only written once an app is excluded via the menu; defaults otherwise (After Effects, MATLAB — Illustrator was dropped 2026-08-21 after `--probe-frame` showed it accepts frame changes)

## Install layout (as of 2026-08-20, post macOS 26.6.2 update)

**Daily driver: `/Applications/MacTLM.app`** — installed via `scripts/install.sh` and registered for Launch at Login (`status: enabled`). It starts itself at login and asserts your saved frames, so you no longer depend on macOS Resume.

**Dev builds stay in `build/MacTLM.app`** via `scripts/make-app.sh`. Never register the build copy for login: `make-app.sh` deletes and recreates that bundle, and wiping `build/` would silently break the login item. `scripts/install.sh` re-runs the build, unregisters any build-dir login item, dittos the bundle to `/Applications`, re-registers from there, and relaunches.

Check state any time:
```bash
/Applications/MacTLM.app/Contents/MacOS/MacTLM --login-status
```

## After a restart — startup checklist

1. **It should start on its own.** If the menu-bar icon is missing, check `--login-status` above; `requiresApproval` means macOS wants you to allow MacTLM under System Settings → General → Login Items (the menu item now says "Launch at Login (needs approval)" and offers to open that pane).

2. **Accessibility permission may need re-approval after a macOS update.** Symptom: no menu-bar icon after launching.
   ```bash
   # is it waiting on permission? a line every ~2s means yes
   log stream --predicate 'process == "MacTLM"' --style compact
   ```
   Fix: System Settings → Privacy & Security → Accessibility. If MacTLM looks enabled but still doesn't work, the TCC entry is stale — remove and re-add it, or reset and relaunch:
   ```bash
   tccutil reset Accessibility dev.mactlm.MacTLM
   open /Users/vincehark/Code/MacTLM/build/MacTLM.app
   ```

3. **The signing identity survives** — "MacTLM Dev" lives in the login keychain, so rebuilds keep the grant. Verify with `security find-identity -v -p codesigning | grep "MacTLM Dev"`. If it ever disappears, `scripts/make-app.sh` silently falls back to ad-hoc signing and the grant will break on every rebuild; regenerate per finding 6 in `docs/BACKLOG.md`.

4. **If the display identity changes** (new UUID, or a different resolution/scale after the update):
   - *Persistence* starts a fresh namespace file under `configurations/`; old data is untouched and records rebuild as you use apps.
   - *Layouts* will appear under **Inactive Monitor Layouts** in the menu and launch adapted onto the main display (proportional remap). To re-anchor them, just re-save with the same names — same-name saves replace rather than duplicate.

5. **If Finder ever goes missing from captures**, restart it (`killall Finder`). The root cause is fixed in code, but a Finder process poisoned by an older build stays poisoned for its lifetime. A machine restart clears this anyway.

## Quick health check

```bash
cd /Users/vincehark/Code/MacTLM
swift test                                   # expect 70 passing
./scripts/make-app.sh && open build/MacTLM.app
./build/MacTLM.app/Contents/MacOS/MacTLM --list-windows | head -20
```
Then click a layout in the menu — windows should move to their saved frames.

## Pick up here

**M2b (next milestone)** — plan not yet written:
- **Bundles** — link the per-monitor layouts from one multi-display save so a single action restores a whole multi-monitor workspace.
- **Hotkeys** — per-layout shortcuts, completing PRD §9's "one hotkey from a clean login". Needs a recorder UI; evaluate `sindresorhus/KeyboardShortcuts` (MIT, SPM-native) since MASShortcut isn't SPM-friendly.
- **Preferences window** — Shortcuts / Apps (exclude list, pin rules) / Layouts (rename, delete, stage mode, optional flags). Today pins and `optional` are JSON-edit-only and there's no delete affordance (`deleteLayout(id:)` exists but is unused).

**One pending verification** — late-arrival restacking (`06a98d1`): when a slow app's window appears after the 15s launch deadline, it should now be pushed back to its z-position. Only reachable on a cold launch of a slow app, so the next full quit-and-relaunch of `Design&Comms` exercises it.

**Process note** — the reviewer-tier subagent hit an account rate limit late in the session (retry ~2.4 days from 2026-08-19). If it's still limited, review gates need to run in the main session rather than being skipped.
