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
SELF_EXTENDER_PROMPT_FILE = SCRIPT_DIR / "self-extender-system-prompt.txt"

HOOK_HOME = Path(os.environ.get("DISPATCH_HOOK_HOME", "")) if os.environ.get("DISPATCH_HOOK_HOME") else Path.home() / ".claude" / "hooks"
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


def detect_worker_stopped(transcript_path: str) -> bool:
    """Return True if the most recent assistant message in the JSONL has
    zero tool_use blocks — i.e., the worker stopped doing work. Returns
    False if the last assistant turn contains any tool_use, or if the
    transcript is empty / unreadable."""
    if not transcript_path or not Path(transcript_path).exists():
        return False
    try:
        # Read the tail of the JSONL — enough to find the last assistant msg.
        code, tail, _ = run(["tail", "-n", "60", transcript_path], timeout=5)
        if code != 0:
            return False
        # Walk backwards to find the last assistant message.
        last_assistant_content = None
        for line in reversed(tail.splitlines()):
            try:
                evt = json.loads(line)
            except Exception:
                continue
            if evt.get("type") != "assistant":
                continue
            msg = evt.get("message") or {}
            content = msg.get("content")
            if content is not None:
                last_assistant_content = content
                break
        if last_assistant_content is None:
            return False
        # Check if any content block is tool_use.
        if isinstance(last_assistant_content, list):
            for block in last_assistant_content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    return False
        return True
    except Exception as e:
        log(f"detect_worker_stopped error={e}")
        return False


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


def _try_repair_truncated_json(s: str) -> dict[str, Any] | None:
    """Attempt to recover a dict from truncated JSON (finish_reason=length).
    DeepSeek sometimes hits max_tokens mid-JSON, leaving unterminated strings
    and missing closing braces. Try progressively aggressive repairs."""
    if not s or not s.strip():
        return None
    # Strategy 1: close unterminated string + add missing braces.
    # Find the last complete key-value pair boundary.
    repaired = s.rstrip()
    # If we're inside a string value, close it
    quote_count = repaired.count('"')
    if quote_count % 2 != 0:
        repaired += '"'
    # Close any open braces/brackets
    open_braces = repaired.count('{') - repaired.count('}')
    open_brackets = repaired.count('[') - repaired.count(']')
    repaired += ']' * max(0, open_brackets)
    repaired += '}' * max(0, open_braces)
    try:
        result = json.loads(repaired)
        if isinstance(result, dict):
            return result
    except Exception:
        pass
    # Strategy 2: truncate to last complete key-value pair.
    # Walk backwards to find a comma or opening brace before the damage.
    for i in range(len(s) - 1, 0, -1):
        if s[i] in (',', '{'):
            candidate = s[:i] if s[i] == ',' else s[:i+1]
            # Close any remaining structure
            open_b = candidate.count('{') - candidate.count('}')
            open_k = candidate.count('[') - candidate.count(']')
            candidate += ']' * max(0, open_k)
            candidate += '}' * max(0, open_b)
            try:
                result = json.loads(candidate)
                if isinstance(result, dict):
                    return result
            except Exception:
                continue
    return None


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
        args_raw = ""
        try:
            args_raw = (obj.get("choices") or [{}])[0].get("message", {}).get("tool_calls", [{}])[0].get("function", {}).get("arguments", "")
        except Exception:
            pass
        # Attempt JSON repair on truncated responses
        if finish_reason == "length" and args_raw:
            repaired = _try_repair_truncated_json(args_raw)
            if repaired:
                log(f"PARSE_REPAIRED finish_reason=length original_bytes={len(args_raw)} "
                    f"keys={list(repaired.keys())}")
                return repaired
        log(f"deepseek_parse_error error={e} finish_reason={finish_reason} RAW_RESPONSE args_head=\"{args_raw[:300]}\" total_bytes={len(raw)}")
        return None


# ----------------------------------------------------------------------
# SelfExtender (v0.5.0)
# ----------------------------------------------------------------------

RECORD_SELF_EXTEND_TOOL = {
    "type": "function",
    "function": {
        "name": "record_self_extend",
        "description": "Record the self-extension verdict: a fix prompt to inject into Claude Code.",
        "parameters": {
            "type": "object",
            "properties": {
                "fix_prompt": {"type": "string"},
                "diagnosis": {"type": "string"},
                "confidence": {"type": "string", "enum": ["high", "low"]},
            },
            "required": ["fix_prompt", "diagnosis", "confidence"],
        },
    },
}


def load_self_extender_prompt() -> str:
    return SELF_EXTENDER_PROMPT_FILE.read_text(encoding="utf-8")


def read_hook_log_tail(n_lines: int = 200) -> str:
    """Read the last N lines of the dispatch-loop.log."""
    if not LOG_FILE.exists():
        return "(no log file)"
    try:
        code, out, _ = run(["tail", "-n", str(n_lines), str(LOG_FILE)], timeout=5)
        return out if code == 0 else "(log read failed)"
    except Exception:
        return "(log read error)"


