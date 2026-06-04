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
import re
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

# Provider registry — mirrors LLMProvider.swift. Maps provider name
# (as stored in active-provider.json) to URL, model, keychain service.
PROVIDERS = {
    "anthropic": {
        "url": "https://api.anthropic.com/v1/messages",
        "model": "claude-haiku-4-5-20251001",
        "keychain_service": "live.supervisor.api.anthropic",
        "api_shape": "anthropic",
    },
    "deepseek": {
        "url": "https://api.deepseek.com/v1/chat/completions",
        "model": "deepseek-chat",
        "keychain_service": "live.supervisor.api.deepseek",
        "api_shape": "openai",
    },
    "moonshot": {
        "url": "https://api.moonshot.ai/v1/chat/completions",
        "model": "kimi-k2-0905-preview",
        "keychain_service": "live.supervisor.api.moonshot",
        "api_shape": "openai",
    },
    "minimax": {
        "url": "https://api.minimax.chat/v1/chat/completions",
        "model": "MiniMax-M1",
        "keychain_service": "live.supervisor.api.minimax",
        "api_shape": "openai",
    },
    "qwenHF": {
        "url": "https://router.huggingface.co/v1/chat/completions",
        "model": "Qwen/Qwen2.5-72B-Instruct",
        "keychain_service": "live.supervisor.api.qwenhf",
        "api_shape": "openai",
    },
}

ACTIVE_PROVIDER_PATH = Path.home() / "Library" / "Application Support" / "Supervisor" / "active-provider.json"


def resolve_provider_config() -> dict[str, str]:
    """Read the user's active provider from active-provider.json and return
    the matching URL, model, keychain service. Falls back to DeepSeek if the
    file is missing or unreadable (backwards compat with v0.4.x hook)."""
    provider_name = "deepseek"  # default fallback
    try:
        if ACTIVE_PROVIDER_PATH.exists():
            data = json.loads(ACTIVE_PROVIDER_PATH.read_text(encoding="utf-8"))
            provider_name = data.get("activeProvider", "deepseek")
    except Exception:
        pass  # fall through to default
    if provider_name not in PROVIDERS:
        provider_name = "deepseek"
    return PROVIDERS[provider_name]


