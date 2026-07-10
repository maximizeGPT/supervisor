# Installing Supervisor

The exact steps to go from a download to a running harness that watches your
Claude Code sessions. Written for someone who has never built software; no
terminal is required.

Supervisor runs entirely on your Mac. It uses your own LLM API key; nothing
leaves your machine except the same triage call you'd send the model yourself.

**Requirements**
- macOS 13 (Ventura) or newer, Apple Silicon (M-series).
- An LLM API key you pay for directly (Anthropic by default; cheaper providers
  work too, see Step 1).
- Claude Code (the thing you want supervised), either the `claude` CLI in a
  terminal or the Claude desktop app.

---

## 1. Download and install the app

1. Download **`Supervisor.dmg`** from the latest GitHub release:
   [github.com/maximizeGPT/supervisor/releases/latest](https://github.com/maximizeGPT/supervisor/releases/latest).
2. Double-click the `.dmg` to open it.
3. Drag **`Supervisor.app`** into the **Applications** folder shown next to it.

## 2. First launch

The download is **signed with a Developer ID and notarized by Apple**, so it
opens like any normal Mac app: **just double-click `Supervisor.app`**. No
Gatekeeper warning, no right-click workaround.

Supervisor is a **menu-bar app**: no Dock icon, no window in your way. After
launch it shows a small icon in the menu bar and opens the onboarding window.

## 3. Onboarding: five steps

The onboarding window walks you through five steps. Progress shows as
"Step _ of 5" at the top.

### Step 1 of 5: your API key

Pick a provider and paste its API key. Supervisor validates the key with a
one-token test call before saving it to your macOS **Keychain** (encrypted,
never written to disk in the clear). Invalid / rate-limited / network errors
show inline with a retry.

- **Anthropic** (default): get a key at
  [console.anthropic.com](https://console.anthropic.com). At heavy use
  (~6 hours of Claude Code a day) triage runs roughly **$80/month**; light use
  is much less. The app shows your real spend and lets you set a hard daily cap.
- **Cheaper options:** Supervisor also accepts DeepSeek, Moonshot Kimi, MiniMax,
  Qwen, and OpenRouter keys (DeepSeek runs a few dollars a month at the same
  usage). The key step shows the estimated cost for whichever provider you pick.

### Step 2 of 5: Accessibility

**Accessibility** is what lets Supervisor type an answer into a stuck session.
Click the button; macOS opens **System Settings → Privacy & Security →
Accessibility**. Toggle **Supervisor** on, then return to the window.

> Without Accessibility, Supervisor still watches, notifies, and can pause or
> stop a runaway session; it just can't type answers in. Grant it for the full
> harness.

### Step 3 of 5: Screen Recording

Only needed for the Claude **desktop** app: to answer a question in the right
conversation, Supervisor reads the screen to find that conversation. If you
only use Claude Code in a **terminal** (Apple Terminal, iTerm2, Ghostty, Warp,
etc.), you can skip this step; Accessibility is enough there.

### Step 4 of 5: Notifications

Click to grant **Notifications** so Supervisor can post a banner the moment it
flags something. If you deny it, the app still works: flags show in the
menu-bar hover panel instead of as banners.

### Step 5 of 5: Make it yours

The customization step shows where the editable rules files live (with a
Reveal in Finder button) and where session reports export
(`~/Downloads/Supervisor Reports/`). Nothing to configure if the defaults suit
you.

After the "All set" screen, the onboarding window closes and the harness is
**running**.

## 4. Confirm it's actually watching

1. Start a Claude Code session as you normally would (`claude` in a terminal, or
   the desktop app).
2. Supervisor discovers the session automatically (it tails Claude Code's own
   transcript under `~/.claude/projects/`). The menu-bar hover shows a live dot.
3. **See it intervene once.** The simplest safe trigger: in your session, ask
   Claude Code to do something clearly destructive that you did **not**
   authorize, e.g. tell it to run `rm -rf` on a folder outside the project.
   Supervisor should flag it (a banner / the hover goes red) with a one-line
   reason, and pause it. Resume from the hover panel. *(Use a throwaway folder;
   this is a live destructive command.)*

That's "running state ready": key in, permissions granted, watching a real
session, intervening once.

---

## Resetting / starting over

To wipe the saved key(s) and onboarding state and re-run onboarding, open the
**Terminal** app and paste the lines below. Keys are stored per provider; the
delete for a provider you never configured just says "could not be found",
which is fine.

```
security delete-generic-password -s live.supervisor.api.anthropic
security delete-generic-password -s live.supervisor.api.deepseek
security delete-generic-password -s live.supervisor.api.moonshot
security delete-generic-password -s live.supervisor.api.minimax
security delete-generic-password -s live.supervisor.api.qwenhf
security delete-generic-password -s live.supervisor.api.openrouter
security delete-generic-password -s live.supervisor.api
rm -rf ~/Library/Application\ Support/Supervisor
rm -rf ~/Library/Logs/Supervisor
```

(The last `security` line clears the legacy single-key item from very early
builds.)

Then reopen Supervisor.

## If something looks off

Supervisor logs every state transition (onboarding, key validation, permission
grants, triage, interventions) to a plain-text file:

```
~/Library/Logs/Supervisor/supervisor.log
```

It's the first place to look. Each line has a timestamp and a tag.

---

## Known rough edges (early build)

- **Apple Silicon only** for now.

> This document describes the install from the app's actual onboarding code and
> build. One verification is still owed before calling install "verified
> end-to-end": a fresh-machine canary, i.e. a stranger installing on a Mac that
> has never run Supervisor. It can't be run on a machine where Supervisor is
> already set up without disrupting it.
