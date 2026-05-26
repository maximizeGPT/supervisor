#!/usr/bin/env python3
"""
v0.4.0-hook — dispatch-loop Stop hook for Claude Code.

Complementary mechanism to Supervisor.app, not a replacement.
Supervisor.app's responsibilities — safety rubric, question-answering
pipeline, multi-provider/recovery/calibration — still live in
Supervisor.app and still matter. This hook handles ONE of those
things, continuous-session dispatch, for the specific case of
"keep this Claude Code session going when I stop typing."

Mechanism: Claude Code's native Stop hook fires when the assistant
finishes a turn. The hook reads the conversation context, calls the
Dispatcher (DeepSeek, same key Supervisor.app uses), and on
high-confidence returns emits `{"decision":"block","reason":<next>}`
which feeds the proposal back to Claude as additional context — the
assistant keeps working without the user re-typing.

Opt-in: this hook exits silently unless
~/.claude/hooks/dispatch-loop-enabled.json exists. Mohammed creates
that file to enable; deletes it to disable without touching
settings.json. The file's JSON contents can override the defaults
below (max_consecutive_low, max_loop_duration_s, etc.).

State: ~/.claude/hooks/dispatch-loop-state.json — per-session
counters (total_dispatches, consecutive_low, loop_started_at,
stopped, stop_reason).

Log: ~/.claude/hooks/dispatch-loop.log — every invocation appends
one line (Stop hook is per-turn; this is the audit trail).

Dispatcher system prompt: loaded at runtime from
dispatcher-system-prompt.txt next to this script. That file is the
text-form copy of Sources/SupervisorCore/Triage/Dispatcher.swift's
`systemPrompt` static (Swift is the source of truth; the .txt is
re-extracted when the Swift changes — v0.4.x will refactor both to
read from the .txt directly).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# ----------------------------------------------------------------------
# Paths + defaults
# ----------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROMPT_FILE = SCRIPT_DIR / "dispatcher-system-prompt.txt"

HOOK_HOME = Path.home() / ".claude" / "hooks"
ENABLED_FLAG = HOOK_HOME / "dispatch-loop-enabled.json"
STATE_FILE = HOOK_HOME / "dispatch-loop-state.json"
LOG_FILE = HOOK_HOME / "dispatch-loop.log"

DEFAULTS = {
    "max_consecutive_low": 3,            # per §12.5 #3 — same as LoopController
    "max_loop_duration_s": 4 * 3600,      # per §12.5 #2
    "max_total_dispatches": 20,           # safety cap beyond §12.5 — outer ceiling
    "supervisor_repo_path": "/Users/main/supervisor",
    "branch_prefix": "autonomous-",
    "deepseek_url": "https://api.deepseek.com/v1/chat/completions",
    "deepseek_model": "deepseek-chat",
    "deepseek_timeout_s": 30,
    "keychain_service": "live.supervisor.api.deepseek",
    "keychain_account": "api-key",
    "issue_fetch_timeout_s": 10,
    "git_log_timeout_s": 10,
    "transcript_last_n_turns": 10,
    "recent_assistant_chars": 2000,
}

# ED-3 stop-shape phrase list, mirrored from
# Sources/SupervisorCore/Triage/TriageEngine.swift detectStopShape.
STOP_SHAPE_PHRASES = [
    "ready for next",
    "what's next",
    "let me know if",
    "let me know",
    "ship it",
    "already done",
    "all done",
    "complete",
    "done",
    "pushed",
    "already shipped",
    "shipped",
    "blocked on",
    "open issues remaining",
    "tests passing",
    "tests pass",
    "no further action",
    "no remaining",
    "session summary",
    "no work needed",
    "all tests green",
    "tests green",
    "hallucinated",
    "doesn't exist",
    "no asymmetry",
]


# ----------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------

def _ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(msg: str) -> None:
    HOOK_HOME.mkdir(parents=True, exist_ok=True)
    try:
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(f"{_ts()} {msg}\n")
    except Exception:
        # Never let logging break the hook itself.
        pass


def silent_exit(reason: str) -> None:
    """Exit 0 with no stdout — Claude Code lets the Stop proceed normally."""
    log(f"silent_exit reason={reason}")
    sys.exit(0)


def emit_block(text: str) -> None:
    """Emit a blocking decision: Claude Code feeds `reason` back as
    additional context within the same turn, and the assistant
    continues. Exit 0 is required."""
    out = {"decision": "block", "reason": text}
    sys.stdout.write(json.dumps(out))
    sys.stdout.flush()
    log(f"BLOCK reason_bytes={len(text)} head=\"{text[:120]}\"")
    sys.exit(0)


# ----------------------------------------------------------------------
# Config / state
# ----------------------------------------------------------------------

def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULTS)
    try:
        if ENABLED_FLAG.exists():
            raw = json.loads(ENABLED_FLAG.read_text(encoding="utf-8") or "{}")
            if isinstance(raw, dict):
                cfg.update(raw)
    except Exception as e:
        log(f"config_parse_error error={e}")
    return cfg


def load_state() -> dict[str, Any]:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8") or "{}")
    except Exception as e:
        log(f"state_parse_error error={e}")
        return {}


def save_state(state: dict[str, Any]) -> None:
    HOOK_HOME.mkdir(parents=True, exist_ok=True)
    try:
        STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")
    except Exception as e:
        log(f"state_save_error error={e}")


def get_session_state(state: dict[str, Any], session_id: str) -> dict[str, Any]:
    s = state.get(session_id) or {}
    if not isinstance(s, dict):
        s = {}
    return s


def put_session_state(state: dict[str, Any], session_id: str, new: dict[str, Any]) -> None:
    state[session_id] = new


# ----------------------------------------------------------------------
# Subprocess helpers
# ----------------------------------------------------------------------

def run(cmd: list[str], *, cwd: str | None = None, timeout: float = 10) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except FileNotFoundError as e:
        return 127, "", f"{e}"
    except Exception as e:
        return 1, "", f"{e}"


def read_keychain(service: str, account: str) -> str | None:
    code, out, err = run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        timeout=5,
    )
    if code != 0:
        log(f"keychain_error code={code} stderr={err.strip()[:120]}")
        return None
    key = out.strip()
    if not key:
        return None
    return key


def current_branch(cwd: str) -> str:
    code, out, _ = run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=cwd,
        timeout=5,
    )
    return out.strip() if code == 0 else ""


# ----------------------------------------------------------------------
# Transcript reading
# ----------------------------------------------------------------------

def read_recent_turns(transcript_path: str, n: int) -> list[dict[str, Any]]:
    """Read the last N user+assistant messages from the JSONL.
    Returns oldest-first list of {role, text, ts}."""
    if not transcript_path or not Path(transcript_path).exists():
        return []
    try:
        # Pull the last N*4 lines to be safe (each turn may have multiple
        # JSONL records — toolUse + toolResult, etc.).
        code, tail, _ = run(["tail", "-n", str(n * 6), transcript_path], timeout=5)
        if code != 0:
            return []
        turns: list[dict[str, Any]] = []
        for line in tail.splitlines():
            try:
                evt = json.loads(line)
            except Exception:
                continue
            etype = evt.get("type")
            msg = evt.get("message") or {}
            content = msg.get("content")
            text = ""
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                # content array of blocks; pick the text blocks
                parts: list[str] = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        parts.append(block.get("text", ""))
                text = "\n".join(parts)
            text = text.strip()
            if not text:
                continue
            if etype == "user":
                turns.append({"role": "user", "text": text, "ts": evt.get("timestamp", "")})
            elif etype == "assistant":
                turns.append({"role": "assistant", "text": text, "ts": evt.get("timestamp", "")})
        return turns[-n:]
    except Exception as e:
        log(f"transcript_read_error error={e}")
        return []


def has_stop_shape(text: str) -> str | None:
    """Return the first matching phrase, or None."""
    if not text:
        return None
    lower = text.lower()
    for p in STOP_SHAPE_PHRASES:
        if p in lower:
            return p
    return None


# ----------------------------------------------------------------------
# Issue / commit fetchers (best-effort; degrade to empty on any failure)
# ----------------------------------------------------------------------

def fetch_issues(cwd: str, timeout: float) -> list[dict[str, Any]]:
    code, out, err = run(
        ["gh", "issue", "list", "--json", "number,title,body,labels",
         "--limit", "50", "--state", "open"],
        cwd=cwd,
        timeout=timeout,
    )
    if code != 0:
        log(f"gh_issues_error code={code} stderr={err.strip()[:120]}")
        return []
    try:
        raw = json.loads(out) or []
    except Exception as e:
        log(f"gh_issues_parse_error error={e}")
        return []
    issues: list[dict[str, Any]] = []
    for item in raw:
        labels = [
            lbl.get("name", "") for lbl in (item.get("labels") or [])
            if isinstance(lbl, dict)
        ]
        issues.append({
            "number": item.get("number"),
            "title": item.get("title", ""),
            "body": item.get("body", ""),
            "labels": labels,
        })
    return issues


def fetch_diff_stat(cwd: str, branch: str, timeout: float) -> list[str]:
    """Return `git diff --stat main..branch` lines, truncated to the top 30
    files by change size. Gives the Dispatcher file-level signal about
    what's been touched — prevents hallucinating partial completion from
    commit subjects alone (Issue #10)."""
    code, out, err = run(
        ["git", "diff", "--stat", f"main..{branch}"],
        cwd=cwd,
        timeout=timeout,
    )
    if code != 0:
        log(f"git_diff_stat_error code={code} stderr={err.strip()[:120]}")
        return []
    lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
    # Last line is the summary ("N files changed, ..."); keep it but cap
    # file lines to 30.
    if not lines:
        return []
    summary = lines[-1] if "changed" in lines[-1] else None
    file_lines = lines[:-1] if summary else lines
    file_lines = file_lines[:30]
    if summary:
        file_lines.append(summary)
    return file_lines


def fetch_commits(cwd: str, branch: str, timeout: float) -> list[dict[str, str]]:
    code, out, err = run(
        ["git", "log", f"main..{branch}",
         "--pretty=format:%H%x00%s%x00%b%x1E",
         "--no-merges"],
        cwd=cwd,
        timeout=timeout,
    )
    if code != 0:
        log(f"git_log_error code={code} stderr={err.strip()[:120]}")
        return []
    commits: list[dict[str, str]] = []
    for record in out.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x00", 2)
        if len(parts) < 2:
            continue
        commits.append({
            "sha": parts[0].strip(),
            "subject": parts[1],
            "body": parts[2].strip() if len(parts) > 2 else "",
        })
    return commits


# ----------------------------------------------------------------------
# Dispatcher call
# ----------------------------------------------------------------------

def load_system_prompt() -> str:
    return PROMPT_FILE.read_text(encoding="utf-8")


def build_user_message(
    *,
    session_id: str,
    cwd: str,
    branch: str,
    recent_turns: list[dict[str, Any]],
    issues: list[dict[str, Any]],
    commits: list[dict[str, str]],
    recent_files_changed: list[str],
    prior_count: int,
    principles_text: str,
) -> str:
    lines: list[str] = []
    lines.append("# Session context")
    lines.append(f"session: {session_id}")
    lines.append(f"cwd: {cwd}")
    lines.append(f"branch: {branch}")
    lines.append("")
    lines.append("# Loop state")
    lines.append(f"prior_dispatches_considered: {prior_count}")
    lines.append("")
    lines.append("# Recent commits on this branch (since divergence from main)")
    if not commits:
        lines.append("(none — either fresh branch, or git fetch failed; treat as 'no commits to follow up on')")
    else:
        for c in commits:
            lines.append(f"- {c['sha'][:8]} {c['subject']}")
            if c["body"]:
                for ln in c["body"].split("\n"):
                    lines.append(f"  {ln}")
    lines.append("")
    lines.append("# Recent files changed on this branch (git diff --stat main..HEAD)")
    if not recent_files_changed:
        lines.append("(none — either fresh branch, or git diff failed)")
    else:
        for fl in recent_files_changed:
            lines.append(fl)
    lines.append("")
    lines.append("# Open GitHub issues (work queue)")
    if not issues:
        lines.append("(empty — either no open issues, or gh fetch failed; lower confidence accordingly if you were about to pick PATH 2)")
    else:
        for i in issues:
            tag = f" [{', '.join(i['labels'])}]" if i["labels"] else ""
            lines.append(f"## Issue #{i['number']} — {i['title']}{tag}")
            if i["body"]:
                lines.append(i["body"][:600])
            lines.append("")
    lines.append("# Session's last turns (most recent first)")
    if not recent_turns:
        lines.append("(no events in window)")
    else:
        for t in recent_turns[-10:]:
            role = t.get("role", "?")
            text = (t.get("text") or "")[:240]
            ts = t.get("ts", "")
            lines.append(f"[{ts}] {role}: {text}")
    lines.append("")
    lines.append("# PRINCIPLES.md (the project's operating manual)")
    lines.append("")
    lines.append(principles_text)
    lines.append("")
    lines.append("# Task")
    lines.append("Call `record_dispatch` exactly once. Pick PATH 1 (continue_branch) or PATH 2 (transition_to_issue), with confidence calibrated per the rubric in the system prompt. The next_task_proposal you write IS the prompt that gets typed into Claude Code — write it in the autonomous opener's voice.")
    return "\n".join(lines)


RECORD_DISPATCH_TOOL = {
    "type": "function",
    "function": {
        "name": "record_dispatch",
        "description": "Record the dispatch verdict: which task to pick up next + the prompt to inject into Claude Code.",
        "parameters": {
            "type": "object",
            "properties": {
                "next_task_proposal": {"type": "string"},
                "justification": {"type": "string"},
                "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                "selected_path": {
                    "type": "string",
                    "enum": ["continue_branch", "transition_to_issue", "low_confidence_no_action"],
                },
                "selected_issue_number": {"type": "integer"},
                "prior_dispatches_considered": {"type": "integer"},
                "requires_human_presence": {
                    "type": "boolean",
                    "description": "Set to true when the proposed task requires macOS GUI interaction (launching apps, granting AX permissions, physical-world trials, anything where Claude Code cannot fully execute from a terminal). The hook will NOT auto-dispatch these — they surface as a banner for the user to act on when present."
                },
            },
            "required": ["next_task_proposal", "justification", "confidence", "selected_path"],
        },
    },
}


