# Ferrite — Rename and Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MacTLM becomes **Ferrite** — platform-neutral (Linux next, maybe Windows) — with every byte of user state carried over: salt, layouts, per-configuration records, magnet groups, pins, exclude list, hotkeys.

**Baseline:** `main` at `v0.10.1`, 213 tests passing. Checkpoint taken precisely so this rename has a safe point behind it.

**History is not rewritten.** Existing specs, plans, and BACKLOG findings keep "MacTLM" as historical record. Only living code, scripts, and forward-looking doc headers rename.

## Naming map (the contract)

| Old | New |
|---|---|
| Product / app / binary `MacTLM` | `Ferrite` |
| Bundle ID `dev.mactlm.MacTLM` | `dev.ferrite.Ferrite` |
| SPM targets `MacTLM` / `MacTLMCore` / `MacTLMCoreTests` | `Ferrite` / `FerriteCore` / `FerriteCoreTests` |
| `~/Library/Application Support/MacTLM/` | `~/Library/Application Support/Ferrite/` |
| Defaults key `dev.mactlm.identitySalt` | `dev.ferrite.identitySalt` |
| Env `MACTLM_TRACE_DRAG` | `FERRITE_TRACE_DRAG` |
| NSLog prefixes `MacTLM:` / `MacTLM/drag:` | `Ferrite:` / `Ferrite/drag:` |
| Signing identity `MacTLM Dev` | `Ferrite Dev` (created in Task 3, human-driven) |
| `/Applications/MacTLM.app` | `/Applications/Ferrite.app` (old removed by install) |

Test fixtures using third-party bundle IDs (`com.adobe.illustrator`, `com.apple.TextEdit`, fake `"arc"`/`"a"`/`"b"`) are **not** names of ours — leave them.

---

## Task 1: Mechanical rename