def build_self_extender_message(
    *,
    failure_reason: str,
    session_id: str,
    cwd: str,
    branch: str,
    recent_turns: list[dict[str, Any]],
    commits: list[dict[str, str]],
    recent_files_changed: list[str],
    principles_text: str,
    hook_log_tail: str,
) -> str:
    lines: list[str] = []
    lines.append("# Failure context")
    lines.append(f"failure_reason: {failure_reason}")
    lines.append(f"session: {session_id}")
    lines.append(f"cwd: {cwd}")
    lines.append(f"branch: {branch}")
    lines.append("")
    lines.append("# Recent commits on this branch")
    if not commits:
        lines.append("(none)")
    else:
        for c in commits:
            lines.append(f"- {c['sha'][:8]} {c['subject']}")
    lines.append("")
    lines.append("# Recent files changed (git diff --stat main..HEAD)")
    if not recent_files_changed:
        lines.append("(none)")
    else:
        for fl in recent_files_changed:
            lines.append(fl)
    lines.append("")
    lines.append("# Recent transcript turns")
    if not recent_turns:
        lines.append("(no events)")
    else:
        for t in recent_turns[-10:]:
            role = t.get("role", "?")
            text = (t.get("text") or "")[:240]
            lines.append(f"[{t.get('ts', '')}] {role}: {text}")
    lines.append("")
    lines.append("# dispatch-loop.log (last 200 lines)")
    lines.append(hook_log_tail)
    lines.append("")
    lines.append("# PRINCIPLES.md")
    lines.append(principles_text)
    lines.append("")
    lines.append("# Task")
    lines.append("Call `record_self_extend` exactly once. Diagnose the failure and produce a fix prompt.")
    return "\n".join(lines)


def call_self_extender(
    *,
    key: str,
    cfg: dict[str, Any],
    system_prompt: str,
    user_message: str,
) -> dict[str, Any] | None:
    """Call DeepSeek with the SelfExtender prompt. Same mechanics as
    call_dispatcher but uses the record_self_extend tool."""
    body = {
        "model": cfg["deepseek_model"],
        "max_tokens": 8192,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "tools": [RECORD_SELF_EXTEND_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "record_self_extend"}},
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
    except Exception as e:
        log(f"self_extender_call_error error={e}")
        return None
    return _parse_self_extender_response(raw)


def _parse_self_extender_response(raw: str) -> dict[str, Any] | None:
    """Parse the SelfExtender response."""
    try:
        obj = json.loads(raw)
    except Exception as e:
        log(f"self_extender_parse_error error={e}")
        return None
    try:
        choice = (obj.get("choices") or [{}])[0]
        finish_reason = choice.get("finish_reason", "(missing)")
        msg = choice.get("message") or {}
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            return None
        args_raw = tool_calls[0].get("function", {}).get("arguments", "")
        return json.loads(args_raw)
    except Exception as e:
        # Attempt repair on truncated responses
        finish_reason = "(unknown)"
        args_raw = ""
        try:
            choice = (obj.get("choices") or [{}])[0]
            finish_reason = choice.get("finish_reason", "(missing)")
            args_raw = choice.get("message", {}).get("tool_calls", [{}])[0].get("function", {}).get("arguments", "")
        except Exception:
            pass
        if finish_reason == "length" and args_raw:
            repaired = _try_repair_truncated_json(args_raw)
            if repaired:
                log(f"SELF_EXTEND_PARSE_REPAIRED finish_reason=length keys={list(repaired.keys())}")
                return repaired
        log(f"self_extender_parse_error error={e} finish_reason={finish_reason}")
        return None


def detect_stuck_patterns(last_text: str) -> str | None:
    """Check if the worker's last text contains stuck-signal phrases.
    Returns the matched phrase or None."""
    if not last_text:
        return None
    lower = last_text.lower()
    stuck_phrases = [
        "would normally ask",
        "needs a values call",
        "principles doesn't cover",
        "no work needed",
        "already shipped",
        "already done",
    ]
    for p in stuck_phrases:
        if p in lower:
            return p
    return None


