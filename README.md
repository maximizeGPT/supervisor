<div align="center">

<img src="./branding/supervisor-wordmark.svg" alt="Supervisor" width="300" />

<h3>Auto mode takes you out of the loop.<br/>Supervisor takes your place.</h3>

<p>A native macOS app that supervises your <a href="https://www.anthropic.com/claude-code">Claude Code</a> sessions, so you can step away without them stalling or going off the rails.</p>

<p>
<a href="https://github.com/maximizeGPT/supervisor/releases/latest/download/Supervisor.dmg"><img src="https://img.shields.io/badge/Download-macOS%2013%2B-3a7d44?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" /></a>
</p>

<p>
<a href="https://github.com/maximizeGPT/supervisor/actions/workflows/ci.yml"><img src="https://github.com/maximizeGPT/supervisor/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
<a href="https://github.com/maximizeGPT/supervisor/releases"><img src="https://img.shields.io/github/v/release/maximizeGPT/supervisor?include_prereleases&sort=semver" alt="Release" /></a>
<a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
<img src="https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey" alt="Platform: macOS 13+" />
</p>

</div>

---

Running Claude Code unattended is great until it stops to ask a question you are not there to answer, or does something you did not want. So you end up watching the terminal instead of doing your work.

Supervisor watches each session and acts in your place:

- **Answers the questions.** When Claude Code stops to ask, Supervisor reads the repo and answers in the session, in plain language. You stop being the bottleneck.
- **Keeps it moving.** It keeps a session going on its own instead of stalling the moment you step away.
- **Stops the dangerous stuff.** When an action looks destructive, it pauses and tells you why, in one sentence you can actually read.

Everything runs on your Mac, on your own API key. Nothing leaves your machine except the same model calls you would make yourself.

**[Watch the 60-second demo &rarr;](https://supervisor-site-taupe.vercel.app)**

## Install

### Download (recommended)

1. **[Download `Supervisor.dmg`](https://github.com/maximizeGPT/supervisor/releases/latest/download/Supervisor.dmg)**. It is notarized by Apple, so it opens with no Gatekeeper warning.
2. Open it and drag **both** `Supervisor.app` and `SupervisorStatusBar.app` into Applications.
3. Launch `Supervisor.app`. It walks you through a three-step setup: paste your API key, grant Accessibility, allow Notifications.

Requires macOS 13 (Ventura) or later. Full first-run guide: **[INSTALL.md](./INSTALL.md)**.

### Build from source

```bash
git clone https://github.com/maximizeGPT/supervisor.git
cd supervisor
./Scripts/build-app.sh debug
open build/Supervisor.app
```

## How it works

Claude Code writes a JSONL transcript of every session. Supervisor tails it as the agent works, runs a fast LLM triage against a small structured rubric on each turn, and acts only when something needs you:

- **Answer** a pending question by typing the response into the session.
- **Keep moving** by nudging an idle session forward toward its objective.
- **Pause or stop** a destructive command before it lands.

Three things make it trustworthy:

- **Local and private.** Everything runs on your Mac. A redaction layer strips secrets (API keys, tokens, credentials) before any model call, and refuses to send a request without it. Fail-closed by design.
- **Bring your own key.** No server, no subscription, no per-seat pricing. Use the key you already have (Anthropic, DeepSeek, and more). Your usage is billed to you, at cost.
- **Honest health.** A companion menu-bar process reports green, amber, or red, so you always know whether Supervisor is actually watching.

The full architecture is in **[DESIGN.md](./DESIGN.md)**.

## Pricing

Free and open source. The only thing you pay for is the model usage you would have paid for anyway, billed to you directly and never to us. The in-app cost view shows your real spend, and you can set a hard daily cap.

## Contributing

```bash
swift build      # compile
swift test       # run the test suite
```

Issues are welcome. A useful one includes the last ~50 lines of `~/Library/Logs/Supervisor/supervisor.log`, your macOS version (`sw_vers -productVersion`), and what Claude Code was doing when the surprise happened. The trace log is local-only and is not redacted, so scrub anything sensitive before pasting.

## License

[MIT](./LICENSE) &copy; Mohammed Wasif