def call_dispatcher(
    *,
    key: str,
    cfg: dict[str, Any],
    system_prompt: str,
    user_message: str,
) -> dict[str, Any] | None:
    """POST to DeepSeek's chat completions endpoint with a forced
    tool call. Returns the parsed tool-call arguments dict, or None."""
    body = {
        "model": cfg["deepseek_model"],
        "max_tokens": 8192,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "tools": [RECORD_DISPATCH_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "record_dispatch"}},
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        cfg["deepseek_url"],
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=cfg["deepseek_timeout_s"]) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        log(f"deepseek_http_error code={e.code} body={(e.read() or b'')[:200]!r}")
        return None
    except Exception as e:
        log(f"deepseek_call_error error={e}")
        return None
    return _parse_dispatcher_response(raw)


def _parse_dispatcher_response(raw: str) -> dict[str, Any] | None:
    """Parse the DeepSeek response JSON into tool-call arguments.
    Returns None on any parse failure."""
    try:
        obj = json.loads(raw)
    except Exception as e:
        log(f"deepseek_parse_error error={e} RAW_RESPONSE total_bytes={len(raw)} head=\"{raw[:300]}\"")
        return None
    try:
        choice = (obj.get("choices") or [{}])[0]
        finish_reason = choice.get("finish_reason", "(missing)")
        msg = choice.get("message") or {}
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            log(f"deepseek_no_tool_call finish_reason={finish_reason}")
            return None
        args_raw = tool_calls[0].get("function", {}).get("arguments", "")
        result = json.loads(args_raw)
        # Log finish_reason on success too, so we can see how close to
        # the ceiling real dispatches run.
        usage = obj.get("usage") or {}
        log(f"PARSE_OK finish_reason={finish_reason} output_tokens={usage.get('completion_tokens', '?')} args_bytes={len(args_raw)}")
        return result
    except Exception as e:
        # args_raw parse failure — likely truncated JSON from max_tokens hit.
        finish_reason = "(unknown)"
        try:
            finish_reason = (obj.get("choices") or [{}])[0].get("finish_reason", "(missing)")
        except Exception:
            pass
        args_head = ""
        try:
            args_head = (obj.get("choices") or [{}])[0].get("message", {}).get("tool_calls", [{}])[0].get("function", {}).get("arguments", "")[:300]
        except Exception:
            pass
        log(f"deepseek_parse_error error={e} finish_reason={finish_reason} RAW_RESPONSE args_head=\"{args_head}\" total_bytes={len(raw)}")
        return None


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

