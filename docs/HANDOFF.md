# Ferrite — Session Handoff (2026-09-23)

State: `main` includes M4 release infrastructure, the public website at https://vhark.github.io/Ferrite/, M6 reflow presets v2 and Standard resize mode, the live-verified resize-propagation gate (finding 27), configurable mate reach (32 pt default, live-confirmed 2026-09-05), the signing timeout (finding 28), and repeat-click direction toggling for Columns/Rows display reflows. **273 unit tests, 0 failures**, verified 2026-09-23. The direction toggle also passed a standalone solver smoke run; native menu acceptance remains. M6 live acceptance is in progress: Step 1 passed; resume at Step 2. No `v0.12.0-m6` tag until the remaining protocol passes.

## What Ferrite is

A macOS-first window layout manager (Linux next): automatic per-app position persistence, workspace templates with per-bundle hotkeys, and magnet groups — windows mated by dragging edges together, carried as a cluster with ⌘-drag, resized with shared-edge shrink/nudge, scaled proportionally from outer edges, and reflowed into weighted-treemap presets. Formerly **MacTLM**; renamed at this tag for the cross-platform future.

## Where things stand

Full shipped table with per-milestone live-acceptance notes: `docs/BACKLOG.md` (`v0.1.0-m1` through `v0.11.0-ferrite` — every tag was cut only after passing its live protocol on the user's machine). The 28-item platform findings list there is **authoritative** — read it before touching AX, TCC, signing, caches, event handling, or persistence.

- Daemon: `/Applications/Ferrite.app` (`dev.ferrite.Ferrite`), running, Launch-at-Login enabled, Accessibility granted (stale MacTLM entry removed by hand).
- Signing: `Ferrite Dev` self-signed identity (openssl + `security import` + `add-trusted-cert -p codeSign`; keychain ACL "Always Allow" clicked — codesign is silent). Never ad-hoc sign: it re-keys TCC per build (finding 6).
- Dev loop: `scripts/make-app.sh` → `build/Ferrite.app`; `scripts/install.sh` → `/Applications` + login item; `scripts/release.sh <x.y.z>` → notarized public release (runbook: `docs/RELEASING.md`). `install.sh` still carries the one-time MacTLM transition block — harmless now, removable later.
- Gesture tracing: `FERRITE_TRACE_DRAG=1` (findings 22–27 were all diagnosed with it). Diagnostics: `--list-windows`, `--list-displays`, `--probe-frame <bundleID>`, `--login-status`, `--apply-bundle`.

## User data

- `~/Library/Application Support/Ferrite/` — layouts.json, per-configuration records + magnet groups, exclude.json, reflows.json (custom reflow presets + display-reflow group policy), magnets.json (mate reach, written when customized). Sync-friendly; window titles are salted hashes, never plaintext.
- `defaults dev.ferrite.Ferrite` — identity salt (32 bytes, key `dev.ferrite.identitySalt`) + hotkey assignments. The salt is load-bearing: losing it orphans every stored titleHash (finding 14).
- **Rollback:** the old `~/Library/Application Support/MacTLM/` directory and `dev.mactlm.MacTLM` defaults domain were deliberately left intact by the copy-never-delete migration (`LegacyMigration`, one-shot, idempotent). Safe to delete once Ferrite has been trusted for a while.

## Pending verification (needs the right moment, not work)

- **Late-arrival restacking** (`06a98d1`): a cold bundle launch where a slow app (Illustrator) takes >15s to draw.
- **A→B group membership move**: first time two magnet clusters exist and a member is dragged from one onto the other.
- **M6 reflow presets v2 + `.standard` resize mode**: Step 1 passed (display/group menu sections, wrapped glyphs, Keep toggle). Resume the plan's live protocol at Step 2: five new built-ins; then custom Grid and Main centre, explode/keep policies, explicit group and submenu targeting with Grow reapply, and Standard vs Shrink/Nudge. Only after those pass should M6 enter the shipped table and receive its tag.
- **Columns/Rows repeat direction**: on the display row, click three times → original/reversed/original placement. Change focus between clicks; it must not change that sequence. With Keep enabled, groups swap as whole tiles without reflecting their internal formation. Repeat history is per display and in memory only. Other presets, custom presets, and group-only actions remain unchanged.

## Open backlog (all optional)

Keychain salt storage · re-hash on demand for pre-M2d records · target-display picker · delete the install.sh transition block after a while · M6 reflow presets v2 and the `.standard` resize mode are implemented and pending live verification (above), not open work · Linux port: `FerriteCore` has zero AppKit imports, a Linux build needs only a new `WindowDriving` (sway/Hyprland IPC or EWMH).

**Known defect:** excluding an app does not prune its existing magnet memberships. Ungroup first; otherwise group carry/reflow can still move it. The fix is tracked in BACKLOG and remains deferred until after M6 acceptance.

**PRD M4 (public release):** README, GUIDE, MIT license, issue templates, Rectangle/KeyboardShortcuts attribution, Homebrew cask (`Casks/ferrite.rb`, this repo doubles as the tap), and the full notarization pipeline (`scripts/release.sh`, runbook in `docs/RELEASING.md`) are all in place. The only remaining gate to a public 1.0 is credentials: enroll in the Apple Developer Program, install a Developer ID Application certificate, run `xcrun notarytool store-credentials ferrite-notary`, then `scripts/release.sh 1.0.0`. Dry-run verified with `--no-notarize`.

## How to resume

Specs in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/` — every milestone has both; plans carry post-execution corrections and stay truthful about deviations. Historical docs keep the MacTLM name on purpose; only living code and forward-looking text renamed.
