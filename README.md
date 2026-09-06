<div align="center">

<img src="./branding/supervisor-wordmark.svg" alt="Supervisor" width="300" />

<h3>Auto mode takes you out of the loop.<br/>Supervisor takes your place.</h3>

<p>A native macOS app that supervises your <a href="https://www.anthropic.com/claude-code">Claude Code</a> and Codex sessions, so you can step away without them stalling or going off the rails.</p>

<p>
<a href="https://github.com/maximizeGPT/supervisor/releases/latest/download/Supervisor.dmg"><img src="https://img.shields.io/badge/Download-macOS%2013%2B-3a7d44?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" /></a>
</p>

<p>
<a href="https://github.com/maximizeGPT/supervisor/actions/workflows/ci.yml"><img src="https://github.com/maximizeGPT/supervisor/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
<a href="https://github.com/maximizeGPT/supervisor/releases"><img src="https://img.shields.io/github/v/release/maximizeGPT/supervisor?include_prereleases&sort=semver" alt="Release" /></a>
<a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
<img src="https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey" alt="Platform: macOS 13+" />
</p>

<p>
<a href="https://supervisor-site-taupe.vercel.app">Website</a> &nbsp;·&nbsp; <a href="https://supervisor-site-taupe.vercel.app">60-second demo</a> &nbsp;·&nbsp; <a href="#use-it-as-a-skill-no-mac-needed">Use it as a skill</a>
</p>

</div>

---

Running a coding agent unattended is great until it stops to ask a question you are not there to answer, or does something you did not want. So you end up watching the terminal instead of doing your work.

Supervisor watches each session and acts in your place:

- **Answers the questions.** When Claude Code stops to ask, Supervisor reads the repo and answers in the session, in plain language. You stop being the bottleneck.
- **Keeps it moving.** It nudges an idle session forward toward its objective instead of letting it stall the moment you step away.
- **Stops the dangerous stuff.** When an action looks destructive, it flags it and tells you why, in one sentence you can actually read, and pauses the session when it can do so safely.