def main() -> None:
    # First gate: opt-in flag file. Without it, hook is a no-op.
    if not ENABLED_FLAG.exists():
        sys.exit(0)

    cfg = load_config()

    # Read Claude Code's hook input from stdin.
    try:
        hook_input = json.loads(sys.stdin.read() or "{}")
    except Exception as e:
        log(f"stdin_parse_error error={e}")
        sys.exit(0)

    session_id = hook_input.get("session_id") or ""
    cwd = hook_input.get("cwd") or ""
    transcript_path = hook_input.get("transcript_path") or ""

    log(f"INVOKE session={session_id} cwd={cwd}")

    # Gate: cwd must be the supervisor repo (or whatever's configured).
    if not cwd.startswith(cfg["supervisor_repo_path"]):
        silent_exit(f"cwd_not_supervisor cwd={cwd}")

    # Gate: branch must start with the autonomous-prefix.
    branch = current_branch(cwd)
    if not branch.startswith(cfg["branch_prefix"]):
        silent_exit(f"non_autonomous_branch branch={branch}")

    # Gate: last assistant turn must contain a stop-shape phrase.
    recent_turns = read_recent_turns(transcript_path, cfg["transcript_last_n_turns"])
    last_assistant = next(
        (t for t in reversed(recent_turns) if t.get("role") == "assistant"),
        None,
    )
    last_text = (last_assistant or {}).get("text", "")
    stop_phrase = has_stop_shape(last_text[-cfg["recent_assistant_chars"]:] if last_text else "")
    if not stop_phrase:
        silent_exit("no_stop_shape")

    # Load state, apply loop hard stops.
    state_all = load_state()
    state = get_session_state(state_all, session_id)
    now_s = time.time()

    if state.get("stopped"):
        silent_exit(f"loop_already_stopped reason={state.get('stop_reason')}")

    if "loop_started_at" not in state:
        state["loop_started_at"] = now_s

    if (now_s - state["loop_started_at"]) >= cfg["max_loop_duration_s"]:
        state["stopped"] = True
        state["stop_reason"] = "four_hours_elapsed"
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit("hard_stop_four_hours")

    if state.get("consecutive_low", 0) >= cfg["max_consecutive_low"]:
        state["stopped"] = True
        state["stop_reason"] = "three_consecutive_low_confidence"
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit("hard_stop_three_lows")

    if state.get("total_dispatches", 0) >= cfg["max_total_dispatches"]:
        state["stopped"] = True
        state["stop_reason"] = "max_total_dispatches"
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit("hard_stop_max_dispatches")

    # Read PRINCIPLES.md (the dispatcher needs it).
    principles_path = Path(cfg["supervisor_repo_path"]) / "PRINCIPLES.md"
    principles_text = principles_path.read_text(encoding="utf-8") if principles_path.exists() else ""
    if not principles_text:
        silent_exit("no_principles_md")

    # Read the system prompt (text-form copy of Dispatcher.swift).
    try:
        system_prompt = load_system_prompt()
    except Exception as e:
        log(f"prompt_load_error error={e}")
        silent_exit("no_system_prompt")

    # Fetch dispatch context.
    issues = fetch_issues(cwd, cfg["issue_fetch_timeout_s"])
    commits = fetch_commits(cwd, branch, cfg["git_log_timeout_s"])
    diff_stat = fetch_diff_stat(cwd, branch, cfg["git_log_timeout_s"])
    prior_count = state.get("total_dispatches", 0)

    log(f"DISPATCH_PREPARE session={session_id} stop_phrase=\"{stop_phrase}\" "
        f"prior={prior_count} issues={len(issues)} commits={len(commits)}")

    # Read API key.
    key = read_keychain(cfg["keychain_service"], cfg["keychain_account"])
    if not key:
        silent_exit("no_deepseek_key")

    # Build + send the Dispatcher request.
    user_message = build_user_message(
        session_id=session_id,
        cwd=cwd,
        branch=branch,
        recent_turns=recent_turns,
        issues=issues,
        commits=commits,
        recent_files_changed=diff_stat,
        prior_count=prior_count,
        principles_text=principles_text,
    )
    log(f"DISPATCH_CALL user_message_bytes={len(user_message.encode('utf-8'))}")

    result = call_dispatcher(
        key=key, cfg=cfg,
        system_prompt=system_prompt,
        user_message=user_message,
    )

    # v0.4.1-hook: retry once on parse error (DeepSeek sometimes
    # returns malformed JSON with unterminated strings).
    if result is None:
        log("RETRY_PARSE_ERROR attempt=1 reason=first_call_returned_none")
        result = call_dispatcher(
            key=key, cfg=cfg,
            system_prompt=system_prompt,
            user_message=user_message,
        )
        if result is None:
            log("RETRY_PARSE_ERROR attempt=1 outcome=still_none")
        else:
            log("RETRY_PARSE_ERROR attempt=1 outcome=success")

    # Update state regardless of result, then act.
    state["total_dispatches"] = state.get("total_dispatches", 0) + 1

    if not result:
        # Dispatcher errored — count as a low for §12.5 #3.
        state["consecutive_low"] = state.get("consecutive_low", 0) + 1
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit("dispatcher_returned_none")

    confidence = (result.get("confidence") or "low").lower()
    selected_path = result.get("selected_path", "")
    proposal = result.get("next_task_proposal", "") or ""
    justification = result.get("justification", "") or ""
    requires_human = bool(result.get("requires_human_presence", False))

    log(f"DISPATCH_RESULT confidence={confidence} path={selected_path} "
        f"prop_bytes={len(proposal)} requires_human={requires_human} "
        f"just=\"{justification[:120]}\"")

    # v0.4.1-hook: requires_human_presence gate. Tasks needing GUI
    # interaction (AX permissions, app launches, physical-world trials)
    # must surface as banners, not auto-dispatch.
    if requires_human:
        state["consecutive_low"] = state.get("consecutive_low", 0) + 1
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit(f"GATE_FAIL reason=requires_human_presence path={selected_path}")

    if confidence == "high" and selected_path != "low_confidence_no_action" and proposal:
        state["consecutive_low"] = 0
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        # Include a short prefix so the assistant knows this came from
        # the hook (not from Mohammed). The autonomous opener tone is
        # already inside `proposal`; the prefix just labels the source.
        prefixed = (
            "[dispatch-loop-hook v0.4.1 — auto-dispatched by Stop hook; "
            f"justification: {justification.strip()}]\n\n{proposal.strip()}"
        )
        emit_block(prefixed)
    else:
        state["consecutive_low"] = state.get("consecutive_low", 0) + 1
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit(f"non_high_confidence confidence={confidence} path={selected_path}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        # Never break the user's session because the hook crashed —
        # log loudly and let the Stop proceed.
        log(f"FATAL exception={exc!r}")
        sys.exit(0)