def try_self_extend(
    *,
    failure_reason: str,
    key: str,
    cfg: dict[str, Any],
    session_id: str,
    cwd: str,
    branch: str,
    recent_turns: list[dict[str, Any]],
    commits: list[dict[str, str]],
    recent_files_changed: list[str],
    principles_text: str,
    state: dict[str, Any],
    state_all: dict[str, Any],
) -> None:
    """Invoke the SelfExtender. On high-confidence result, emit_block.
    On low-confidence, retry once with escalation. If still low, inject
    an investigation prompt. Never silent_exit — the loop stays alive."""
    log(f"SELF_EXTEND_START reason={failure_reason}")

    try:
        se_prompt = load_self_extender_prompt()
    except Exception as e:
        log(f"self_extender_prompt_load_error error={e}")
        silent_exit("no_self_extender_prompt")

    hook_log = read_hook_log_tail(200)

    user_msg = build_self_extender_message(
        failure_reason=failure_reason,
        session_id=session_id,
        cwd=cwd,
        branch=branch,
        recent_turns=recent_turns,
        commits=commits,
        recent_files_changed=recent_files_changed,
        principles_text=principles_text,
        hook_log_tail=hook_log,
    )

    result = call_self_extender(key=key, cfg=cfg, system_prompt=se_prompt, user_message=user_msg)

    if result and (result.get("confidence") or "").lower() == "high" and result.get("fix_prompt"):
        fix_prompt = result["fix_prompt"]
        diagnosis = result.get("diagnosis", "")
        # Validate: never allow issue-filing in the fix prompt
        if "gh issue create" in fix_prompt.lower() or "filed as issue" in fix_prompt.lower():
            log(f"SELF_EXTEND_BLOCKED reason=fix_prompt_contains_issue_filing")
        log(f"SELF_EXTEND_HIGH diagnosis=\"{diagnosis[:120]}\"")
        state["consecutive_low"] = 0
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        prefixed = (
            f"[dispatch-loop-hook v0.5.0 — SelfExtender auto-fix; "
            f"failure: {failure_reason}; diagnosis: {diagnosis.strip()[:200]}]\n\n"
            f"{fix_prompt.strip()}"
        )
        emit_block(prefixed)
        return  # emit_block calls sys.exit(0); return is belt-and-suspenders

    # First attempt returned low or None — retry with escalation
    log("SELF_EXTEND_RETRY reason=first_call_low_or_none")
    escalation_msg = (
        user_msg + "\n\n# ESCALATION\n"
        "You returned low confidence on the first call. Identify the smallest "
        "incremental fix that would unblock progress, even if it's not the "
        "complete fix. Ship that. If you can see any code to read or any test "
        "to run that would clarify the situation, produce a prompt that does "
        "that and writes findings to trial-notes.md."
    )
    result2 = call_self_extender(key=key, cfg=cfg, system_prompt=se_prompt, user_message=escalation_msg)

    if result2 and result2.get("fix_prompt"):
        fix_prompt = result2["fix_prompt"]
        diagnosis = result2.get("diagnosis", "")
        log(f"SELF_EXTEND_RETRY_OK diagnosis=\"{diagnosis[:120]}\"")
        state["consecutive_low"] = 0
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        prefixed = (
            f"[dispatch-loop-hook v0.5.0 — SelfExtender retry; "
            f"failure: {failure_reason}; diagnosis: {diagnosis.strip()[:200]}]\n\n"
            f"{fix_prompt.strip()}"
        )
        emit_block(prefixed)
        return  # emit_block calls sys.exit(0); return is belt-and-suspenders

    # Both calls failed — inject investigation prompt as last resort
    log("SELF_EXTEND_FALLBACK reason=both_calls_failed")
    state["consecutive_low"] = 0  # reset to prevent infinite loop
    put_session_state(state_all, session_id, state)
    save_state(state_all)
    fallback = (
        "[dispatch-loop-hook v0.5.0 — SelfExtender fallback; "
        f"failure: {failure_reason}; both SelfExtender calls failed]\n\n"
        "Investigate the dispatch failure. Read:\n"
        "  1. ~/.claude/hooks/dispatch-loop.log (last 50 lines)\n"
        "  2. git log --oneline -10\n"
        "  3. git diff --stat main..HEAD\n"
        "Write findings + a hypothesis to trial-notes.md on this branch. "
        "Then propose the smallest fix that would unblock the dispatch loop."
    )
    emit_block(fallback)


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

    # Gate: last assistant turn must have no tool_use blocks (worker stopped).
    if not detect_worker_stopped(transcript_path):
        silent_exit("worker_still_working")

    recent_turns = read_recent_turns(transcript_path, cfg["transcript_last_n_turns"])

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

    # v0.5.0: consecutive lows trigger SelfExtender instead of hard stop.
    # SelfExtender resets consecutive_low on success, keeping the loop alive.

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

    log(f"DISPATCH_PREPARE session={session_id} worker_idle_signal=no_tool_use "
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

    # v0.5.0: common kwargs for SelfExtender invocation.
    se_kwargs = dict(
        key=key, cfg=cfg, session_id=session_id, cwd=cwd, branch=branch,
        recent_turns=recent_turns, commits=commits, recent_files_changed=diff_stat,
        principles_text=principles_text, state=state, state_all=state_all,
    )

    if not result:
        # Dispatcher errored — v0.5.0: SelfExtender instead of silent_exit.
        state["consecutive_low"] = state.get("consecutive_low", 0) + 1
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        try_self_extend(failure_reason="dispatcher_returned_none", **se_kwargs)
        # try_self_extend calls emit_block or silent_exit; if we reach here, something went wrong
        silent_exit("self_extend_unreachable")

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
            "[dispatch-loop-hook v0.5.0 — auto-dispatched by Stop hook; "
            f"justification: {justification.strip()}]\n\n{proposal.strip()}"
        )
        emit_block(prefixed)
    else:
        state["consecutive_low"] = state.get("consecutive_low", 0) + 1
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        # v0.5.0: SelfExtender on non-high confidence instead of silent_exit.
        try_self_extend(
            failure_reason=f"non_high_confidence confidence={confidence} path={selected_path}",
            **se_kwargs,
        )
        silent_exit("self_extend_unreachable")


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
