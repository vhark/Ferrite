# Keep Mac Awake (Alpha) — Design

- **Date:** 2026-11-03 · **Status:** Approved alpha design, pre-implementation
- **Baseline:** `10f44f9` (`feat/automatic-app-clusters`)
- **Requested behavior:** Caffeine-style keep-awake operation, extended to closed-lid use without an external display.

## 1. Feature contract

**Keep Mac Awake (Alpha)** is an opt-in Ferrite feature. While active on AC power it must:

- prevent idle system sleep;
- prevent idle display sleep and dimming;
- prevent the idle screen saver and idle lock screen;
- prevent automatic logout after inactivity, keeping the login session and its apps open;
- prevent sleep when the laptop lid closes, with no external display required;
- restore normal power behavior when disabled; and
- restore the user's enabled preference after Ferrite relaunches and after reboot/login.

Closed-lid operation is **AC-only**. Removing AC immediately releases the closed-lid override and all app assertions. The saved preference remains enabled, shows **Waiting for AC**, and automatically reactivates when AC returns. Activation on battery is refused.

The feature does not support battery operation, timed durations, MDM-policy bypass, or rewriting the user's screen-saver, lock, or logout security preferences. Explicit user lock/logout/shutdown remain outside the feature. While the global closed-lid override is active, macOS can ignore manual sleep requests as well as lid-close sleep; disabling Keep Awake restores normal sleep behavior.

Automatic logout suppression has no logout-specific public API. Ferrite will use periodic local-user-activity declarations, following maintained Caffeine's mechanism. This part of the contract is provisional until the live automatic-logout acceptance test passes.

## 2. Research findings and rejected approaches

Apple's IOKit contract distinguishes `kIOPMAssertPreventUserIdleSystemSleep` from `kIOPMAssertPreventUserIdleDisplaySleep`. The system assertion still permits display sleep; both permit lid-close sleep. The display assertion prevents idle display dimming/off but does not relight an already-dark display. `IOPMAssertionDeclareUserActivity` declares local user activity, can relight the display, and can be repeated with the returned assertion ID.

Apple's `caffeinate -i` and `-d` map to those two assertions. Its `-u` option declares user activity. Maintained Caffeine periodically calls `IOPMAssertionDeclareUserActivity` and holds the display-sleep assertion. Neither mechanism guarantees displayless closed-lid operation.

`pmset -a disablesleep 1` is the stronger system-wide override needed for that closed-lid case. `pmset` modifications require root. The setting is global and has no built-in application ownership, so Ferrite must add ownership and cleanup safeguards.

Sources:

