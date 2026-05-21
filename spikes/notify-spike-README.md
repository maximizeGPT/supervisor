# Spike 2 — UNUserNotificationCenter on an unsigned dev build

## What it tested

Whether `UNUserNotificationCenter` (the modern macOS notification API)
works for an unsigned, ad-hoc-built Supervisor.app — i.e. a v0.1.0 build
on Mohammed's own Mac, with no Apple Developer ID, no notarization.

The realistic worry: Apple has been tightening notification entitlements
over the last few macOS releases. If the framework refuses to even
schedule a notification without a real signature, the entire v0.1.0
intervention surface (which is notify-only) collapses.

## How it tested it

`notify_spike.swift` is wrapped into a minimal `NotifySpike.app` bundle
by `build_notify_app.sh`, with a proper `CFBundleIdentifier`
(`live.supervisor.notifyspike`). The spike:

1. Reads current `UNNotificationSettings` (does not prompt).
2. Calls `requestAuthorization([.alert, .sound, .badge])`.
3. Logs the result (granted / error).
4. Attempts to schedule a notification with `center.add(...)` regardless.
5. After 3s, queries pending and delivered notifications.

Three configurations were tested:

- **Default `swiftc` ad-hoc** (no explicit `codesign` step).
- **+ LaunchServices registration** via `lsregister -f`.
- **+ Explicit `codesign --force --sign - --entitlements`** with bundle
  identifier matching `CFBundleIdentifier`.

## What it found

| Configuration | auth status | alert setting | `requestAuthorization` | `center.add` | Banner display |
|---|---|---|---|---|---|
| `swiftc`-only (codesign `Identifier=NotifySpike`, mismatched) | `notDetermined` | `notSupported` | ❌ `UNErrorDomain Code=1` | ❌ Code=1 | no |
| + `lsregister -f` | same | same | ❌ same | ❌ same | no |
| **+ `codesign --force --sign -` with matching Identifier** | `denied` (cached from earlier failure) | `enabled` | ❌ Code=1 "not allowed" | ✅ **delivered** | ⚠️ in Notification Center, no banner |

The transition is the explicit `codesign --force --sign -` step.
`swiftc`'s default ad-hoc signature puts `Identifier=<executable-name>`
in the CodeDirectory; the notification subsystem requires this to match
`CFBundleIdentifier` and rejects mismatches with `Code=1 "notSupported"`.

Other findings:

- **`center.add` succeeds even when auth is `denied`.** Notifications
  land in the user's Notification Center delivered list — visible if
  they open the menu-bar Notification Center icon. Banners are
  suppressed. This is a real graceful-degradation path.
- **Denial is sticky and not programmatically resettable.** Once
  `requestAuthorization` errors out (e.g., from the first run with bad
  signing), macOS caches `denied` indefinitely. `tccutil reset` does
  **not** reset notification permissions — they're owned by `usernoted`,
  not the TCC database. Recovery is **System Settings → Notifications →
  [app] → toggle Allow Notifications**.
- **The first launch's signing state is therefore load-bearing.** A
  badly-signed first run can poison the OS cache before the user ever
  sees a permission prompt.

## What v0.1.0 does because of this

Three new items in Phase A that weren't in the original plan:

1. **`Scripts/sign-adhoc.sh`** is used by every dev build, not just at
   release. The script runs `codesign --force --sign - --entitlements
   <plist>` and asserts `codesign -dv | grep "Identifier="` matches
   `CFBundleIdentifier`. Fails loudly if not.

2. **`Notifier.swift` is built defensively.** It assumes
   `requestAuthorization` can fail and assumes `denied` can be reached
   without user action. Both surfaces are typed in `NotifierError`. The
   `getNotificationSettings` query is used as the source of truth for
   the onboarding flow, not the boolean returned by
   `requestAuthorization`.

3. **Onboarding's notifications step** (in Phase B) detects three
   states from `getNotificationSettings`: `notDetermined` (prompt),
   `denied` (deep-link to System Settings → Notifications), `authorized`
   (proceed). A banner-suppressed fallback message warns the user once:
   "Notifications are in Notification Center only — banner display is
   blocked by macOS settings."

## What this spike does NOT cover

- Behavior post-notarization. We expect things only get **more**
  permissive once we have a real Developer ID; needs re-test at publish
  time.
- Whether the system permission prompt ever appears in a typical
  Mac-user-clicking-around scenario (only tested headlessly, where
  prompts never appear). Will verify during Phase B onboarding work.
- Focus mode interaction. Untested; assumption is that Focus respects
  the per-app permission as it does for signed apps.

## When to re-run

Re-run if:
- macOS major version changes.
- Apple deprecates `UNUserNotificationCenter` for unsigned apps (which
  has been rumored periodically — would force us to notarize earlier).
- A user reports "Supervisor's notifications stopped working" — first
  thing to verify is current auth status from
  `getNotificationSettings`.

## Artifacts

- `notify_spike.swift` — source
- `build_notify_app.sh` — bundle build script (gitignored output)
- `notify_spike.log` ... `notify_spike4.log` — four progressive runs
  showing the configuration changes (kept for reference)
