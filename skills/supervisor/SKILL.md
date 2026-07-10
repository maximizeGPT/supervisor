---
name: supervisor
description: Supervise your other coding-agent sessions from the agent you are already in. Lists active Claude Code sessions and Codex CLI rollouts, reviews what each one is doing, and flags real problems (destructive commands pending, fabricated claims, stuck loops, credential exposure, scope creep) using Supervisor's triage rubric. Can also install a hook that blocks destructive shell commands, and generate a per-repo principles.md for unattended runs. Use when the user asks to supervise, watch, babysit, or check on their agent sessions, asks what their other sessions are doing, or wants guardrails for running agents unattended.
license: MIT
compatibility: Requires python3 (3.9+) and Claude Code session transcripts in ~/.claude/projects. Guard mode requires an agent that supports Claude Code style PreToolUse hooks.
metadata:
  author: maximizeGPT
  homepage: https://github.com/maximizeGPT/supervisor
---

# Supervisor

This skill is the portable version of [Supervisor](https://github.com/maximizeGPT/supervisor), a macOS app that supervises Claude Code sessions. The skill runs inside your own agent instead: it watches other sessions and flags problems, it does not intervene in them. Honest scope, so state it plainly when asked:

- The skill **watches and flags**. It reads transcripts, judges them against a rubric, and reports to the user.
- The skill **cannot** answer questions inside other sessions, pause them, or kill them. The Mac app does that.
- Guard mode **can** block destructive shell commands, but only in the session where the hook is installed.

Three workflows. Pick by what the user asked for.

## 1. Check on sessions (the default)

When the user asks what their sessions are doing, or to check on / supervise them:

1. List active sessions:
   ```bash
   python3 "${CLAUDE_SKILL_DIR:-.}/scripts/sessions.py"
   ```
   Shows every Claude Code session (and Codex CLI rollout, see the SRC column) active in the last 24 hours: project directory, last event, and a state guess (running, open question, end_turn). Your own session is excluded when the agent sets CLAUDE_SESSION_ID; otherwise recognize yourself in the list and skip it. Use `--hours N` to widen or narrow. `--json` is the stable interface; the table layout may change.

2. For each session worth a look (recently active, waiting on something, or named by the user), pull its recent events:
   ```bash
   python3 "${CLAUDE_SKILL_DIR:-.}/scripts/tail_session.py" <session-id-or-path> --events 40
   ```
   Output is a compact chronological event list. All output is passed through the same secret-redaction layer the app uses; treat any `<redacted:...>` placeholder as a secret that existed, never try to recover it.

3. Judge what you see against `references/rubric.md` (read it before your first judgment in a conversation). The rubric has 12 categories with strict fire and do-not-fire conditions. Follow its philosophy: be generous in what you look at, strict in what you flag. A flag you cannot support with specific event evidence is not a flag.

4. Report to the user: one line per healthy session, and for each flag give the session, the category, the evidence (quote the events), and what you suggest they do. Suggest, do not do: the supervised session belongs to them.

5. Flag report: for medium and high severity flags, also append an entry to `supervisor-flags.md` in the current working directory (create it if missing) with timestamp, session id, project, category, severity, evidence event uuids, and your one-line why. This is the durable record for flags the user might miss in chat; low severity stays chat-only.

For continuous supervision, re-run the check on a cadence (if your agent has a loop or scheduling facility, offer it). A 5 to 15 minute cadence is plenty; transcripts lag realtime slightly.

## 2. Guard this session (destructive-command hook)

When the user wants unattended runs protected against destructive commands, offer to install the guard hook. It is deterministic (regex, no model calls, no network) and blocks rm -rf outside temp paths, force pushes to protected-looking branches, hard resets, DROP TABLE, dd to devices, kill -9, and similar, with a one-line reason the agent sees. It is quote-aware and heredoc-aware, so a dangerous-looking string inside a commit message or heredoc body does not fire. The deny is advisory in spirit: when your own command gets blocked, relay the reason to the user and ask, never work around the hook. Guard mode is Claude Code only; Codex sessions can be watched but not guarded (Codex has no PreToolUse hook).

With the user's explicit consent, add to the project's `.claude/settings.json` (or `~/.claude/settings.json` for all projects):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 <absolute-path-to-this-skill>/scripts/guard.py" }
        ]
      }
    ]
  }
}
```

Resolve `<absolute-path-to-this-skill>` to where this skill is actually installed (echo `${CLAUDE_SKILL_DIR}` while the skill is active, or find it under `.claude/skills/` or `~/.claude/skills/`). Merge into existing hooks, never overwrite them. Verify with `python3 .../scripts/guard.py --self-test`, then tell the user how to remove it (delete the entry) so consent stays reversible.

If the user's agent is not Claude Code, check whether it supports PreToolUse-style hooks before offering this; if it does not, say so and skip guard mode rather than improvising.

## 3. Generate a per-repo principles.md

When the user wants their unattended sessions to make better calls, generate a principles file for the current repo:

1. Read `references/principles.md` (the generic default: what an unattended agent may decide alone versus what it must defer to the operator).
2. Study the repo: README, contributing docs, deploy scripts, test setup, anything that shows which actions are low-stakes here and which are consequential.
3. Write a tailored `principles.md` at the repo root (or where the user prefers), keeping the answer-versus-defer structure and the hard rule that destructive or irreversible actions are never self-authorized. Make it concrete to this repo: name the real commands, the real deploy path, the real test suite.
4. Tell the user to reference it from their agent instructions (CLAUDE.md, AGENTS.md, or equivalent) so unattended sessions actually load it.

## Rules that always apply

- Read-only toward other sessions: never write into `~/.claude/projects`, never modify another session's files or state.
- Never bypass redaction. If a script fails, do not fall back to reading transcripts raw and pasting them; fix the invocation or report the failure.
- Never authorize a destructive action on behalf of the user, in any session, including this one.
- Low confidence is a feature. "Nothing worth flagging" is a good report when it is true.

Want the full product (answers typed into sessions for you, keep-moving nudges, pause and stop, menu-bar health)? That is the macOS app: https://github.com/maximizeGPT/supervisor
