# MacTLM — Session Handoff (2026-08-24, pre-rename checkpoint)

State saved at tag `v0.10.1` on `main`. Working tree clean. 213 unit tests, 0 failures.

## Where things stand

The **entire PRD arc is shipped and live-verified** — every milestone tagged after passing its live protocol on the user's machine, never on unit tests alone:

| Tag | Milestone |
|---|---|
| `v0.1.0-m1` | Position persistence (automatic per-app capture/restore) |
| `v0.2.0–v0.2.2-m2a` | Workspace templates, stacking correctness, install + login item |
| `v0.3.0-m2b` | Bundles, per-bundle hotkeys, Preferences window |
| `v0.4.0-m2c` | Apps tab, per-entry editing |
| `v0.5.0/1-m2d` | Hashed window identity — no titles ever persisted |
| `v0.6.0-m3a` | Preset reflow solvers + weighted treemap, evidence-based exclusions |
| `v0.7.0-m3b` | Magnet groups: drag-to-mate, shrink/nudge resize, weights, menu |
| `v0.8.0-m3c` | Proportional group scale (outer edge/corner, settle-on-release) |
| `v0.9.0-m3d` | ⌘ group drag with ghost outlines; drag-away un-mate |
| `v0.10.0-m2e` | Merged per-app placement across displays (residual retired) |

Daemon: `/Applications/MacTLM.app`, running, Launch-at-Login `enabled`. Accessibility grant stable (bound to the "MacTLM Dev" signing identity; its keychain ACL is permanent after an "Always Allow" — codesign is silent). Dev builds: `scripts/make-app.sh` → `build/`; daily driver: `scripts/install.sh`.

## Rename pending (next work item)

The user wants a platform-neutral name (Linux next, maybe Windows) — "Mac" must leave the name. Decided at this checkpoint so the rename lands as its own milestone ON TOP of this tag. The rename's real costs, mapped in advance:

- **TCC re-grant is unavoidable.** The Accessibility grant binds to the signature's designated requirement, which includes the bundle ID (`dev.mactlm.MacTLM`). New bundle ID → one-time re-approval; stale entries must be removed, not toggled (finding 6).
- **The identity salt MUST migrate** (`dev.mactlm.identitySalt` in the `dev.mactlm.MacTLM` defaults domain). Losing it kills every stored `titleHash` — matching would silently degrade to pins and order for all existing records (finding 14 territory).
- **Also migrating:** `~/Library/Application Support/MacTLM/` (layouts.json, configurations/*.json, exclude.json), KeyboardShortcuts assignments (`bundle-<name>` keys, same defaults domain), login-item registration (old bundle unregistered, new registered — may show "needs approval"), old app bundle removal.
- **Mechanical scope:** SPM targets `MacTLM`/`MacTLMCore`/`MacTLMCoreTests`, every `import MacTLMCore`, `MACTLM_TRACE_DRAG`, NSLog prefixes, scripts, docs. Repo directory rename last and optional.

## User data (all local to this machine)

- `~/Library/Application Support/MacTLM/` — layouts, per-configuration records + magnet groups, exclude list. Designed to be synced (git/Nextcloud); titles are salted hashes, never plaintext.
- `defaults dev.mactlm.MacTLM` — identity salt (32 bytes), hotkey assignments.
- Salt deliberately OUTSIDE the synced directory; Keychain storage is a queued hardening item.

## Pending verification (needs the right moment, not work)

- **Late-arrival restacking** (`06a98d1`): a cold bundle launch where a slow app (Illustrator) takes >15s to draw its window.
- **A→B group membership move**: first time two magnet clusters exist and a member is dragged from one onto the other.

## Open backlog (all optional)

Keychain salt · re-hash on demand for pre-M2d records · target-display picker · PRD M4 (README, Homebrew cask, notarization — the public-release bar; why this checkpoint is not v1.0.0) · Linux port (`MacTLMCore` has zero AppKit imports — that seam is the entire strategy; a Linux build needs only a new `WindowDriving` implementation).

## How to resume

- `docs/BACKLOG.md` is authoritative: 26 platform findings paid for in blood — read before touching AX, TCC, signing, caches, or persistence.
- Specs in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/` — every milestone has both, plans carry post-execution corrections.
- Diagnostics: `--list-windows`, `--list-displays`, `--probe-frame <bundleID>`, `--login-status`, `--apply-bundle`; live gesture tracing via `MACTLM_TRACE_DRAG=1` (findings 22–26 were all diagnosed with it).
- The reviewer-tier subagent rate limit encountered 2026-08-19 (~2.4-day retry) may matter if review gates are reinstated.