DEFAULTS = {
    "max_consecutive_low": 3,            # per §12.5 #3 — same as LoopController
    "max_loop_duration_s": 4 * 3600,      # per §12.5 #2
    "max_total_dispatches": 20,           # safety cap beyond §12.5 — outer ceiling
    # Fresh-session reset: the 4-hour budget bounds a CONTINUOUS autonomous
    # run, not wall-clock through an overnight pause. If the worker has been
    # idle (no Stop-hook activity) for at least this long, the human stepped
    # away — closed the laptop, slept — so the next resume is treated as a
    # brand-new Supervisor session: the clock and counters reset. Chosen
    # longer than the 75-min single-task cap (§12) so it never trips
    # mid-work, and far shorter than a sleep.
    "session_reset_idle_s": 2 * 3600,    # 2h idle → resume is a fresh session
    # Repetition breaker: if a new high-confidence proposal overlaps the
    # previous dispatched proposal by at least this Jaccard fraction, it is
    # treated as the SAME task and the loop stops (real thrashing on one
    # thing). Two genuinely different tasks share far fewer words, so they
    # never trip this.
    "same_proposal_jaccard_threshold": 0.8,
    "supervisor_repo_path": "/Users/main/supervisor",
    "branch_prefix": "autonomous-",
    # Provider settings are resolved dynamically from active-provider.json.
    # These defaults are overridden by resolve_provider_config() in main().
    "provider_url": "https://api.deepseek.com/v1/chat/completions",
    "provider_model": "deepseek-chat",
    "provider_timeout_s": 30,
    "keychain_service": "live.supervisor.api.deepseek",
    "keychain_account": "api-key",
    "api_shape": "openai",
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
    # Resolve provider from active-provider.json — overrides defaults
    # with the user's actual configured provider.
    prov = resolve_provider_config()
    cfg["provider_url"] = prov["url"]
    cfg["provider_model"] = prov["model"]
    cfg["keychain_service"] = prov["keychain_service"]
    cfg["api_shape"] = prov["api_shape"]
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


def apply_idle_reset(state: dict[str, Any], now_s: float, idle_threshold_s: float) -> bool:
    """Fresh-session reset on resume after a long idle gap.

    If the worker has been idle (no Stop-hook activity) for at least
    `idle_threshold_s`, the human stepped away — closed the laptop, slept —
    so the next resume is treated as a BRAND-NEW Supervisor session: restart
    the 4-hour clock, clear the sticky stop, and reset the per-session
    counters. Always stamps `last_seen_at = now_s`. Returns True iff a reset
    happened.

    The 4-hour budget (§12.5 #2) bounds a CONTINUOUS autonomous run; it must
    not keep ticking through an overnight pause. The threshold is chosen
    longer than the 75-min single-task cap (§12) so it never trips mid-work,
    and far shorter than a sleep. The very first invocation (no prior
    last_seen_at) never resets — there is no gap yet.
    """
    last_seen = state.get("last_seen_at")
    did_reset = False
    if last_seen is not None and (now_s - last_seen) >= idle_threshold_s:
        state["loop_started_at"] = now_s
        state["stopped"] = False
        state["stop_reason"] = None
        state["total_dispatches"] = 0
        state["consecutive_low"] = 0
        did_reset = True
    state["last_seen_at"] = now_s
    if "loop_started_at" not in state:
        state["loop_started_at"] = now_s
    return did_reset


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


def resolve_repo_root(cwd: str, configured_root: str) -> str:
    """Resolve the repo ROOT for the session, regardless of which
    subdirectory it started in.

    A session launched from e.g. `Tools/dispatch-loop-hook` reports that
    subdir as cwd; if the hook used it verbatim it would grep `Sources/`
    in the wrong place (source_markers_error) and write OWNER-BRIEF.md
    into the subdir instead of the repo root. This resolves the true root
    via `git rev-parse --show-toplevel`, falling back to the configured
    repo path. The result never escapes the configured repo: if the git
    toplevel isn't the configured root (or under it), or git fails, we use
    the configured root as long as cwd is inside it.
    """
    code, out, _ = run(["git", "rev-parse", "--show-toplevel"], cwd=cwd, timeout=5)
    if code == 0:
        root = out.strip()
        if root == configured_root or root.startswith(configured_root.rstrip("/") + "/"):
            return root
    # Git failed or returned an unexpected root. If the session is inside
    # the configured repo, pin to that known root; otherwise leave cwd.
    if cwd == configured_root or cwd.startswith(configured_root.rstrip("/") + "/"):
        return configured_root
    return cwd


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


def _resolve_diff_base(cwd: str, branch: str, timeout: float) -> str | None:
    """Find the best base ref to diff against. Tries, in order:
    1. merge-base of main and the branch (the actual divergence point)
    2. merge-base of origin/main and the branch
    3. merge-base of main and HEAD (if branch name doesn't resolve)
    4. merge-base of origin/main and HEAD
    5. None (caller falls back to HEAD~20)
    Returns the base commit SHA or None."""
    # Try branch name first, then HEAD as fallback (handles detached HEAD
    # and cases where the branch name doesn't resolve as a git ref).
    targets = [branch, "HEAD"] if branch != "HEAD" else ["HEAD"]
    for target in targets:
        for base_ref in ("main", "origin/main"):
            code, out, _ = run(
                ["git", "merge-base", base_ref, target],
                cwd=cwd,
                timeout=timeout,
            )
            if code == 0 and out.strip():
                return out.strip()
    return None


def _safe_head_range(cwd: str, n: int, timeout: float) -> str:
    """Return a safe diff range like 'HEAD~N..HEAD' where N is capped to the
    actual number of commits available. Falls back to diffing against the
    repo root commit if the branch is very short."""
    # Count available commits.
    code, out, _ = run(
        ["git", "rev-list", "--count", "HEAD"],
        cwd=cwd, timeout=timeout,
    )
    if code == 0 and out.strip().isdigit():
        available = int(out.strip())
        actual_n = min(n, max(available - 1, 0))
        if actual_n > 0:
            return f"HEAD~{actual_n}..HEAD"
    # Very short branch or rev-list failed — diff against root commit.
    code, out, _ = run(
        ["git", "rev-list", "--max-parents=0", "HEAD"],
        cwd=cwd, timeout=timeout,
    )
    if code == 0 and out.strip():
        root = out.strip().splitlines()[0]
        return f"{root}..HEAD"
    # Absolute fallback — empty tree (shows all files as added).
    return "4b825dc642cb6eb9a060e54bf899d69f82cf7256..HEAD"


def fetch_diff_stat(cwd: str, branch: str, timeout: float) -> list[str]:
    """Return `git diff --stat base..HEAD` lines, truncated to the top 30
    files by change size. Resolves the comparison base robustly via
    merge-base, falling back to a safe HEAD range that handles short
    branches without erroring."""
    base = _resolve_diff_base(cwd, branch, timeout)
    if base:
        diff_range = f"{base}..HEAD"
    else:
        # No merge-base — use safe fallback that counts actual commits.
        diff_range = _safe_head_range(cwd, 20, timeout)
        log(f"diff_stat_fallback reason=no_merge_base branch={branch} using={diff_range}")

    code, out, err = run(
        ["git", "diff", "--stat", diff_range],
        cwd=cwd,
        timeout=timeout,
    )
    if code != 0:
        # Primary range failed — try safe fallback.
        fallback_range = _safe_head_range(cwd, 20, timeout)
        if fallback_range != diff_range:
            log(f"git_diff_stat_retry range={diff_range} failed, trying {fallback_range}")
            code, out, err = run(
                ["git", "diff", "--stat", fallback_range],
                cwd=cwd,
                timeout=timeout,
            )
        if code != 0:
            log(f"git_diff_stat_error code={code} range={diff_range} stderr={err.strip()[:200]}")
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


def fetch_product_direction(cwd: str) -> str:
    """Read PRODUCT-DIRECTION.md from the repo root. Returns empty string if missing."""
    path = Path(cwd) / "PRODUCT-DIRECTION.md"
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except Exception as e:
        log(f"product_direction_read_error error={e}")
        return ""


def fetch_known_gaps(cwd: str) -> str:
    """Read the '# Known Gaps' section from trial-notes.md on the current branch.
    Returns the section text or empty string if not found."""
    path = Path(cwd) / "trial-notes.md"
    if not path.exists():
        return ""
    try:
        content = path.read_text(encoding="utf-8")
    except Exception as e:
        log(f"known_gaps_read_error error={e}")
        return ""
    # Extract the Known Gaps section — starts at "# Known Gaps" and ends
    # at the next top-level heading or EOF.
    marker = "# Known Gaps"
    idx = content.find(marker)
    if idx < 0:
        return ""
    section = content[idx:]
    # Find the next "---" or top-level "# " heading that isn't our own.
    lines = section.split("\n")
    result: list[str] = [lines[0]]
    for line in lines[1:]:
        if line.startswith("# ") and not line.startswith("# Known Gaps"):
            break
        if line.strip() == "---":
            break
        result.append(line)
    return "\n".join(result).strip()


# Phrases that mark a proposal as the closed trust-prompt-bootstrap or
# prove-the-loop work. Matched case-insensitively against the combined
# proposal + justification text. Kept specific so real product work
# (e.g. fixing the onboarding AX step, or a genuine trust-related
# security feature) is not caught. The shared theme here is
# "demonstrate the loop" or "bypass Claude Code's folder-trust prompt
# to start new sessions", both of which are closed.
_BLOCKED_PROPOSAL_PHRASES = [
    "supervisor_trusted_terminal",
    "trust prompt",
    "trust-prompt",
    "folder trust",
    "folder-trust",
    "workspace trust",
    "untrusted dir",
    "untrusted director",
    "skip-permissions",
    "prove the loop",
    "prove the dispatch loop",
    "proving the loop",
    "trial harness",
    "reproduce the historical",
    "historical proof",
    "demonstrate the loop",
    "demonstrate the dispatch loop",
    "bootstrap a new session",
    "bootstrap new session",
    "bootstrap new claude",
    "verify the loop end-to-end",
    "verify the loop end to end",
]


def _is_blocked_loop_proof_proposal(text: str) -> bool:
    """True when a dispatch proposal is about proving the loop or bypassing
    Claude Code's folder-trust prompt. Both are closed (see Known Gaps and
    the dispatcher prompt). The loop is already proven for trusted
    sessions; bootstrapping new untrusted sessions is blocked on a Claude
    Code limitation, not a Supervisor gap."""
    low = (text or "").lower()
    return any(phrase in low for phrase in _BLOCKED_PROPOSAL_PHRASES)


# Phrases that mark a proposal as meta-work about the loop's OWN dispatch
# behaviour: detectors for the loop spinning, guards against double
# dispatch, thrash detectors. If the loop notices it is spinning, the
# correct response is to STOP, not to dispatch machinery about spinning.
# Such features can be filed as known gaps for a human to schedule; they
# are never self-dispatched mid-thrash. Kept specific so real product
# work is not caught.
_THRASH_META_PHRASES = [
    "thrash guard",
    "thrash-guard",
    "thrash detector",
    "anti-thrash",
    "double-dispatch",
    "double dispatch",
    "in-flight guard",
    "in-flight dispatch",
    "single-in-flight",
    "spin detector",
    "spin detection",
    "detect when the loop",
    "loop is spinning",
    "loop spinning",
    "stuck-worker detector",
    "stuck worker detector",
    "guard against dispatch",
    "dispatch-loop guard",
    "detector for the loop",
    "machinery about spinning",
]


def _is_thrash_meta_proposal(text: str) -> bool:
    """True when a proposal is meta-work about the loop's own thrashing
    (spin/thrash/double-dispatch detectors). Such proposals are never
    auto-dispatched; the loop stops instead."""
    low = (text or "").lower()
    return any(phrase in low for phrase in _THRASH_META_PHRASES)


def _is_build_existing_proposal(text: str) -> bool:
    """True if the proposal builds/wires a component that ALREADY EXISTS, or
    makes a false "X is not wired/built/missing" claim about one. Mirrors the
    Swift Dispatcher.premiseRejection — the root-cause guard against the loop
    proposing to build ITSELF (Dispatcher, LoopController, triage engine, the
    inject path, the catch-list), the exact self-referential runaway.

    Precise: a build verb must appear in the window just BEFORE the component
    (so "build the CGEventPost-based Dispatcher" is caught) but is skipped when
    a preposition makes the component a modifier ("a test FOR the dispatcher").
    """
    t = (text or "").lower()
    existing = [
        "dispatch loop", "dispatcher", "loopcontroller", "loop controller", "loopconfig",
        "triage engine", "triageengine", "inject path", "injector", "interventionrouter",
        "intervention router", "dispatch engine", "dispatch queue", "self-extender",
        "selfextender", "dispatch hook", "deterministic catch", "deterministiccatch",
        "questionanswerer", "question answerer", "hardcodedrubric",
    ]
    build_verbs = ["build ", "implement ", "wire up ", "wire the ", "stand up ",
                   "introduce ", "create the ", "create a ", "write the ", "design the "]
    prepositions = [" for ", " of ", " to ", " about ", " on ", " with ", " in ", " into "]
    missing_suffixes = [" is not wired", " is not built", " is missing", " does not exist",
                        " doesn't exist", " isn't wired", " is not implemented",
                        " is not yet wired", " is not yet built", " needs to be built",
                        " needs to be wired"]
    for comp in existing:
        idx = t.find(comp)
        if idx < 0:
            continue
        before = t[max(0, idx - 40):idx]
        if any(v in before for v in build_verbs) and not any(p in before for p in prepositions):
            return True
        after = t[idx + len(comp): idx + len(comp) + 18]
        if any(s in after for s in missing_suffixes):
            return True
    return False


def _is_owner_brief_proposal(text: str) -> bool:
    """True when a proposal's job is to rewrite/regenerate the OWNER-BRIEF
    content. The brief is auto-written by write_owner_brief on every
    dispatch, so "rewrite the owner brief" is never actionable work — it is
    loop-managed and would be a self-referential no-op (the dispatcher kept
    proposing it, with the brief's own "next step" being to rewrite itself).
    Fixing the brief-GENERATION code is different and must NOT be caught:
    those proposals reference write_owner_brief / the function / format /
    tests, not "rewrite the brief".
    """
    low = (text or "").lower()
    if "owner brief" not in low and "owner-brief" not in low:
        return False
    # Real engineering on the generator is legitimate — let it through.
    code_work = [
        "write_owner_brief", "function", "the format", "voice rule",
        "unit test", "regression test", "helper", "bug in", "refactor",
    ]
    if any(c in low for c in code_work):
        return False
    rewrite_intent = [
        "rewrite", "regenerate", "re-generate", "refresh", "replace",
        "truthful replacement", "accurate snapshot", "fresh brief",
        "update the owner", "regenerate owner", "rewrite owner", "truthful",
    ]
    return any(v in low for v in rewrite_intent)


# --- Grounding: a proposal cannot name a symbol that does not exist --------
#
# DEFECT 2: the dispatcher repeatedly emitted high-confidence tasks with
# false premises — most starkly "fix the <X> check" where <X> was a symbol
# that DOES NOT EXIST anywhere in the code (a pure hallucination). Grounding
# moves the reality check INTO the hook: before a proposal is dispatched,
# every concrete code symbol it names (snake_case identifier, CamelCase
# type, file.ext) must actually appear in the repo as real code. If any
# named symbol is absent, the premise is fabricated and the proposal is
# discarded — the loop idles instead of dispatching garbage.

# Tokens that look code-shaped but are ordinary words / proper nouns the
# dispatcher uses in prose — never treat these as "must exist" symbols.
_GROUNDING_STOPWORDS = frozenset({
    "claude_code", "product_direction", "owner_brief", "known_gaps",
    "self_watch", "low_confidence_no_action", "high_confidence",
    "no_action", "trial_notes", "product-direction.md", "owner-brief.md",
    "changelog.md", "principles.md", "readme.md", "trial-notes.md",
})

# File extensions whose tokens we treat as path references.
_GROUNDING_FILE_EXTS = ("swift", "py", "json", "md", "sh", "txt", "yaml", "yml", "plist")


def _extract_code_symbols(text: str) -> list[str]:
    """Extract concrete code-symbol-like tokens a proposal claims exist:
    snake_case identifiers, multi-word CamelCase types, and file.ext paths.
    Plain English words and single-capitalized words are NOT symbols."""
    text = text or ""
    syms: set[str] = set()
    # snake_case: at least one underscore joining alphanumerics.
    for m in re.findall(r"[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+", text):
        syms.add(m)
    # CamelCase types: two or more capitalized segments (LoopController).
    for m in re.findall(r"\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b", text):
        syms.add(m)
    # file.ext references (Foo.swift, dispatch_loop_hook.py).
    for m in re.findall(r"\b[\w/.-]+\.(?:" + "|".join(_GROUNDING_FILE_EXTS) + r")\b", text):
        syms.add(m)
    # Backtick-quoted code tokens.
    for m in re.findall(r"`([^`]+)`", text):
        t = m.strip()
        if re.fullmatch(r"[\w./-]+", t) and ("_" in t or "." in t or re.search(r"[a-z][A-Z]", t)):
            syms.add(t)
    return [s for s in syms if s.lower() not in _GROUNDING_STOPWORDS]


# Pathspecs excluded from the symbol search: a symbol mentioned only in
# prose (markdown docs, the owner brief, the changelog, trial notes) or in a
# test fixture is NOT proof it exists as real code. We search code only.
_GROUNDING_EXCLUDES = [
    ":(exclude,glob)**/*.md",
    ":(exclude,glob)**/*test*",
    ":(exclude,glob)**/*Test*",
    ":(exclude,glob)OWNER-BRIEF*",
    ":(exclude,glob)CHANGELOG*",
    ":(exclude,glob)trial-notes*",
]


def _symbol_exists_in_repo(cwd: str, symbol: str, timeout: float) -> bool:
    """True if `symbol` exists as real CODE in the repo. Files are checked
    on disk; identifiers via `git grep -F` over code only (docs, the owner
    brief / changelog / trial-notes, and tests are excluded — a symbol
    mentioned in prose or a test string is not proof it exists)."""
    if symbol.endswith(tuple("." + e for e in _GROUNDING_FILE_EXTS)) or "/" in symbol:
        if (Path(cwd) / symbol).exists():
            return True
        base = symbol.rsplit("/", 1)[-1]
        code, out, _ = run(
            ["git", "grep", "-l", "-F", base, "--"] + _GROUNDING_EXCLUDES,
            cwd=cwd, timeout=timeout,
        )
        if code == 0 and out.strip():
            return True
    code, out, _ = run(
        ["git", "grep", "-I", "-l", "-F", symbol, "--"] + _GROUNDING_EXCLUDES,
        cwd=cwd, timeout=timeout,
    )
    return code == 0 and bool(out.strip())


def _ground_proposal(cwd: str, proposal: str, justification: str, timeout: float) -> tuple[bool, str]:
    """Verify a proposal's premise against the real tree. Returns
    (grounded, reason). Ungrounded = it names a concrete code symbol
    (function/type/file) that does not exist anywhere in the repo. This is
    what makes it IMPOSSIBLE to dispatch "fix <X>" when <X> is a symbol that
    exists nowhere in the code."""
    blob = (proposal or "") + " " + (justification or "")
    symbols = _extract_code_symbols(blob)
    missing = [s for s in symbols if not _symbol_exists_in_repo(cwd, s, timeout)]
    if missing:
        return False, "missing_symbols=" + ",".join(sorted(missing)[:5])
    return True, ""


# --- Repetition breaker helpers -------------------------------------------

_PROPOSAL_STOPWORDS = {
    "the", "and", "for", "this", "that", "with", "from", "into", "next",
    "then", "are", "was", "has", "have", "will", "should", "must", "not",
    "but", "you", "your", "its", "per", "via", "out", "now", "all", "any",
}


def _proposal_tokens(text: str) -> frozenset:
    """Normalized significant-word token set for a proposal. Lowercase,
    alphanumeric words of length >= 3, common stopwords dropped. Used to
    compare two proposals for substantial sameness."""
    words = re.findall(r"[a-z0-9]+", (text or "").lower())
    return frozenset(w for w in words if len(w) >= 3 and w not in _PROPOSAL_STOPWORDS)


def _jaccard(a: frozenset, b: frozenset) -> float:
    """Jaccard similarity of two token sets. 0.0 when both are empty."""
    if not a and not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def _is_repeat_proposal(state: dict, proposal: str, threshold: float) -> bool:
    """True when `proposal` is substantially the same as the last proposal
    this session dispatched (token overlap >= threshold). This catches the
    loop proposing the SAME task twice in a row. It does NOT trip on two
    DIFFERENT tasks, which share few significant words."""
    last = state.get("last_proposal_tokens")
    if not last:
        return False
    return _jaccard(_proposal_tokens(proposal), frozenset(last)) >= threshold


def _remember_proposal(state: dict, proposal: str) -> None:
    """Record the proposal we are about to dispatch, so the next dispatch
    can detect a repeat. Stored as a sorted list (JSON-serializable)."""
    state["last_proposal_tokens"] = sorted(_proposal_tokens(proposal))


def _build_fallback_from_gaps(
    known_gaps: str,
    diff_stat: list[str],
    commits: list[dict[str, str]],
) -> str | None:
    """When the dispatcher returns low confidence, check if Known Gaps has
    actionable work. Returns a fallback dispatch prompt, or None if
    everything is blocked.

    Strategy: scan Known Gaps for items that are NOT blocked on external
    setup (API keys, human presence). If found, build a dispatch prompt
    that points the worker at the most impactful unblocked gap."""

    if not known_gaps:
        return None

    # Skip if all gaps are blocked or struck-through.
    blocked_markers = [
        "blocked on",
        "requires human presence",
        "needs api key",
        "blocked on anthropic_api_key",
        "blocked on external",
        "requires human",
        "need.*api key",
        "calibration sweep",
        "refinement in the",
        "rubric body",
        "evaluate switching",
    ]
    # Parse individual gap items. Each item starts with "- " and may
    # span multiple continuation lines (indented or not starting with "- ").
    # Track the current section header to filter entire blocked sections.
    blocked_sections = ["blocked on external", "calibration gap", "never verified"]
    lines = known_gaps.split("\n")
    items: list[tuple[str, str]] = []  # (section, item_text)
    current_item: list[str] = []
    current_section = ""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("## "):
            current_section = stripped.lower()
            continue
        if stripped.startswith("- "):
            if current_item:
                items.append((current_section, "\n".join(current_item)))
            current_item = [stripped]
        elif current_item and stripped and not stripped.startswith("#"):
            current_item.append(stripped)
    if current_item:
        items.append((current_section, "\n".join(current_item)))

    actionable: list[str] = []
    for section, item in items:
        # Skip items in blocked sections.
        if any(bs in section for bs in blocked_sections):
            continue
        # Skip struck-through items.
        if item.startswith("- ~~"):
            continue
        # Check the FULL item text (not just first line) for blocked markers.
        item_lower = item.lower()
        is_blocked = any(m in item_lower for m in blocked_markers)
        if is_blocked:
            continue
        # Take just the first line for the dispatch prompt.
        first_line = item.split("\n")[0]
        actionable.append(first_line)

    if not actionable:
        return None

    # Build a compact diff summary for context.
    diff_summary = "\n".join(diff_stat[:10]) if diff_stat else "(no diff available)"
    recent_subjects = ", ".join(c.get("subject", "")[:60] for c in commits[:5])

    prompt = (
        "The dispatch loop's primary dispatcher returned low confidence, "
        "but Known Gaps has actionable unblocked work. Pick the most "
        "impactful item from the list below and work on it.\n\n"
        f"## Actionable Known Gaps\n\n"
        + "\n".join(actionable) + "\n\n"
        f"## Recent commits on this branch\n{recent_subjects}\n\n"
        f"## Files changed (diff stat)\n{diff_summary}\n\n"
        "Read PRINCIPLES.md first. Pick the gap that most advances "
        "PRODUCT-DIRECTION.md. Don't duplicate work already in the diff. "
        "Hard-stop: 75 min per PRINCIPLES section 12."
    )
    return prompt


def fetch_source_markers(cwd: str, timeout: float) -> list[str]:
    """Grep for TODO/FIXME in source files. Returns up to 30 lines."""
    code, out, err = run(
        ["grep", "-rn", "-E", "TODO|FIXME", "Sources/"],
        cwd=cwd,
        timeout=timeout,
    )
    if code not in (0, 1):  # 1 = no matches, which is fine
        log(f"source_markers_error code={code} stderr={err.strip()[:120]}")
        return []
    lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
    return lines[:30]


def fetch_commits(cwd: str, branch: str, timeout: float) -> list[dict[str, str]]:
    base = _resolve_diff_base(cwd, branch, timeout)
    if base:
        log_range = f"{base}..HEAD"
    else:
        log_range = _safe_head_range(cwd, 20, timeout)
        log(f"git_log_fallback reason=no_merge_base branch={branch} using={log_range}")

    code, out, err = run(
        ["git", "log", log_range,
         "--pretty=format:%H%x00%s%x00%b%x1E",
         "--no-merges"],
        cwd=cwd,
        timeout=timeout,
    )
    if code != 0:
        # Try safe fallback range.
        fallback = _safe_head_range(cwd, 20, timeout)
        if fallback != log_range:
            code, out, err = run(
                ["git", "log", fallback,
                 "--pretty=format:%H%x00%s%x00%b%x1E",
                 "--no-merges"],
                cwd=cwd, timeout=timeout,
            )
        if code != 0:
            log(f"git_log_error code={code} range={log_range} stderr={err.strip()[:200]}")
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
    product_direction: str = "",
    known_gaps: str = "",
    source_markers: list[str] | None = None,
    self_watch_warnings: list[str] | None = None,
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

    # Product direction — the north star
    lines.append("# PRODUCT-DIRECTION.md (where the project is going)")
    lines.append("")
    if product_direction:
        lines.append(product_direction)
    else:
        lines.append("(not found — no PRODUCT-DIRECTION.md in repo root; reason from PRINCIPLES.md and recent work instead)")
    lines.append("")

    lines.append("# Recent commits on this branch (last 20)")
    if not commits:
        lines.append("(none — either fresh branch, or git fetch failed; treat as 'no commits to follow up on')")
    else:
        for c in commits[:20]:
            lines.append(f"- {c['sha'][:8]} {c['subject']}")
        if len(commits) > 20:
            lines.append(f"(... {len(commits) - 20} older commits omitted)")
    lines.append("")
    lines.append("# Recent files changed on this branch (git diff --stat main..HEAD)")
    if not recent_files_changed:
        lines.append("(none — either fresh branch, or git diff failed)")
    else:
        for fl in recent_files_changed:
            lines.append(fl)
    lines.append("")

    # Known Gaps — the standing work record
    lines.append("# Known Gaps (unfinished, unticketed, or blocked work)")
    lines.append("")
    if known_gaps:
        lines.append(known_gaps)
    else:
        lines.append("(no Known Gaps section found in trial-notes.md)")
    lines.append("")

    lines.append("# Open GitHub issues")
    if not issues:
        lines.append("(empty — this is normal; check Known Gaps and source markers for real remaining work)")
    else:
        for i in issues:
            tag = f" [{', '.join(i['labels'])}]" if i["labels"] else ""
            lines.append(f"## Issue #{i['number']} — {i['title']}{tag}")
            if i["body"]:
                lines.append(i["body"][:600])
            lines.append("")

    # Source-level markers
    lines.append("# Source markers (TODO/FIXME in recently-touched files)")
    if source_markers:
        for m in source_markers:
            lines.append(m)
    else:
        lines.append("(none found)")
    lines.append("")

    # Self-watch warnings (problems the loop detected)
    lines.append("# Self-watch warnings (problems detected by the loop)")
    if self_watch_warnings:
        for w in self_watch_warnings:
            lines.append(f"- {w}")
        lines.append("")
        lines.append("If any warning is actionable by the worker (e.g. rebuild), consider making it the next task. If it needs the owner (e.g. AX permissions), flag requires_human_presence=true.")
    else:
        lines.append("(no problems detected — everything looks healthy)")
    lines.append("")

    lines.append("# Session's last turns (what the worker just did — 'the screen')")
    if not recent_turns:
        lines.append("(no events in window)")
    else:
        for t in recent_turns[-10:]:
            role = t.get("role", "?")
            text = (t.get("text") or "")[:240]
            ts = t.get("ts", "")
            lines.append(f"[{ts}] {role}: {text}")
    lines.append("")

    # Cap PRINCIPLES.md to ~15K chars to stay within DeepSeek's context
    # window. Sections 0-7 are decision-relevant; sections 8-13 are
    # reference material the Dispatcher rarely needs.
    lines.append("# PRINCIPLES.md (key sections — capped at 15K chars)")
    lines.append("")
    lines.append(principles_text[:15000])
    if len(principles_text) > 15000:
        lines.append("\n(... remaining sections omitted for context budget)")
    lines.append("")
    lines.append("# Task")
    lines.append("Call `record_dispatch` exactly once. Choose the single most useful next move that advances the project direction, grounded in the real state of the work. The next_task_proposal you write IS the prompt that gets typed into Claude Code — write it like a senior collaborator giving specific, actionable direction.")
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
    tool call. Retries up to 3 times with exponential backoff on
    transient failures (truncated responses, HTTP errors).
    Returns the parsed tool-call arguments dict, or None."""
    body = {
        "model": cfg["provider_model"],
        "max_tokens": 8192,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "tools": [RECORD_DISPATCH_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "record_dispatch"}},
    }
    data = json.dumps(body).encode("utf-8")

    max_attempts = 3
    for attempt in range(max_attempts):
        req = urllib.request.Request(
            cfg["provider_url"],
            data=data,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {key}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=cfg["provider_timeout_s"]) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            log(f"deepseek_http_error code={e.code} attempt={attempt+1}/{max_attempts} body={(e.read() or b'')[:200]!r}")
            if attempt < max_attempts - 1:
                time.sleep(1.0 * (2 ** attempt))
                continue
            return None
        except Exception as e:
            log(f"deepseek_call_error error={e} attempt={attempt+1}/{max_attempts}")
            if attempt < max_attempts - 1:
                time.sleep(1.0 * (2 ** attempt))
                continue
            return None

        result = _parse_dispatcher_response(raw)
        if result is not None:
            if attempt > 0:
                log(f"deepseek_retry_success attempt={attempt+1}")
            return result

        # Parse failed — retry with backoff if attempts remain.
        if attempt < max_attempts - 1:
            log(f"deepseek_retry attempt={attempt+1}/{max_attempts} reason=parse_failed")
            time.sleep(1.0 * (2 ** attempt))

    return None


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
    self_watch_warnings: list[str] | None = None,
) -> str:
    """Build the SelfExtender user message. IMPORTANT: this message must
    stay compact (~8-12K chars) to leave room for the model's output.
    The Dispatcher's message can be ~60K because it's a broader reasoning
    task; the SelfExtender only needs enough to diagnose a specific
    failure. Cap each section aggressively."""
    lines: list[str] = []
    lines.append("# Failure context")
    lines.append(f"failure_reason: {failure_reason}")
    lines.append(f"session: {session_id}")
    lines.append(f"cwd: {cwd}")
    lines.append(f"branch: {branch}")
    lines.append("")

    # Last 10 commits only (the SelfExtender diagnoses the recent failure,
    # not the full branch history).
    lines.append("# Recent commits (last 10)")
    if not commits:
        lines.append("(none)")
    else:
        for c in commits[:10]:
            lines.append(f"- {c['sha'][:8]} {c['subject']}")
    lines.append("")

    # Diff stat: top 15 files only.
    lines.append("# Files changed (top 15)")
    if not recent_files_changed:
        lines.append("(none)")
    else:
        for fl in recent_files_changed[:15]:
            lines.append(fl)
    lines.append("")

    # Self-watch warnings — these explain WHY the dispatch failed.
    if self_watch_warnings:
        lines.append("# Self-watch warnings")
        for w in self_watch_warnings:
            lines.append(f"- {w}")
        lines.append("")

    # Last 5 transcript turns (not 10 — the SelfExtender needs the
    # immediate context, not the full conversation).
    lines.append("# Recent transcript (last 5 turns)")
    if not recent_turns:
        lines.append("(no events)")
    else:
        for t in recent_turns[-5:]:
            role = t.get("role", "?")
            text = (t.get("text") or "")[:160]
            lines.append(f"[{t.get('ts', '')}] {role}: {text}")
    lines.append("")

    # Hook log: last 50 lines (not 200 — the SelfExtender only needs
    # the recent failure pattern, not the full session history).
    lines.append("# dispatch-loop.log (last 50 lines)")
    log_lines = hook_log_tail.strip().splitlines()
    lines.append("\n".join(log_lines[-50:]) if log_lines else "(empty)")
    lines.append("")

    # PRINCIPLES.md: OMIT entirely. The SelfExtender has its own system
    # prompt with the relevant rules (meta-rule, scope, fix strategies).
    # Including the full ~35K PRINCIPLES.md was consuming the context
    # window and causing finish_reason=length truncation at ~92 bytes.

    lines.append("# Task")
    lines.append("Call `record_self_extend` exactly once. Diagnose the failure and produce a fix prompt. Keep fix_prompt under 300 words and diagnosis under 3 sentences.")
    return "\n".join(lines)


def call_self_extender(
    *,
    key: str,
    cfg: dict[str, Any],
    system_prompt: str,
    user_message: str,
) -> dict[str, Any] | None:
    """Call DeepSeek with the SelfExtender prompt. Same retry mechanics
    as call_dispatcher (3 attempts with exponential backoff)."""
    body = {
        "model": cfg["provider_model"],
        "max_tokens": 8192,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "tools": [RECORD_SELF_EXTEND_TOOL],
        "tool_choice": {"type": "function", "function": {"name": "record_self_extend"}},
    }
    data = json.dumps(body).encode("utf-8")

    max_attempts = 3
    for attempt in range(max_attempts):
        req = urllib.request.Request(
            cfg["provider_url"],
            data=data,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {key}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=cfg["provider_timeout_s"]) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            log(f"self_extender_http_error code={e.code} attempt={attempt+1}/{max_attempts}")
            if attempt < max_attempts - 1:
                time.sleep(1.0 * (2 ** attempt))
                continue
            return None
        except Exception as e:
            log(f"self_extender_call_error error={e} attempt={attempt+1}/{max_attempts}")
            if attempt < max_attempts - 1:
                time.sleep(1.0 * (2 ** attempt))
                continue
            return None

        result = _parse_self_extender_response(raw)
        if result is not None:
            if attempt > 0:
                log(f"self_extender_retry_success attempt={attempt+1}")
            return result

        if attempt < max_attempts - 1:
            log(f"self_extender_retry attempt={attempt+1}/{max_attempts} reason=parse_failed")
            time.sleep(1.0 * (2 ** attempt))

    return None


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
    self_watch_warnings: list[str] | None = None,
) -> None:
    """Invoke the SelfExtender. On high-confidence result, emit_block.
    On low-confidence, retry once with escalation. If still low, inject
    an investigation prompt. Never silent_exit — the loop stays alive.
    Writes owner brief after each successful self-extend."""
    log(f"SELF_EXTEND_START reason={failure_reason}")
    warnings = self_watch_warnings or []

    try:
        se_prompt = load_self_extender_prompt()
    except Exception as e:
        log(f"self_extender_prompt_load_error error={e}")
        silent_exit("no_self_extender_prompt")

    # Read only 50 lines of hook log for the SelfExtender (not 200).
    # The full log consumed too much of DeepSeek's context window,
    # causing finish_reason=length truncation at ~92 bytes.
    hook_log = read_hook_log_tail(50)

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
        self_watch_warnings=warnings,
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
        # v0.7.0: write owner brief after self-extend fix.
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next=f"Self-extend fix: {diagnosis[:200]}",
            needs_owner="",
            loop_doing_next=f"Applying SelfExtender fix: {fix_prompt[:150]}{'...' if len(fix_prompt) > 150 else ''}",
            warnings=warnings,
        )
        prefixed = (
            f"[dispatch-loop-hook v0.7.0 — SelfExtender auto-fix; "
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
        # v0.7.0: write owner brief after retry fix.
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next=f"Self-extend retry fix: {diagnosis[:200]}",
            needs_owner="",
            loop_doing_next=f"Applying SelfExtender retry fix: {fix_prompt[:150]}{'...' if len(fix_prompt) > 150 else ''}",
            warnings=warnings,
        )
        prefixed = (
            f"[dispatch-loop-hook v0.7.0 — SelfExtender retry; "
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
    # v0.7.0: write owner brief on fallback — the owner should know
    # the loop is struggling.
    write_owner_brief(
        cwd=cwd,
        what_shipped=summarize_recent_commits(commits),
        most_valuable_next="The SelfExtender couldn't diagnose the dispatch failure after two attempts.",
        needs_owner="The loop is stuck. Check the dispatch log and decide what to work on next.",
        loop_doing_next="Injecting an investigation prompt as a last resort.",
        warnings=warnings,
    )
    fallback = (
        "[dispatch-loop-hook v0.7.0 — SelfExtender fallback; "
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
# Owner Brief (Capability 1 — talk UP to the owner)
# ----------------------------------------------------------------------

def write_owner_brief(
    *,
    cwd: str,
    what_shipped: str,
    most_valuable_next: str,
    needs_owner: str,
    loop_doing_next: str,
    warnings: list[str],
) -> None:
    """Write OWNER-BRIEF.md — a plain-language update for the project
    owner. Updated after each dispatch cycle. The voice is an advisor
    talking to the person who owns the project, not an engineer
    talking to another engineer."""
    lines: list[str] = []
    lines.append("# Owner Brief")
    lines.append("")
    lines.append(f"Last updated: {_ts()}")
    lines.append("")

    lines.append("## What shipped recently")
    lines.append("")
    lines.append(what_shipped if what_shipped else "Nothing new since the last brief.")
    lines.append("")

    lines.append("## Most valuable thing remaining")
    lines.append("")
    lines.append(most_valuable_next if most_valuable_next else "The loop couldn't identify a clear next priority.")
    lines.append("")

    if needs_owner:
        lines.append("## Needs your attention")
        lines.append("")
        lines.append(needs_owner)
        lines.append("")

    if warnings:
        lines.append("## Warnings")
        lines.append("")
        for w in warnings:
            lines.append(f"- {w}")
        lines.append("")

    lines.append("## What the loop is doing next")
    lines.append("")
    lines.append(loop_doing_next if loop_doing_next else "Waiting for direction.")
    lines.append("")

    brief_path = Path(cwd) / "OWNER-BRIEF.md"
    try:
        brief_path.write_text("\n".join(lines), encoding="utf-8")
        log(f"OWNER_BRIEF_WRITTEN path={brief_path}")
    except Exception as e:
        log(f"OWNER_BRIEF_ERROR error={e}")


def summarize_recent_commits(commits: list[dict[str, str]], limit: int = 10) -> str:
    """Plain-language summary of recent commits for the owner brief."""
    if not commits:
        return "No new commits on this branch."
    recent = commits[:limit]
    lines = []
    for c in recent:
        # Strip Co-Authored-By and other noise from subjects
        subject = c["subject"].strip()
        if subject:
            lines.append(f"- {subject}")
    if not lines:
        return "No new commits on this branch."
    return "\n".join(lines)


# ----------------------------------------------------------------------
# Self-Watch (Capability 2 — catch mismatches, fix them)
# ----------------------------------------------------------------------

def _newest_swift_mtime(cwd: str, rel_path: str) -> float:
    """Newest mtime among .swift files under rel_path (a file or directory),
    resolved relative to cwd. 0.0 if nothing resolves."""
    p = Path(cwd) / rel_path
    try:
        if p.is_file():
            return p.stat().st_mtime
        if p.is_dir():
            newest = 0.0
            for f in p.rglob("*.swift"):
                try:
                    newest = max(newest, f.stat().st_mtime)
                except Exception:
                    pass
            return newest
    except Exception:
        pass
    return 0.0


def detect_stale_build(cwd: str, timeout: float) -> tuple[str | None, float]:
    """Detect when UI source files were EDITED more recently than the
    deployed Supervisor.app was built, so the running app can't reflect
    them.

    Compares the deployed bundle's mtime to the newest UI SOURCE FILE
    mtime, NOT to git commit times. The normal workflow is build-then-
    commit, so a commit timestamp is ALWAYS newer than the binary even when
    the binary was built from that exact code — using commit time produced
    a guaranteed false "stale build" after every commit, which kept
    dispatching pointless rebuilds. File mtimes only move when a file is
    actually edited, so newest_src > app_mtime means a real post-build edit.

    Returns (warning, newest_src_mtime) for dedup, or (None, 0)."""
    app_path = "/Applications/Supervisor.app/Contents/Info.plist"
    if not Path(app_path).exists():
        return None, 0

    try:
        app_mtime = Path(app_path).stat().st_mtime
    except Exception:
        return None, 0

    ui_paths = [
        "Sources/SupervisorUI/",
        "Sources/SupervisorCore/Intervention/Notifier.swift",
        "Sources/SupervisorCore/Hover/HoverViewModel.swift",
    ]
    newest_src = 0.0
    for ui_path in ui_paths:
        newest_src = max(newest_src, _newest_swift_mtime(cwd, ui_path))

    # Only warn on positive evidence: a UI source file is genuinely newer
    # than the deployed app (edited after the last build/deploy). The
    # `timeout` arg is retained for signature compatibility (git no longer
    # consulted here).
    _ = timeout
    if newest_src > 0 and newest_src > app_mtime:
        return (
            "The running Supervisor app is older than recent code changes "
            "to the hover label, notifications, or UI. The new wording "
            "won't be visible until you rebuild and relaunch. "
            "Run build-app.sh and do the atomic swap to /Applications."
        ), newest_src
    return None, 0


def detect_suspicious_stop(
    recent_turns: list[dict[str, Any]],
    known_gaps: str,
    result: dict[str, Any] | None,
) -> str | None:
    """Detect a suspicious stop — the worker went quiet but the work
    looks incomplete. Returns a plain warning or None."""
    if not recent_turns:
        return None

    last_text = ""
    for t in reversed(recent_turns):
        if t.get("role") == "assistant":
            last_text = t.get("text", "")
            break

    if not last_text:
        return None

    lower = last_text.lower()
    # Patterns that suggest the worker stopped in a bad state
    stuck_signals = [
        "error:",
        "failed to",
        "cannot find",
        "compilation error",
        "build failed",
        "test failed",
        "i'm stuck",
        "i need help",
        "unable to",
    ]

    for signal in stuck_signals:
        if signal in lower:
            # Check if the worker acknowledged the error and moved on,
            # or if it just stopped
            resolution_signals = ["fixed", "resolved", "working now", "pass", "succeeded"]
            resolved = any(r in lower for r in resolution_signals)
            if not resolved:
                return (
                    f"The worker stopped after mentioning '{signal}' without "
                    f"indicating the issue was resolved. The last message may "
                    f"indicate a stuck or failed state worth investigating."
                )

    # Check if the dispatcher returned low confidence on an empty queue
    # but known gaps exist — this suggests the loop is stalling
    if result and (result.get("confidence") or "").lower() == "low" and known_gaps:
        return (
            "The Dispatcher returned low confidence even though Known Gaps "
            "lists actionable work. The loop may be stalling. Check if "
            "the gaps are actually blocked or if the Dispatcher needs "
            "better context."
        )

    return None


def detect_ineffective_change(
    cwd: str,
    commits: list[dict[str, str]],
    recent_files_changed: list[str],
) -> str | None:
    """Detect when recent commits changed UI-facing code (notification
    text, hover labels) but the running app can't reflect them without
    a rebuild. Similar to stale_build but focused on recent-session
    commits specifically."""
    if not commits:
        return None

    # Check if recent commits touched notification/hover code
    ui_file_patterns = ["Notifier.swift", "HoverViewModel.swift", "HoverView.swift"]
    ui_files_touched = []
    for f in recent_files_changed:
        for pat in ui_file_patterns:
            if pat in f:
                ui_files_touched.append(pat)

    if ui_files_touched:
        app_bin = Path("/Applications/Supervisor.app/Contents/MacOS/Supervisor")
        if app_bin.exists():
            # Only a real problem if the deployed binary is OLDER than the
            # UI source it would need to reflect. If we rebuilt and
            # redeployed after editing those files, the app already shows
            # the change. The previous version fired unconditionally
            # whenever a UI file appeared in the diff, so it stayed lit
            # even right after a deploy (a permanent false positive that
            # made the owner brief cry wolf).
            app_mtime = app_bin.stat().st_mtime
            newest_src = 0.0
            for f in recent_files_changed:
                if any(pat in f for pat in ui_file_patterns):
                    # recent_files_changed entries are `git diff --stat`
                    # lines like "Sources/.../HoverViewModel.swift | 45 +++".
                    # The stat column must be stripped before resolving, or
                    # Path(cwd)/f never exists, newest_src stays 0, and the
                    # freshness guard below is silently bypassed — which made
                    # this warning fire even when the binary was already
                    # newer than the source (the exact false positive that
                    # dispatched a pointless rebuild).
                    path_part = f.rsplit("|", 1)[0].strip()
                    if "=>" in path_part:                # rename: "old => new"
                        path_part = path_part.split("=>")[-1].strip().rstrip("} ")
                    p = Path(cwd) / path_part
                    if p.exists():
                        newest_src = max(newest_src, p.stat().st_mtime)
            # Warn ONLY on positive evidence: a resolved source file is newer
            # than the deployed binary. If no source mtime resolved
            # (newest_src == 0) we cannot claim staleness, so stay quiet
            # rather than cry wolf.
            if newest_src == 0.0 or app_mtime >= newest_src:
                return None  # deployed build is at least as new as the source
            return (
                f"This session changed {', '.join(set(ui_files_touched))} "
                f"but the installed Supervisor.app is older than those edits. "
                f"The new hover labels and notification wording won't appear "
                f"until the app is rebuilt and relaunched."
            )
    return None


def run_self_watch_pre_dispatch(
    *,
    cwd: str,
    recent_turns: list[dict[str, Any]],
    commits: list[dict[str, str]],
    recent_files_changed: list[str],
    timeout: float,
    state: dict[str, Any],
) -> list[str]:
    """Run self-watch checks that don't depend on the dispatch result.
    Called BEFORE the dispatcher so warnings flow into its context.
    Uses state-based deduplication: once a warning is surfaced in
    the owner brief, it's recorded in state. Subsequent cycles with
    the same underlying condition skip the warning to avoid noise.
    The warning re-fires when the condition changes (new commit) or
    resolves (app rebuilt)."""
    warnings: list[str] = []
    surfaced = state.get("surfaced_warnings") or {}

    stale_warning, stale_commit_time = detect_stale_build(cwd, timeout)
    if stale_warning:
        # Only surface if this is a NEW staleness (different commit time
        # than what we already surfaced). If the same commit time was
        # already surfaced, the owner already knows — don't repeat.
        last_surfaced_time = surfaced.get("stale_build_commit_time", 0)
        if stale_commit_time != last_surfaced_time:
            warnings.append(stale_warning)
            surfaced["stale_build_commit_time"] = stale_commit_time
            log(f"SELF_WATCH stale_build detected (new, commit_time={stale_commit_time})")
        else:
            log(f"SELF_WATCH stale_build still present but already surfaced (commit_time={stale_commit_time})")
    else:
        # Condition resolved (app rebuilt or no app installed) — clear.
        if "stale_build_commit_time" in surfaced:
            del surfaced["stale_build_commit_time"]
            log("SELF_WATCH stale_build resolved")

    ineffective = detect_ineffective_change(cwd, commits, recent_files_changed)
    if ineffective:
        # Ineffective-change is session-scoped (tied to recent commits),
        # so it only fires when recent commits touch UI files. Dedup by
        # the set of touched files.
        touched_key = str(sorted(set(
            p for p in ["Notifier.swift", "HoverViewModel.swift", "HoverView.swift"]
            if any(p in f for f in recent_files_changed)
        )))
        last_surfaced_key = surfaced.get("ineffective_change_key", "")
        if touched_key != last_surfaced_key:
            warnings.append(ineffective)
            surfaced["ineffective_change_key"] = touched_key
            log(f"SELF_WATCH ineffective_change detected (new)")
        else:
            log(f"SELF_WATCH ineffective_change still present but already surfaced")
    else:
        if "ineffective_change_key" in surfaced:
            del surfaced["ineffective_change_key"]

    state["surfaced_warnings"] = surfaced
    return warnings


def run_self_watch_post_dispatch(
    *,
    recent_turns: list[dict[str, Any]],
    known_gaps: str,
    result: dict[str, Any] | None,
) -> list[str]:
    """Run self-watch checks that depend on the dispatch result.
    Called AFTER the dispatcher, before acting on the result."""
    warnings: list[str] = []

    suspicious = detect_suspicious_stop(recent_turns, known_gaps, result)
    if suspicious:
        warnings.append(suspicious)
        log(f"SELF_WATCH suspicious_stop detected")

    return warnings


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

    # Gate: cwd must be within the supervisor repo (or whatever's configured).
    if not cwd.startswith(cfg["supervisor_repo_path"]):
        silent_exit(f"cwd_not_supervisor cwd={cwd}")

    # Pin to the repo ROOT regardless of which subdirectory the session
    # started in. Without this, a session launched from a subdir (e.g.
    # Tools/dispatch-loop-hook) greps Sources/ in the wrong place and writes
    # OWNER-BRIEF.md into the subdir. All canonical reads/writes below use
    # this resolved root.
    resolved_root = resolve_repo_root(cwd, cfg["supervisor_repo_path"])
    if resolved_root != cwd:
        log(f"repo_root_pinned from={cwd} to={resolved_root}")
        cwd = resolved_root

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

    # Fresh-session reset on resume after a long idle gap (apply_idle_reset /
    # DEFAULTS["session_reset_idle_s"]). Runs BEFORE the sticky-stopped check
    # so an overnight pause un-sticks a four_hours_elapsed stop. Persisted
    # immediately so last_seen_at survives the early-exit paths below.
    last_seen = state.get("last_seen_at")
    was_stopped = bool(state.get("stopped"))
    if apply_idle_reset(state, now_s, cfg["session_reset_idle_s"]):
        log(f"session_reset_after_idle session={session_id} "
            f"idle_gap_s={int(now_s - last_seen)} "
            f"threshold_s={int(cfg['session_reset_idle_s'])} "
            f"was_stopped={was_stopped}")
    put_session_state(state_all, session_id, state)
    save_state(state_all)

    if state.get("stopped"):
        silent_exit(f"loop_already_stopped reason={state.get('stop_reason')}")

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

    # Read PRODUCT-DIRECTION.md (the north star).
    product_direction = fetch_product_direction(cwd)

    # Read Known Gaps from trial-notes.md.
    known_gaps = fetch_known_gaps(cwd)

    # Fetch dispatch context.
    issues = fetch_issues(cwd, cfg["issue_fetch_timeout_s"])
    commits = fetch_commits(cwd, branch, cfg["git_log_timeout_s"])
    diff_stat = fetch_diff_stat(cwd, branch, cfg["git_log_timeout_s"])
    source_markers = fetch_source_markers(cwd, cfg["git_log_timeout_s"])
    prior_count = state.get("total_dispatches", 0)

    log(f"DISPATCH_PREPARE session={session_id} worker_idle_signal=no_tool_use "
        f"prior={prior_count} issues={len(issues)} commits={len(commits)} "
        f"gaps={len(known_gaps)} markers={len(source_markers)} "
        f"direction={'yes' if product_direction else 'no'}")

    # Read API key from the user's configured provider.
    key = read_keychain(cfg["keychain_service"], cfg["keychain_account"])
    if not key:
        silent_exit(f"no_provider_key service={cfg['keychain_service']}")

    # The Python hook uses the OpenAI-compatible chat.completions shape.
    # If the user's active provider is Anthropic (which uses a different
    # wire format), the Swift app handles dispatch natively — the hook
    # gates out. This only matters if someone configures Anthropic as
    # active provider; all other providers (DeepSeek, Moonshot, MiniMax,
    # Qwen) use the OpenAI-compatible shape the hook already speaks.
    if cfg.get("api_shape") == "anthropic":
        silent_exit("provider_is_anthropic_use_swift_app")

    # v0.7.0: run pre-dispatch self-watch (stale build, ineffective change).
    # These warnings flow into the dispatcher's context so it can act on them.
    pre_warnings = run_self_watch_pre_dispatch(
        cwd=cwd, recent_turns=recent_turns,
        commits=commits, recent_files_changed=diff_stat,
        timeout=cfg["git_log_timeout_s"],
        state=state,
    )
    # Save state after pre-dispatch so dedup keys persist.
    put_session_state(state_all, session_id, state)
    save_state(state_all)

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
        product_direction=product_direction,
        known_gaps=known_gaps,
        source_markers=source_markers,
        self_watch_warnings=pre_warnings,
    )
    log(f"DISPATCH_CALL user_message_bytes={len(user_message.encode('utf-8'))}")

    # v0.8.0: call_dispatcher handles retries internally (3 attempts
    # with exponential backoff). The old v0.4.1 single-retry in main()
    # is removed — the built-in retry is more robust.
    result = call_dispatcher(
        key=key, cfg=cfg,
        system_prompt=system_prompt,
        user_message=user_message,
    )

    # Update state regardless of result, then act.
    state["total_dispatches"] = state.get("total_dispatches", 0) + 1

    # v0.7.0: common kwargs for SelfExtender invocation.
    # pre_warnings (stale build, ineffective change) are available now;
    # post_warnings (suspicious stop) come after the result is known.
    # The SelfExtender gets pre_warnings immediately; the combined set
    # flows into the owner brief downstream.
    se_kwargs = dict(
        key=key, cfg=cfg, session_id=session_id, cwd=cwd, branch=branch,
        recent_turns=recent_turns, commits=commits, recent_files_changed=diff_stat,
        principles_text=principles_text, state=state, state_all=state_all,
        self_watch_warnings=pre_warnings,
    )

    if not result:
        # The dispatcher returned no parseable result. This is a REAL
        # failure (network error, malformed JSON, stuck call), not an idle
        # state, so the SelfExtender is the correct response: fix the
        # machinery, do not invent new product work. This is the ONLY path
        # that invokes the SelfExtender. Empty queue and low confidence are
        # handled below as normal terminal states, never as breakage.
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

    # Post-dispatch self-watch (suspicious stop — needs the result). Computed
    # here, before any branch below references it, so the blocked-proposal
    # branch can no longer raise UnboundLocalError on self_watch_warnings.
    post_warnings = run_self_watch_post_dispatch(
        recent_turns=recent_turns,
        known_gaps=known_gaps,
        result=result,
    )
    self_watch_warnings = pre_warnings + post_warnings

    # Guard: never dispatch a closed/meta/self-referential proposal.
    #   - trust-prompt-bootstrap / prove-the-loop: blocked on a Claude Code
    #     limitation; the loop is already proven for trusted sessions.
    #   - thrash meta-work (spin/thrash/double-dispatch detectors): if the
    #     loop notices it is spinning, the response is to STOP, not to build
    #     machinery about spinning. Such features are filed as known gaps
    #     for a human to schedule, never self-dispatched mid-thrash.
    #   - owner-brief rewrite: the brief is auto-written every dispatch, so
    #     "rewrite the owner brief" is a self-referential no-op, never a task.
    # Either way: surface once in the owner brief and stop. No SelfExtender.
    blob = proposal + " " + justification
    if (_is_blocked_loop_proof_proposal(blob)
            or _is_thrash_meta_proposal(blob)
            or _is_owner_brief_proposal(blob)
            or _is_build_existing_proposal(blob)):
        if _is_thrash_meta_proposal(blob):
            reason = "thrash_meta"
        elif _is_owner_brief_proposal(blob):
            reason = "owner_brief_rewrite"
        elif _is_build_existing_proposal(blob):
            reason = "build_existing_machinery"
        else:
            reason = "trust_prompt_or_prove_loop"
        log(f"BLOCKED_PROPOSAL_FILTERED reason={reason} just=\"{justification[:120]}\"")
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next="Skipped a closed or self-referential proposal (proving the loop, the trust prompt, machinery about the loop's own thrashing, or rewriting this brief). That work is not auto-dispatched.",
            needs_owner="",
            loop_doing_next="Idle. Skipped a closed/meta proposal. Waiting for real queued work.",
            warnings=self_watch_warnings,
        )
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit(f"blocked_proposal_filtered reason={reason}")

    # v0.4.1-hook: requires_human_presence gate. The dispatcher says this
    # task needs a human, so we surface it and stop. Terminal, not a
    # failure, so no SelfExtender.
    if requires_human:
        log(f"HUMAN_GATE skipping proposal, not counting as low")
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next=proposal[:300] if proposal else justification[:300],
            needs_owner=f"This task needs you at the keyboard: {justification}",
            loop_doing_next="Skipped human-required task; idle until you take it or queue other work.",
            warnings=self_watch_warnings,
        )
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit(f"GATE_FAIL reason=requires_human_presence path={selected_path}")

    actionable = selected_path != "low_confidence_no_action" and bool(proposal)

    if confidence == "high" and actionable:
        # Repetition breaker: if this is substantially the SAME task the
        # loop dispatched last time, that is real thrashing on one thing.
        # Stop with a calm idle brief instead of dispatching it again. Two
        # genuinely DIFFERENT tasks share few significant words and do not
        # trip this, so legitimate multi-task work keeps flowing.
        if _is_repeat_proposal(state, proposal, cfg["same_proposal_jaccard_threshold"]):
            log("CIRCUIT_BREAKER reason=repeated_proposal")
            write_owner_brief(
                cwd=cwd,
                what_shipped=summarize_recent_commits(commits),
                most_valuable_next="The loop proposed the same task twice in a row, so it stopped instead of spinning on one thing. Give it a new direction or add new items to the queue.",
                needs_owner="The loop is repeating itself. It needs a new direction or a refilled queue.",
                loop_doing_next="Stopped: repeated the same proposal. Idle until there is new direction.",
                warnings=self_watch_warnings,
            )
            state["consecutive_low"] = 0
            put_session_state(state_all, session_id, state)
            save_state(state_all)
            silent_exit("breaker_repeated_proposal")

        # Grounding (DEFECT 2): a proposal may not name a code symbol that
        # does not exist. The dispatcher repeatedly fabricated work (e.g.
        # "fix the <X> check" naming a symbol that exists nowhere). Verify
        # every concrete symbol/file the proposal names actually appears in
        # the tree as code; if any is missing, the premise is hallucinated —
        # discard and idle, never dispatch. "no work" is the correct,
        # confident answer here.
        grounded, gr_reason = _ground_proposal(
            cwd, proposal, justification, cfg["git_log_timeout_s"]
        )
        if not grounded:
            log(f"UNGROUNDED_PROPOSAL {gr_reason} just=\"{justification[:120]}\"")
            write_owner_brief(
                cwd=cwd,
                what_shipped=summarize_recent_commits(commits),
                most_valuable_next="The dispatcher proposed work referencing something that does not exist in the code (a fabricated premise). It was discarded. The queue is effectively empty; add real direction.",
                needs_owner="Loop idle: the dispatcher fabricated a task. Add real queued work or leave it idle.",
                loop_doing_next="Idle. Discarded an ungrounded proposal (named a symbol that does not exist). Waiting for direction.",
                warnings=self_watch_warnings,
            )
            state["consecutive_low"] = 0
            put_session_state(state_all, session_id, state)
            save_state(state_all)
            silent_exit(f"ungrounded_proposal {gr_reason}")

        # Genuine new actionable work. Remember it (for next-dispatch repeat
        # detection) and dispatch.
        state["consecutive_low"] = 0
        _remember_proposal(state, proposal)
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next=justification[:300],
            needs_owner="",
            loop_doing_next=f"Dispatching now: {proposal[:200]}{'...' if len(proposal) > 200 else ''}",
            warnings=self_watch_warnings,
        )
        prefixed = (
            "[dispatch-loop-hook v0.9.0 — auto-dispatched by Stop hook; "
            f"justification: {justification.strip()}]\n\n{proposal.strip()}"
        )
        emit_block(prefixed)

    elif confidence == "medium" and actionable:
        # Propose-and-wait: medium confidence surfaces a proposal for the
        # owner but does NOT auto-dispatch. Terminal, not escalation.
        log("PROPOSE_AND_WAIT confidence=medium")
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next=proposal[:300],
            needs_owner=f"The loop has a medium-confidence proposal waiting for your call: {justification}",
            loop_doing_next="Holding a medium-confidence proposal for your decision. Not auto-dispatching.",
            warnings=self_watch_warnings,
        )
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        silent_exit("propose_and_wait_medium")

    else:
        # EMPTY QUEUE / LOW CONFIDENCE is a valid TERMINAL state, not a
        # failure. The loop stops calmly. It does NOT escalate to the
        # SelfExtender (that is only for real machinery breakage) and it
        # does NOT second-guess the dispatcher with a gaps-fallback (the
        # dispatcher already read the gaps). Stopping here with no
        # emit_block breaks the thrash chain: nothing re-triggers the Stop
        # hook, so an empty queue produces calm idle, not a dispatch storm.
        log(f"IDLE_TERMINAL reason=no_queued_work confidence={confidence} path={selected_path}")
        state["consecutive_low"] = 0
        put_session_state(state_all, session_id, state)
        save_state(state_all)
        write_owner_brief(
            cwd=cwd,
            what_shipped=summarize_recent_commits(commits),
            most_valuable_next="No queued work the loop can act on right now.",
            needs_owner="Loop idle, waiting for direction. Add items to the issue queue or tell the loop what to work on.",
            loop_doing_next="Idle. No actionable unblocked work. Waiting for direction.",
            warnings=self_watch_warnings,
        )
        silent_exit("idle_no_work")


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