- [ ] **Step 1** `git mv Sources/MacTLM Sources/Ferrite && git mv Sources/MacTLMCore Sources/FerriteCore && git mv Tests/MacTLMCoreTests Tests/FerriteCoreTests`; update `Package.swift` (package name, target names, product, any explicit paths).
- [ ] **Step 2** Every `import MacTLMCore` / `@testable import MacTLMCore` → `FerriteCore`. Then sweep `grep -rn "MacTLM\|mactlm\|MACTLM" Sources Tests Package.swift scripts` and rename every hit per the map: bundle-ID literals, the Application Support directory component, the salt key (code side only — migration reads the old one), env var, log prefixes, UI strings (menu items, alert titles, accessibility labels, Preferences window), `Info.plist` heredoc in `make-app.sh` (also bump `CFBundleShortVersionString` to `0.11.0`), binary copy path `.build/release/Ferrite`.
- [ ] **Step 3** `scripts/install.sh`: rename throughout, AND add the transition block — if `/Applications/MacTLM.app` exists: run its `--login-unregister` (best-effort), `pkill -f "MacTLM.app/Contents/MacOS/MacTLM"`, `rm -rf /Applications/MacTLM.app`, echo what was removed. `pkill` patterns must cover both names during transition.
- [ ] **Step 4** Docs, forward-looking only: one-line rename note at the top of `docs/BACKLOG.md` and of the PRD spec ("Renamed MacTLM → Ferrite at v0.11.0; historical text below keeps the old name"). Do not touch findings/specs/plans bodies.
- [ ] **Step 5** Verify: `swift build` clean; `swift test` 213/0 (a pure rename changes zero behavior); `grep -rn "MacTLM" Sources Tests Package.swift scripts` returns ONLY hits you can justify line-by-line (expected: the install.sh transition block and the migration constants added in Task 2). Do NOT run make-app.sh (old identity is gone from the script; new one doesn't exist until Task 3). Do NOT launch anything.
- [ ] **Step 6: Commit** — `rename: MacTLM becomes Ferrite, platform-neutral`

---

## Task 2: Legacy migration (TDD)

One-shot, first-launch, copy-never-delete: the old MacTLM state remains on disk as its own backup.

**Files:** create `Sources/FerriteCore/LegacyMigration.swift`, `Tests/FerriteCoreTests/LegacyMigrationTests.swift`; wire into startup in `Sources/Ferrite` (before any store loads — find where `LayoutLibraryStore`/`WindowTracker` first read and run migration ahead of it).

Contract (`LegacyMigration.run(oldDirectory:newDirectory:oldDefaults:newDefaults:) -> Report`):
1. **Files:** if `newDirectory` does not exist and `oldDirectory` does → create parent, copy the whole directory (layouts.json, configurations/, exclude.json). New dir already exists → no file action (idempotent; a half-adopted install is never clobbered).
2. **Salt:** if new defaults lack `dev.ferrite.identitySalt` and old defaults have `dev.mactlm.identitySalt` → copy the Data verbatim. THE load-bearing step: a lost salt kills every stored titleHash silently (finding 14).
3. **Hotkeys:** copy every old-domain key prefixed `KeyboardShortcuts_` absent from the new domain (the library reads the app's standard defaults, so copied keys light up with no library changes).
4. Returns a Report (filesCopied, saltMigrated, hotkeyKeysCopied, skippedBecause) — logged once at startup, `Ferrite: migrated …`.

- [ ] **Step 1 — tests first** (temp directories; `UserDefaults(suiteName: "dev.ferrite.test.<uuid>")` with `removePersistentDomain` teardown — never the real domains): fresh-machine no-op; full migration (dir + salt bytes verbatim + two hotkey keys); idempotence (second run reports all-skipped, files untouched — compare mtimes or content hashes); existing-new-dir never overwritten even when old exists; salt never overwritten when both domains have one; hotkey copy skips keys already present. ~7 tests → expect 220.
- [ ] **Step 2** Run, watch fail. **Step 3** Implement (Foundation only — `UserDefaults` and `FileManager` are in corelibs-foundation, so Core stays portable; still guard with the usual `#if canImport` pattern only where actually needed). **Step 4** Run, watch pass; Core purity grep (AppKit/CryptoKit) empty.
- [ ] **Step 5** Startup wiring: real call sites pass `UserDefaults(suiteName: "dev.mactlm.MacTLM")` and `.standard`, old dir `~/Library/Application Support/MacTLM`, new `…/Ferrite`.
- [ ] **Step 6** Verify: build clean, `swift test` 220/0. **Commit** — `feat: one-shot migration of MacTLM state into Ferrite`

---

## Task 3: Identity, install, live verification (human-driven — Main + user; do not attempt from an agent)

- [ ] **Step 1** Create the `Ferrite Dev` signing identity (openssl self-signed with `extendedKeyUsage=codeSigning`, pkcs12, `security import -T /usr/bin/codesign`); confirm `security find-identity -v -p codesigning` lists it.
- [ ] **Step 2** `./scripts/install.sh` — expect: old MacTLM daemon stopped, unregistered and removed; Ferrite installed; ONE keychain prompt (user clicks **Always Allow**); login-item registration reported (may show `requiresApproval`).
- [ ] **Step 3** TCC: System Settings → Privacy & Security → Accessibility — REMOVE the stale MacTLM entry (never just toggle, finding 6), add/approve Ferrite. `--list-windows` proves the grant.
- [ ] **Step 4** Migration proof, all four legs: menu lists the existing layouts; a saved workspace hotkey fires; Groups section still knows the magnet groups; capture still hash-matches (quit/reopen one two-window app → windows return to their own positions, proving the salt survived byte-for-byte).
- [ ] **Step 5** `docs/BACKLOG.md` shipped row + acceptance note; refresh `docs/HANDOFF.md` names; tag `v0.11.0-ferrite`.

---

## Plan self-review notes

- **Salt is the whole ballgame.** Everything else recoverable by hand; a lost salt silently orphans every titleHash on disk. Hence: verbatim-bytes test, never-overwrite test, and the live leg in Task 3 Step 4 that only passes if the real salt crossed over.
- **Copy, never move:** the MacTLM directory and defaults domain stay behind as the rollback path, matching the v0.10.1 checkpoint stance.
- **Risk — `UserDefaults(suiteName:)` for another bundle's domain** is plain plist reading for a non-sandboxed app; if macOS 26 returns empty for the old domain, fall back to reading the plist file directly and REPORT it — do not silently skip the salt.
- **Deliberate omission:** no repo-directory rename in this plan (`~/Code/MacTLM` → `~/Code/Ferrite` is a user/tooling choice after the dust settles); no Homebrew/notarization (that is PRD M4).