- [Apple IOKit power API](https://developer.apple.com/documentation/iokit/iopmlib_h) and the installed `IOKit/pwr_mgt/IOPMLib.h` assertion contracts.
- [Apple's `caffeinate` implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/caffeinate/caffeinate.c).
- [Apple automatic-logout guidance](https://support.apple.com/guide/mac-help/set-your-mac-to-log-out-when-not-in-use-mchlp2443/mac).
- [Apple sleep-settings guidance](https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac).
- [Maintained Caffeine source](https://github.com/IntelliScape/caffeine/blob/master/AppDelegate.m).
- [KeepingYouAwake closed-lid limitation](https://github.com/newmarcel/KeepingYouAwake#does-it-work-on-a-macbook-with-a-closed-lid).

Rejected alternatives:

1. **In-process assertions only:** simplest and safest, but cannot meet closed-lid/no-display operation.
2. **Scoped sudoers rule:** avoids a persistent root helper but leaves a passwordless system-power rule and cannot reliably clean up after forced Ferrite termination.
3. **One-shot administrator prompts:** cannot disable automatically on unplug or client failure without another authorization prompt.

The approved approach is a narrow privileged helper plus an app-side controller.

## 3. Components and ownership

### App-side `KeepAwakeController`

Owned by `AppDelegate` independently of window-persistence behavior and injected into the status-menu and Preferences controllers. It owns:

- the desired-state preference and live feature state;
- `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` assertions;
- an immediate `IOPMAssertionDeclareUserActivity` call and a repeating 30-second heartbeat;
- the current user-activity assertion ID, replacing it as returned by IOKit;
- Launch at Login registration needed for reboot restoration;
- AC loss/reconnect coordination with the helper; and
- rollback and user-facing errors.

The controller uses actual helper and assertion state, never the persisted preference alone, when presenting status.

### Privileged `FerriteKeepAwakeHelper`

A command-line executable registered through `SMAppService.daemon(plistName:)` as a root LaunchDaemon. It has a narrow XPC interface: enable, disable, and query status. It accepts no caller-supplied executable, path, or arbitrary argument list. Its only power mutations are the fixed commands:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

The helper validates the connecting client's audit token and code-signing identity against Ferrite before accepting requests. Unsigned or incorrectly signed clients are rejected.

The helper itself checks the power source before enabling, refuses battery activation, and monitors AC while enabled. It does not trust an app-side AC check. LaunchDaemon configuration starts it at boot and restarts it after failure so stale helper-owned state can be cleaned even if Ferrite is not running.

### Preference storage

A new power-settings store persists only `keepAwakeEnabled`, defaulting to `false` when absent or unreadable. It is separate from `magnets.json`; power management is not a magnet preference. The desired preference survives relaunch and reboot. Actual assertion IDs, XPC state, and helper ownership are runtime/helper state, not user preferences.

## 4. Closed-lid override ownership

`SleepDisabled` is global and has no owner. Ferrite must not adopt or clear an override it did not create.

- On activation, the helper queries the current setting. If it is already enabled without Ferrite's ownership record, activation fails with **External sleep override already active**.
- When the helper successfully enables the setting, it records helper ownership in root-only state.
- Helper startup clears the setting only when that ownership record says this helper previously enabled it. After confirmed cleanup, it clears the stale record before accepting activation. If cleanup fails, it retains the record, rejects activation, and reports **Error**.
- Disable and client-disconnect cleanup run only for helper-owned activation. Clearing an already-normal setting is harmless and idempotent.
- After a helper restart, Ferrite may reactivate its saved preference only after startup cleanup and only on AC.
- The helper verifies command results and resulting state before reporting success.

This ownership rule also covers reboot: the helper cleans stale helper-owned state at boot; Ferrite deliberately re-enables later through Launch at Login.

## 5. Activation, deactivation, and recovery

### Activation

1. The user enables Keep Awake. Ferrite registers Launch at Login if needed.
2. The app registers/connects to the privileged helper, triggering macOS approval UI on first use.
3. The helper rejects battery operation or an unmanaged pre-existing override; otherwise it enables and records the closed-lid override.
4. The app creates both sleep assertions and declares user activity immediately.
5. The menu and Preferences report **Active** only after all required pieces succeed.

If Launch at Login needs separate user approval, current-session activation may continue, but Preferences shows that reboot restoration is not yet guaranteed.

### Normal disable

Selecting Off clears the saved preference, stops the heartbeat, releases both app assertions and the user-activity assertion, and asks the helper to clear its owned override. Launch at Login remains unchanged because it is an independent Ferrite preference.

### AC loss and return

On AC loss the helper clears its owned override. The app stops the heartbeat and releases its assertions. The preference stays enabled and the state becomes **Waiting for AC**. AC return repeats activation automatically. Selecting Off while waiting clears the preference without requiring activation first.

### Client and helper lifecycle

Normal quit, forced termination, logout, and XPC invalidation all lead the helper to release helper-owned state. The app releases its own assertions on normal termination; process death releases its IOKit assertions automatically.

On helper startup/restart, the helper cleans only stale helper-owned state. A running Ferrite instance reconnects and reapplies its desired state on AC; without a client, the helper remains normal-sleep-only. At boot, the helper performs that cleanup before Ferrite's login launch reactivates the preference.

### Failure and rollback

Rejected helper commands, partial assertion creation, heartbeat failure, or inconsistent actual state never report **Active**. Ferrite releases any app assertions it created and requests helper cleanup.

A failed cleanup command cannot be represented as successful rollback. The helper retries failed safety cleanup, retains the ownership record until normal state is confirmed, and reports **Error**. The UI shows the concrete failure and the manual recovery command `sudo pmset -a disablesleep 0`. There is no silent lid-open-only fallback.

## 6. User interface

A new **Preferences → Power** tab contains:

- **Keep Mac Awake (Alpha)**, off by default for existing and new users;
- a concise behavior and security explanation, including system-wide closed-lid override and AC-only operation;
- live state: **Off**, **Active**, **Waiting for AC**, **Approval needed**, or **Error**;
- helper installation/approval and Launch-at-Login approval status/actions; and
- error details and manual recovery guidance when cleanup fails.

Ferrite's existing status menu gains the same toggle and live state. The existing Ferrite status icon remains unchanged; this alpha adds no second menu-bar icon.

Disabling the feature never disables Launch at Login. If the user later disables Launch at Login while Keep Awake remains enabled, Preferences warns that reboot restoration is unavailable.

## 7. Testing strategy

### Policy and preference tests

Use deterministic fake power-source and command providers to exercise behavior, not real machine power settings:

- absent settings default off; enabled desired state round-trips;
- activation on AC succeeds and activation on battery is refused;
- AC loss releases actual state while preserving desired state; AC return reactivates;
- client disconnect and helper restart clear only helper-owned state;
- pre-existing unmanaged `SleepDisabled` is neither adopted nor cleared;
- repeated enable/disable is idempotent;
- command failure rolls back partial activation and failed cleanup remains visibly erroneous;
- reboot cleanup followed by login restoration preserves the approved lifecycle; and
- unsigned or incorrectly signed clients are rejected through the helper's validation boundary.

### Assertion lifecycle tests

Using a controllable assertion/activity provider, verify:

- immediate assertion and activity creation;
- heartbeat replacement of returned activity assertion IDs;
- full release on disable and AC loss;
- partial creation failure releases already-created assertions; and
- relaunch/reconnect restores the desired state without leaking duplicate assertions.

Tests assert consumer-visible state and cleanup effects. No test calls `pmset` or changes the developer Mac's actual settings.

### Build and packaging verification

- Existing `swift test` suite remains green.
- App and helper build for both release architectures.
- The helper plist and executable are placed where `SMAppService` expects them.
- Nested helper signing is completed before app signing; strict signature verification covers both.
- The existing release flow continues to produce a notarizable app with the helper included.

## 8. Live alpha acceptance protocol

Record macOS version, hardware, power state, and Ferrite build for every run.

1. **Assertions:** enable the feature and confirm Ferrite's system/display assertions in `pmset -g assertions`; confirm helper-owned `SleepDisabled` changes only while active.
2. **Idle session:** configure the shortest practical screen-saver, idle-lock, and automatic-logout intervals. Leave the Mac untouched beyond each threshold plus a margin. Verify no screen saver, lock, or logout and that pre-existing apps remain open. Restore the user's settings afterward.
3. **Lid open:** exceed the normal idle-sleep/display timers without input; verify the Mac and display remain awake.
4. **Closed lid:** on AC with no external display, close the lid beyond the normal sleep interval; verify the login session and running processes remain active.
5. **AC safety:** unplug while closed; verify the override and app assertions release and normal sleep is allowed. Reconnect; verify automatic reactivation.
6. **Lifecycle:** verify normal quit/relaunch, forced Ferrite termination, helper restart, logout, and reboot/login cleanup/restoration. Reboot restoration must also be checked on battery, where the state must remain **Waiting for AC**.
7. **Disable recovery:** disable the feature and verify ordinary manual sleep and configured idle sleep return.
8. **Failure injection:** exercise rejected clients, helper command failure, external pre-existing override, and simulated cleanup failure without leaving the Mac in an unreported overridden state.

The feature is not accepted for automatic-logout prevention until step 2 passes. A failure there blocks the claimed contract; it must not be hidden by documentation wording alone.

## 9. Documentation and release posture

Implementation updates README, GUIDE, HANDOFF, and BACKLOG with **Alpha** terminology, AC-only constraints, privileged-helper approval, global-override ownership, and live verification results. The feature ships off by default and remains alpha until the complete live protocol passes on the user's Mac.

## 10. Known limits

- `disablesleep` is system-wide while Ferrite owns it; other users and power utilities observe the same override.
- AC-only enforcement reduces battery/bag risk but does not detect bags, blocked ventilation, or unsafe thermal conditions. The alpha adds no thermal controller.
- Manual sleep can be suppressed along with lid-close sleep while the override is active.
- Reboot restoration depends on macOS allowing Ferrite's Launch at Login/background items.
- MDM-enforced lock/logout policy and explicit user lock/logout/shutdown are not bypassed.
- A root or power-system failure can make cleanup fail; Ferrite must surface that state and manual recovery rather than claim success.
