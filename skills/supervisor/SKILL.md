---
name: supervisor
description: Supervise your other coding-agent sessions from the agent you are already in. Lists active Claude Code sessions and Codex CLI rollouts, reviews what each one is doing, and flags real problems (destructive commands pending, fabricated claims, stuck loops, credential exposure, scope creep) using Supervisor's triage rubric. Can also install a hook that blocks destructive shell commands, generate a per-repo principles.md for unattended runs, and build a second brain, a plain-Markdown project memory distilled from the user's own sessions that improves each iteration. Use when the user asks to supervise, watch, babysit, or check on their agent sessions, asks what their other sessions are doing, wants guardrails for running agents unattended, or wants the project to remember decisions, corrections, and preferences across sessions.
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

Four workflows. Pick by what the user asked for.

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

## 4. Build a second brain (iterative memory)

When the user wants the project to remember what their sessions taught them, run the second-brain loop. The motivation is what Nadella called the Reverse Information Paradox (July 2026): users pay for AI twice, in money and in the proprietary knowledge they reveal in prompts and corrections, and that second payment evaporates when the session ends. The second brain captures it into plain Markdown that lives in the user's own repo, readable by any model or agent, and measured every iteration. Honest scope, same shape as the rest of this skill: it watches and distills. It never auto-edits CLAUDE.md or any agent instruction file, and the memory never leaves the user's repo.

Division of labor: the script does the deterministic mechanics (transcript discovery, redaction, merge, retirement, measurement); you do the judgment (curation).

1. Extract candidates from this project's recent transcripts:
   ```bash
   python3 "${CLAUDE_SKILL_DIR:-.}/scripts/second_brain.py" extract --project "$(pwd)" --since-hours 24
   ```
   Output is JSON: candidate entries pulled from user-authored messages only, already redacted (same rules as the other scripts; treat `<redacted:...>` placeholders as secrets that existed). The heuristics are deliberately narrow and will miss things you noticed in your own session; you add those during curation.

2. Curate against `references/second-brain.md` (read it before your first curation in a conversation). Keep durable project facts, drop noise, rewrite for precision, and never store secrets, even redacted-adjacent ones.

3. Merge the curated list, as JSON on stdin:
   ```bash
   python3 "${CLAUDE_SKILL_DIR:-.}/scripts/second_brain.py" merge --brain-dir "$(pwd)/.supervisor/second-brain" <<'EOF'
   [{"kind": "decision", "text": "use ruff for linting, not flake8"}]
   EOF
   ```
   The script confirms exact re-observations (bumping confidence a step), merges near-duplicates, retires entries unconfirmed for 5 iterations, regenerates memory.md from brain.json, and prints the iteration delta (added / confirmed / merged / retired / active_total). Report the delta to the user: it is the evidence the memory is improving, not just growing. An empty list `[]` is a valid iteration that only ages stale entries.

4. `show --brain-dir ...` prints where the memory lives and its current state. When an entry has earned promotion into CLAUDE.md (criteria in the reference), propose the exact line for the user to paste; the user applies it, never you.

The brain is three files under `<project>/.supervisor/second-brain/`: memory.md (human-readable, regenerated on every merge, so hand-edits there are lost by design), brain.json (the ledger, source of truth), and iteration-log.md (append-only measurement history). Whether to commit the directory is the user's call; suggest it, since a memory that lives in the repo travels with the repo.

## Rules that always apply

- Read-only toward other sessions: never write into `~/.claude/projects`, never modify another session's files or state.
- Never bypass redaction. If a script fails, do not fall back to reading transcripts raw and pasting them; fix the invocation or report the failure.
- Never authorize a destructive action on behalf of the user, in any session, including this one.
- Low confidence is a feature. "Nothing worth flagging" is a good report when it is true.

Want the full product (answers typed into sessions for you, keep-moving nudges, pause and stop, menu-bar health)? That is the macOS app: https://github.com/maximizeGPT/supervisor