Everything runs on your Mac, on your own API key. Nothing leaves your machine except the same model calls you would make yourself, plus the escalation message described in [Remote escalation delivery](#remote-escalation-delivery) if you turn that on yourself. It ships off, and its default message quotes nothing from your session.

**New in 0.4.0:** escalations reach your phone. Discord, Slack or ntfy, off by default, and the status-bar companion pages you when the app itself crashes or hangs, because the process that most needs reporting is the one that cannot report itself. Model spend is now metered, traced hourly, and capped at $5/day by default: the idle path used to re-buy the same verdict every 60 seconds, about $11/day against sessions that had been silent for hours, and it now settles onto a 30-minute rung for well under $1. From 0.3.x: launch reliability, an opt-in Second Brain, supervised Codex sessions, a second-opinion panel across other models, context health monitoring, and the portable Agent Skill below.

## Install

### Download the app (recommended)

1. **[Download `Supervisor.dmg`](https://github.com/maximizeGPT/supervisor/releases/latest/download/Supervisor.dmg)**. It is signed and notarized by Apple, so it opens with a plain double-click, no Gatekeeper warning.
2. Drag `Supervisor.app` into Applications and launch it.
3. Onboarding walks you through the rest: paste an API key, grant Accessibility, allow Notifications.

Requires macOS 13 (Ventura) or later. Full first-run guide: **[INSTALL.md](./INSTALL.md)**.

### Use it as a skill (no Mac needed)

The portable subset of Supervisor ships as an [Agent Skill](https://agentskills.io) at [`skills/supervisor/`](./skills/supervisor/). It runs inside the agent you already use (Claude Code, Codex, Cursor, opencode, Amp, Gemini CLI, or anything that supports Agent Skills) on any OS with `python3`:

```bash
npx skills add maximizeGPT/supervisor
```

The skill watches your other sessions and flags real problems against Supervisor's triage rubric, blocks destructive shell commands with an optional hook, and generates a per-repo `principles.md` for unattended runs. It watches and flags; answering questions inside sessions, keeping them moving, and pause and stop are app territory.

### Build from source

```bash
git clone https://github.com/maximizeGPT/supervisor.git
cd supervisor
./Scripts/build-app.sh debug
open build/Supervisor.app
```

## How it works

Claude Code and Codex write a transcript of every session. Supervisor tails it as the agent works, runs a fast LLM triage against a small structured rubric on each turn, and acts only when something needs you:

- **Answer** a pending question by typing the response into the session.
- **Keep moving** by nudging an idle session forward toward its objective.
- **Flag, pause, or stop** a destructive command, with a plain-language reason.

Four intervention types, ordered by escalation. `notify` is the floor: every stronger intervention checks that it can act safely first, and degrades to a notification when it cannot.

| Type   | What it does                                                             | Degrades to notify when                                                                                                  |
|--------|--------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| notify | macOS banner notification plus a hover flag. Always available.           | Never. This is the fallback for everything else.                                                                           |
| inject | Types an answer or corrective text into the session's composer.          | The targeter is not confident it found the right conversation, the text does not land as a turn, or a human is actively typing. |
| pause  | Sends `SIGSTOP` to the agent CLI process so it freezes in place.         | The resolved target is the shared desktop app (never signaled), or the session cannot be resolved to a single process.     |
| kill   | Sends `SIGTERM` to the agent CLI process so it shuts down cleanly.       | Same guards as pause.                                                                                                       |

> [!NOTE]
> Interventions are honest and best-effort by design: you always get told; you do not always get an automatic save. Triage also reads the transcript after a tool call is recorded, so a very fast command can finish before its flag arrives. Every degrade is logged with a reason, and the hover panel shows what actually happened.

Three things make it trustworthy:

- **Local and private.** Everything runs on your Mac. A redaction layer strips secrets (API keys, tokens, credentials) before any model call, and refuses to send a request without it. Fail-closed by design. The one optional exception is the escalation message described in [Remote escalation delivery](#remote-escalation-delivery), which ships off only if you turn that on yourself.
- **Bring your own key.** No server, no subscription, no per-seat pricing. Use the key you already have: Anthropic, DeepSeek, Moonshot Kimi, MiniMax, Qwen, or OpenRouter. Your usage is billed to you, at cost.
- **Honest health.** A companion menu-bar process reports green, amber, or red, so you always know whether Supervisor is actually watching.

The architecture at a glance: [docs/architecture.svg](./docs/architecture.svg).

## Remote escalation delivery

The whole point is the moment you step away from the Mac. Until now the escalation path ended at a macOS banner on a screen you were not looking at, so a paused session sat there until you came back to find it.

Remote delivery posts an escalation to a webhook you supply. Discord, Slack, and [ntfy](https://ntfy.sh) endpoints are detected from the URL and get their native payload shape; anything else receives a flat JSON envelope. For a self-hosted ntfy server, set `remote_notify.format: ntfy` (or pick ntfy in the panel) since the host alone says nothing.

**The zero-infrastructure default is ntfy.** No account, no server, about 30 seconds: install the ntfy app on your phone, subscribe to a topic name only you would guess (the topic name is the whole secret, so make it long and random), and your webhook URL is `https://ntfy.sh/your-topic-name`. Discord and Slack work exactly as well if you already live there.

**The easiest setup is in the app.** Open the hover panel, expand Controls, and use the Remote escalation row: paste the webhook URL, flip delivery on, pick the detail level, and press Send test. A green result there means the real channel delivered. The CLI path below does the same thing and stays supported:

```bash
# 1. Store the URL. Env form only: the URL is a bearer credential, and argv
#    leaks it into shell history and into Supervisor's own observation of
#    the command. read -s takes the pasted URL without echoing it and
#    without touching disk. Must be https.
read -rs SUPERVISOR_REMOTE_NOTIFY_SECRET_URL && export SUPERVISOR_REMOTE_NOTIFY_SECRET_URL
swift run SupervisorDevTools remote-notify-url-from-env
unset SUPERVISOR_REMOTE_NOTIFY_SECRET_URL

# 2. Turn it on in ~/Library/Application Support/Supervisor/config.yaml
#    (watched live, no relaunch needed):
#      remote_notify:
#        enabled: true
#        detail: minimal

# 3. Send one synthetic escalation and confirm it arrives.
swift run SupervisorDevTools remote-notify-test
```

The first Supervisor launch after storing the URL may show a macOS Keychain permission prompt; click Always Allow so later launches read the webhook without asking again.

**What gets sent.** At `detail: minimal`, the default, the message carries Supervisor's own verdict and nothing quoted from the session: the rubric category, the severity, what Supervisor did, an 8-character session prefix, and the working directory's basename. No command text, no assistant reasoning, no absolute paths. `detail: full` adds the triggering command and the plain-language reasoning, both passed through the same redaction layer the model calls use.

**When it fires.** Only events where the session is blocked on you, plus high-severity flags: pause, kill, a medium-confidence dispatch waiting on your approval, a low-confidence dispatch waiting on your direction, an answer Supervisor could not type for you, a missing Screen Recording permission, and any high-severity notify. Work Supervisor handled by itself stays local. Repeats of the same session, outcome and category collapse to one message per minute, so a stuck loop pages you once.

**The honest caveat.** You get pinged. You cannot answer from your phone, so a blocked session still says "go to your Mac." Delivery is one-way.

## Pricing

Free and open source. The only thing you pay for is the model usage you would have paid for anyway, billed to you directly and never to us. At heavy use (~6 hours of Claude Code a day) triage runs about $80/month on Anthropic and a few dollars a month on DeepSeek. The in-app cost view shows your real spend.

**There is a hard daily cap, and it is on by default at $5.00.** When today's recorded spend reaches it, Supervisor refuses model calls before they leave the machine, pauses triage, and pages you that it has stopped watching. You do not have to configure anything to get this. The cap is a runaway backstop, not a budget: heavy Anthropic use runs about $2.67/day, so a normal day never approaches it. To raise it, lower it, or turn it off, edit `~/Library/Application Support/Supervisor/config.yaml`, which Supervisor writes on first launch with every default commented out (read live, no relaunch):

```yaml
cost:
  daily_cap_usd: 10.00   # your ceiling for a day of model spend
  # daily_cap_usd: 0     # 0 removes the cap entirely. Nothing then bounds spend.
```

A value that does not parse is treated as a typo, not as "no cap": the $5.00 default stays in force. If Supervisor cannot read today's spend at all, it refuses the spend-heavy calls until the store answers again and tells you the spend record is unreadable. It does not report that as a cap hit, because no spend was measured.

## Contributing

```bash
swift build      # compile
swift test       # run the test suite
```

Issues are welcome. A useful one includes the last ~50 lines of `~/Library/Logs/Supervisor/supervisor.log`, your macOS version (`sw_vers -productVersion`), and what the agent was doing when the surprise happened. The trace log is local-only and is not redacted, so scrub anything sensitive before pasting.

## License

[MIT](./LICENSE) &copy; Mohammed Wasif
