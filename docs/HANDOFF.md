# Ferrite — Session Handoff (2026-08-24, post-rename)

State saved at tag `v0.11.0-ferrite` on `main`. Working tree clean. 220 unit tests, 0 failures.

## What Ferrite is

A macOS-first window layout manager (Linux next): automatic per-app position persistence, workspace templates with per-bundle hotkeys, and magnet groups — windows mated by dragging edges together, carried as a cluster with ⌘-drag, resized with shared-edge shrink/nudge, scaled proportionally from outer edges, and reflowed into weighted-treemap presets. Formerly **MacTLM**; renamed at this tag for the cross-platform future.

## Where things stand

Full shipped table with per-milestone live-acceptance notes: `docs/BACKLOG.md` (`v0.1.0-m1` through `v0.11.0-ferrite` — every tag was cut only after passing its live protocol on the user's machine). 27-item platform findings list there is **authoritative** — read it before touching AX, TCC, signing, caches, event handling, or persistence.

- Daemon: `/Applications/Ferrite.app` (`dev.ferrite.Ferrite`), running, Launch-at-Login enabled, Accessibility granted (stale MacTLM entry removed by hand).
- Signing: `Ferrite Dev` self-signed identity (openssl + `security import` + `add-trusted-cert -p codeSign`; keychain ACL "Always Allow" clicked — codesign is silent). Never ad-hoc sign: it re-keys TCC per build (finding 6).
- Dev loop: `scripts/make-app.sh` → `build/Ferrite.app`; `scripts/install.sh` → `/Applications` + login item. `install.sh` still carries the one-time MacTLM transition block — harmless now, removable later.
- Gesture tracing: `FERRITE_TRACE_DRAG=1` (findings 22–26 were all diagnosed with it). Diagnostics: `--list-windows`, `--list-displays`, `--probe-frame <bundleID>`, `--login-status`, `--apply-bundle`.

## User data

- `~/Library/Application Support/Ferrite/` — layouts.json, per-configuration records + magnet groups, exclude.json. Sync-friendly; window titles are salted hashes, never plaintext.
- `defaults dev.ferrite.Ferrite` — identity salt (32 bytes, key `dev.ferrite.identitySalt`) + hotkey assignments. The salt is load-bearing: losing it orphans every stored titleHash (finding 14).
- **Rollback:** the old `~/Library/Application Support/MacTLM/` directory and `dev.mactlm.MacTLM` defaults domain were deliberately left intact by the copy-never-delete migration (`LegacyMigration`, one-shot, idempotent). Safe to delete once Ferrite has been trusted for a while.

## Pending verification (needs the right moment, not work)

- **Late-arrival restacking** (`06a98d1`): a cold bundle launch where a slow app (Illustrator) takes >15s to draw.
- **A→B group membership move**: first time two magnet clusters exist and a member is dragged from one onto the other.

## Open backlog (all optional)

Keychain salt storage · re-hash on demand for pre-M2d records · target-display picker · delete the install.sh transition block after a while · rename the repo directory (`~/Code/MacTLM` → `~/Code/Ferrite` — user/tooling choice) · PRD M4: README, Homebrew cask, notarization (the public-release bar; why no 1.0 yet) · Linux port: `FerriteCore` has zero AppKit imports, a Linux build needs only a new `WindowDriving` (sway/Hyprland IPC or EWMH).

## How to resume

Specs in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/` — every milestone has both; plans carry post-execution corrections and stay truthful about deviations. Historical docs keep the MacTLM name on purpose; only living code and forward-looking text renamed.
