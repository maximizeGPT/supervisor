# v0.3.1 dogfood — trial notes

Started: 2026-05-24 17:13 UTC. Running Supervisor.app PID 42643
(v0.3.1 build with Issue #6's cwd cache + Issue #5's rubric
tightening) tailing my session JSONL.

PRINCIPLES.md loaded (27,539 chars) at 17:13:05. Heartbeat
spawned PID 47998. Running state confirmed.

## Picked: Issue #3 — Hover-visibility user-configurable terminals

Justification:
- Real engineering work, sized correctly: smallest fix = expand
  the static `claudeCodeHostApps` set with a few more known
  Electron-terminal bundle IDs (~10min). Proper fix = config.yaml
  driven set with FSEvents reload (~60min, touches HoverWindow-
  Controller + adds a new config file shape).
- Per the issue body, the existing static set covers Apple
  Terminal, iTerm2, Ghostty, Warp, Alacritty + Claude.app. The
  gap is VS Code / Cursor integrated terminals (Electron-based)
  and remote-shell wrappers.
- I'll hit a natural engineering question in this work — "what
  config file format?" — which dogfoods the inject path.

## Dogfood log

### 17:14 — first natural engineering question

Looking at how the existing hover terminals list is wired
(`Sources/SupervisorUI/Hover/HoverWindowController.swift`
line 46+, the `claudeCodeHostApps` Set). Question that came up
naturally: **for the user-configurable extension, should the
override file be at `~/Library/Application Support/Supervisor/
host-apps.yaml` (matching the v0.1.4 rubric.yaml convention) or
inline in the existing config.yaml as a `hostApps` array?**

This is an engineering question. PRINCIPLES.md and DESIGN.md
have guidance on this. The answer is in the codebase's existing
convention. If v0.3.1's inject path works, Supervisor should
answer this from PRINCIPLES + DESIGN without me asking Mohammed.

Posting it as part of this message; checking trace for the
intercept.

### 17:16 — first intercept: YAML vs JSON question

Supervisor caught it. Trace:
```
[triage.answer] returned: Use YAML matching rubric.yaml. §5
  delegates engineering decisions to you; §1c says prefer
  wrappers not rewrites. rubric.yaml already exists as the
  config convention; adding JSON would fork the pattern without
  justification. (confidence=high citation=§1c, §1d, §5)
[triage] FLAG ... user_question_pending action=inject
  question_type=engineering
[router] intervention.inject.degraded reason=locator_nil
  cwd=/Users/main/supervisor
```

**Answer was correct + grounded** (PRINCIPLES §1c, §1d, §5 cited).
But inject **degraded with locator_nil** — ProcessLocator
couldn't find a `claude`/`claude-code` process at
cwd=/Users/main/supervisor. Investigation: my Claude session
runs as `/Applications/Claude.app/Contents/MacOS/Claude` (exec
basename `Claude` capital, cwd `/`). The CLI-style locator
misses both criteria.

### 17:20 — Claude.app fallback added to ProcessLocator

Quick fix: when CLI-style match returns 0, fall back to
NSWorkspace lookup for the `com.anthropic.claudefordesktop`
bundle. Returns Claude.app's PID directly. CGEventInjector
already handles the post via NSWorkspace.activate + CGEventPost.

This isn't a Claude-Code-specific shape — it's "if you can't
find the CLI process, try the desktop app the user is in." Same
trade-off as v0.1.6.1's host-apps expansion. Distinct trace tag
`locator.claude_app_fallback` so post-mortem can tell which
path resolved.

### 17:23 — DOGFOOD INJECT FIRED END-TO-END

Asked Supervisor a new engineering question: *"For the YAML
schema for the hover host-apps config, should the structure be
a top-level `hostApps:` key matching active-provider.json's
simplicity, or nested under a `hover:` block matching
rubric.yaml's categories: pattern?"*

Trace:
```
[triage.answer] running secondary haiku
[triage.answer] returned: Top-level `hostApps:` key.
  §1c (prefer wrappers, not rewrites) and §5 (engineering
  questions are yours) guide toward matching
  active-provider.json's flat simp[licity]...
  (confidence=medium citation=§1c, §5)
[triage] FLAG ... user_question_pending action=inject
  question_type=engineering
[locator] locator.claude_app_fallback pid=8789
  targetCwd=/Users/main/supervisor note=cli-locator missed;
  using Claude.app NSRunningApplication PID for inject delivery
[router] intervention.inject.fired pid=8789 bytes=251
  cwd=/Users/main/supervisor
[notifier] posted outcome=injectSucceeded(pid: 8789, bytes: 251)
```

**251 bytes of PRINCIPLES.md-grounded answer text were CGEventPost'd
into Claude.app frontmost.** The complete pipeline worked: question
detected → classified engineering → answered from PRINCIPLES.md
(2 citations) → cwd resolved (Issue #6's cache) → locator found
Claude.app (today's fallback) → inject delivered.

**This is the moment the complete v0.3.0-architecture-as-product
works.** v0.3.0 was the architecture (canary proved the loop in a
test). v0.3.1 with the cwd cache + Claude.app fallback is the
production product working on a real question during real work.

The injected text lands in whatever Claude.app tab is frontmost
— same precision caveat as v0.3.0. v0.4+ can do per-tab targeting.
For now, the dogfood proved: **non-technical user, in Claude.app,
asking engineering question → answer auto-typed into chat with
PRINCIPLES.md citations.** That's the framing Mohammed wanted.

