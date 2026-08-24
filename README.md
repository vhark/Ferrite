# Ferrite

A window layout manager for macOS (Linux planned). Ferrite remembers where your windows live, restores whole workspaces with one hotkey, and lets windows snap together into **magnet groups** that move, resize, and reflow as one.

Ferrite is *not* a classic auto-tiler: windows stay free-floating and may overlap. Structure is something you opt into, one edge at a time.

## Highlights

- **Position persistence** — every app's windows are remembered automatically and restored when the app relaunches, when you log in, or when your display configuration changes. No setup.
- **Workspaces** — snapshot your whole desktop as a named layout, per display. One hotkey restores everything: running apps snap into place, missing apps are launched and placed, stacking order included.
- **Magnet groups** — drag a window near another's edge and they mate flush. Mated windows resize together (shrink or nudge), scale proportionally like one combined window, carry as a cluster with ⌘-drag, and reflow into presets — including a weighted treemap that sizes windows by rank.
- **Private by design** — window titles are never written to disk, only salted hashes. The data files are built to be synced (git, Nextcloud) without leaking your browsing history.

## Install

**Homebrew** — available once the first notarized release (1.0) ships:

```sh
brew tap vhark/ferrite https://github.com/vhark/Ferrite.git
brew install --cask ferrite
```

**From source** (Swift 5.9+, macOS 13+):

```sh
git clone https://github.com/vhark/Ferrite.git && cd Ferrite
./scripts/install.sh
```

This builds `Ferrite.app`, installs it to `/Applications`, and registers Launch at Login. On first run, macOS will ask you to grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility) — Ferrite cannot see or move windows without it. If Login Items shows "needs approval," allow Ferrite there too.

Optional, for rebuild-stable permissions during development: create a self-signed **"Ferrite Dev"** code-signing identity (see the guide's *Building from source* section). Without it, builds are ad-hoc signed and macOS drops the Accessibility grant on every rebuild.

## Quick start

1. Arrange your windows the way you like.
2. Menu bar icon → **Save Current Arrangement as Layout…**, give it a name.
3. Open **Preferences… → Layouts** and record a hotkey for it.
4. Rearrange everything, then press the hotkey: your workspace comes back — including apps that weren't running.
5. Drag one window's edge close to another's until the blue bar appears, release — they're mated. ⌘-drag either one to carry both.

## Documentation

The full manual — every gesture, menu item, preference, CLI diagnostic, and troubleshooting recipe — is in [`docs/GUIDE.md`](docs/GUIDE.md).

## Status

macOS-first and used daily by its author. The core engine (`FerriteCore`) is pure Foundation with no AppKit dependency — the Linux port needs only a new window driver (sway/Hyprland IPC or EWMH). 220 unit tests; every feature was additionally verified by live protocol on real hardware before shipping.

## Acknowledgments

- [Rectangle](https://github.com/rxhanson/Rectangle) (Ryan Hanson, MIT) — the proven position→size→position AX write sequence Ferrite's window driver uses, and the original seed of the exclude list (now evidence-based via `--probe-frame`).
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (Sindre Sorhus, MIT) — global hotkey recording and registration.

## License

[MIT](LICENSE).
