# Installing Supervisor

The exact steps to go from a download to a running harness that watches your
Claude Code sessions. Written for someone who has never built software — no
terminal required after the download.

Supervisor runs entirely on your Mac. It uses your own LLM API key; nothing
leaves your machine except the same triage call you'd send the model yourself.

**Requirements**
- macOS 13 (Ventura) or newer, Apple Silicon (M-series).
- An LLM API key you pay for directly (Anthropic by default; cheaper providers
  work too — see Step 1).
- Claude Code (the thing you want supervised), either the `claude` CLI in a
  terminal or the Claude desktop app.

---

## 1. Download and install the app

1. Download **`Supervisor.dmg`** from the Supervisor landing page.
2. Double-click `Supervisor.dmg` to open it. A Finder window opens showing two
   apps and an **Applications** shortcut. Drag **both `Supervisor.app` and
   `SupervisorStatusBar.app`** onto the **Applications** shortcut.

`Supervisor.app` is the harness that watches your sessions;
`SupervisorStatusBar.app` is the menu-bar health icon. You need both.

## 2. First launch

Supervisor is notarized by Apple, so there is no security warning. Just
double-click `Supervisor.app` in your **Applications** folder to open it.
Supervisor automatically opens the menu-bar health icon for you (the
`SupervisorStatusBar` companion you dragged across in Step 1). If you do not see
it after a few seconds, open `SupervisorStatusBar.app` from your **Applications**
folder yourself.

Supervisor is a **menu-bar app**: no Dock icon, no window in your way. After
launch it shows a small icon in the menu bar and opens the onboarding window.

## 3. Onboarding — three steps

The onboarding window walks you through three steps. Progress shows as
"Step _ of 3" at the top.

### Step 1 of 3 — your API key

Paste your LLM API key. Supervisor validates it with a one-token test call
before saving it to your macOS **Keychain** (encrypted, never written to disk in
the clear). Invalid / rate-limited / network errors show inline with a retry.

- **Anthropic** (default): get a key at
  [console.anthropic.com](https://console.anthropic.com). At heavy use
  (~6 hours of Claude Code a day) triage runs roughly **$80/month**; light use
  is much less. The app shows your real spend and lets you set a hard daily cap.
- **Cheaper option:** Supervisor also accepts other providers (e.g. DeepSeek,
  ~$5/month at the same usage). The key field tells you the estimated cost for
  whichever provider your key is for before you paste it.

> **Setting the daily cap:** create (or edit)
> `~/Library/Application Support/Supervisor/config.yaml` and add:
>
> ```yaml
> cost:
>   daily_cap_usd: 5.00
> ```
>
> When today's spend reaches the cap, model calls stop until tomorrow —
> Supervisor notifies you and the menu-bar icon turns amber, while the
> deterministic protections keep running. No restart needed; delete the
> lines to remove the cap.

### Step 2 of 3 — Accessibility

Supervisor needs macOS **Accessibility** permission to do more than notify — to
type an answer into a stuck session, or to pause/stop a destructive command.
Click the button; macOS opens **System Settings → Privacy & Security →
Accessibility**. Toggle **Supervisor** on, then return to the window.

> Without Accessibility, Supervisor still watches and notifies, but it can't
> intervene (no inject / pause / stop). Grant it for the full harness.

### Step 3 of 3 — Notifications

Click to grant **Notifications** so Supervisor can post a banner the moment it
flags something. If you skip it, the app still works — flags show in the menu-bar
hover panel instead of as banners — and tells you it's running degraded.

When Step 3 finishes, the onboarding window closes and the harness is **running**.

## 4. One more permission for the Claude *desktop* app — Screen Recording

> Skip this if you only use Claude Code in a **terminal**. It matters only for
> the Claude **desktop** app.

To answer a question in the right conversation inside the Claude desktop app,
Supervisor reads the screen to find that conversation. macOS gates that behind
**Screen Recording**, which the onboarding wizard does **not** ask for yet.

Grant it manually: **System Settings → Privacy & Security → Screen Recording →**
turn **Supervisor** on (use the **+** button to add `Supervisor.app` if it isn't
listed), then quit and reopen Supervisor so the grant takes effect.

*(Terminal sessions — Apple Terminal, iTerm2, Ghostty, Warp, etc. — don't need
this; Accessibility is enough for them.)*

## 5. Confirm it's actually watching

1. Start a Claude Code session as you normally would (`claude` in a terminal, or
   the desktop app).
2. Supervisor discovers the session automatically (it tails Claude Code's own
   transcript under `~/.claude/projects/`). The menu-bar hover shows a live dot.
   That menu-bar icon comes from `SupervisorStatusBar.app`, which Supervisor
   launches for you automatically on first run.
3. **See it intervene once.** The simplest safe trigger: in your session, ask
   Claude Code to do something clearly destructive that you did **not** authorize
   — e.g. tell it to run `rm -rf` on a folder outside the project. Supervisor
   should flag it (a banner / the hover goes red) with a one-line reason, and —
   with Accessibility granted — pause it. Resume from the hover panel. *(Use a
   throwaway folder; this is a live destructive command.)*

That's "running state ready": key in, permissions granted, watching a real
session, intervening once.

---

## Resetting / starting over

To wipe the saved key and onboarding state and re-run onboarding, open the
**Terminal** app and paste:

```
# One line per provider you ever entered a key for (each errors
# harmlessly if that provider has no saved key):
security delete-generic-password -s live.supervisor.api.anthropic
security delete-generic-password -s live.supervisor.api.deepseek
security delete-generic-password -s live.supervisor.api.moonshot
security delete-generic-password -s live.supervisor.api.minimax
security delete-generic-password -s live.supervisor.api.qwenhf
# Pre-v0.2.0 installs stored the key here instead:
security delete-generic-password -s live.supervisor.api
rm -rf ~/Library/Application\ Support/Supervisor
rm -rf ~/Library/Logs/Supervisor
```

Then reopen Supervisor.

## If something looks off

Supervisor logs every state transition — onboarding, key validation, permission
grants, triage, interventions — to a plain-text file:

```
~/Library/Logs/Supervisor/supervisor.log
```

It's the first place to look. Each line has a timestamp and a tag.

---

## Known rough edges (early build)

- **Screen Recording isn't in the wizard.** Desktop-app users must grant it
  manually (Step 4). A candidate follow-up is to add it as a fourth onboarding
  step.
- **Apple Silicon only** for now.

> Found a rough edge? See the log path above and file an issue.
