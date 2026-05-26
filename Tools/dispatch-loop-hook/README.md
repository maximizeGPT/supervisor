# v0.4.0-hook — dispatch-loop Stop hook

A small Claude Code Stop hook that handles continuous-session
dispatch inline. **Complementary to Supervisor.app, not a replacement.**

## What it is

Supervisor.app does four things:
1. Safety rubric (destructive_action_pending, edits_outside_worktree,
   prompt_injection_signature, user_question_pending,
   worker_idle_post_completion)
2. Question-answering pipeline (the v0.3.0 secondary Haiku
   answer/translate calls)
3. Continuous-session dispatch (the v0.4.0 Dispatcher + LoopController)
4. Multi-provider routing, recovery docs, calibration history

This hook implements ONE of those — the v0.4.0 dispatch piece — for
the specific case of "keep this Claude Code session going when I
stop typing." It does NOT do safety triage, question-answering,
recovery, or multi-provider arbitration. Supervisor.app still owns
those.

The dispatch is the lightest piece of the loop architecturally and
the heaviest piece operationally — `CGEventPost` into another
terminal needs Accessibility permission, code-signed binary,
running daemon, etc. Claude Code's native Stop hook contract lets
us short-circuit all of that for the in-session case: the hook
runs inside the running `claude` process, gets the session context
for free, and feeds the next prompt back as additional context via
`{"decision":"block","reason":...}`.

## What it is NOT

- Not a replacement for Supervisor.app.
- Not a cross-process supervisor — it only continues the session
  it's installed in. Cross-process supervision (watching someone
  else's worker, e.g.) still requires Supervisor.app's
  CGEventPost path.
- Not a safety harness. Anything destructive that the worker does
  is still triaged by Supervisor.app's rubric. The hook doesn't
  look at tool calls; it only decides whether to continue.

## Files

- `dispatch_loop_hook.py` — the hook script. Reads stdin (Claude
  Code's session JSON), gates aggressively, calls the Dispatcher
  (DeepSeek), emits `block` decision on high confidence.
- `dispatcher-system-prompt.txt` — text-form copy of
  `Sources/SupervisorCore/Triage/Dispatcher.swift`'s `systemPrompt`.
  Swift is the source of truth; this file is regenerated when the
  Swift changes (filed for v0.4.x: refactor both to read from the
  `.txt` directly).
- `settings.example.json` — the snippet to merge into
  `~/.claude/settings.json` to register the hook.

## How the hook decides to fire

Six gates, all must pass:

1. **Opt-in flag** — `~/.claude/hooks/dispatch-loop-enabled.json`
   must exist. Without it, the hook is a silent no-op. The file's
   contents (if non-empty) can override the default thresholds:
   `max_consecutive_low`, `max_loop_duration_s`,
   `max_total_dispatches`, `supervisor_repo_path`, `branch_prefix`.
2. **cwd match** — the running `claude` session's cwd must start
   with `supervisor_repo_path` (default `/Users/main/supervisor`).
3. **Branch match** — `git rev-parse --abbrev-ref HEAD` must
   return a branch starting with `branch_prefix` (default
   `autonomous-`). Hook will not fire on `main` or feature
   branches.
4. **Stop-shape phrase** — the last assistant turn (read from
   the transcript JSONL) must contain one of the ED-3 phrases
   ("ready for next", "what's next", "let me know if",
   "let me know", "ship it", "all done", "complete", "done").
5. **No hard stop tripped** — loop hasn't hit 4-hour budget,
   3 consecutive lows, or `max_total_dispatches` cap.
6. **Dispatcher returns `confidence=high`** — medium/low/error
   all let the Stop proceed normally.

If all six pass, the hook emits `{"decision":"block","reason":...}`
and the assistant continues.

## Enable

After `settings.json` is registered (one-time):

```bash
mkdir -p ~/.claude/hooks
echo '{}' > ~/.claude/hooks/dispatch-loop-enabled.json
```

That's it. Hook fires on the next Stop event in any qualifying
session.

## Disable

```bash
rm ~/.claude/hooks/dispatch-loop-enabled.json
```

The `settings.json` registration stays; the hook still runs on
every Stop but exits silently because the flag is gone. To
fully uninstall, remove the `Stop` block from `settings.json`.

## State + logs

- `~/.claude/hooks/dispatch-loop-state.json` — per-session
  counters (`total_dispatches`, `consecutive_low`,
  `loop_started_at`, `stopped`, `stop_reason`). Inspect to see
  current loop state.
- `~/.claude/hooks/dispatch-loop.log` — append-only audit trail.
  One line per Stop invocation: enabled-check, gate failures,
  dispatcher result, block decisions.

## Hard stops (mirrors PRINCIPLES.md v3.5 §12.5)

The hook enforces the same loop hard stops Supervisor.app does:

- 4 hours wall-clock since the first dispatch in this session.
- 3 consecutive lows (or `.error` returns — counted as lows).
- `max_total_dispatches` cap (default 20 — outer safety ceiling
  beyond §12.5).

Once tripped, the hook stays no-op for the session until you
clear the state:

```bash
# Reset state for one session:
python3 -c "import json,pathlib; p=pathlib.Path.home()/'.claude/hooks/dispatch-loop-state.json'; \
  d=json.loads(p.read_text() or '{}'); d.pop('<SESSION_UUID>', None); p.write_text(json.dumps(d,indent=2))"
```

## Cost

~$0.003 per dispatch on DeepSeek (PRINCIPLES.md is ~30k chars
input + session context ~5k + ~500 output). 20 dispatches max
per session ≈ $0.06. The `max_total_dispatches=20` is what
keeps a runaway loop bounded under §9e.

The hook reads the DeepSeek key from the same Keychain entry
Supervisor.app uses (`service=live.supervisor.api.deepseek`,
`account=api-key`). If you haven't onboarded Supervisor.app
with a DeepSeek key, the hook will exit silently with
`no_deepseek_key` in the log.

## Relationship to the autonomous branch

This artifact lives in `Tools/dispatch-loop-hook/` on the
autonomous branch (`autonomous-20260525T193906Z`) and depends on
PRINCIPLES.md v3.5 being on disk. PRINCIPLES.md v3.5 is on
`main` (commit `8b69cdc`). The hook reads PRINCIPLES.md from
`supervisor_repo_path/PRINCIPLES.md` at runtime — whichever
version is on disk gets used.

When v0.4.0 merges to main, the hook can move under
`Tools/dispatch-loop-hook/` on main and stay opt-in via the
flag file. No code changes needed.
