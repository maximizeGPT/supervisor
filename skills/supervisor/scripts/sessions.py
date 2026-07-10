#!/usr/bin/env python3
"""sessions.py - list agent sessions active in the last N hours.

Part of the Supervisor skill (skills/supervisor). Read-only: it scans
Claude Code transcripts (~/.claude/projects/<slug>/<session-id>.jsonl)
and, when present, OpenAI Codex CLI rollouts
(~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl), then prints one row per
recently-active session so a supervising agent can decide which
transcript to tail next.

Usage:
    python3 sessions.py                    # table, active in last 24h
    python3 sessions.py --hours 6          # narrower window
    python3 sessions.py --json             # machine-readable output
    python3 sessions.py --projects-dir P   # override ~/.claude/projects
    python3 sessions.py --codex-dir P      # override ~/.codex/sessions
    python3 sessions.py --no-codex         # Claude Code sessions only

Ported from (paths relative to the supervisor repo root):
  - Sources/SupervisorCore/Observation/SessionDiscovery.swift:
    mtime is the last-activity proxy; recency-window filtering.
  - Sources/SupervisorCore/Observation/EventParser.swift: record shapes;
    the real cwd comes from the first record that carries one (the slug
    is NOT decoded when a cwd is available, see below); sidechain and
    machine-generated user turns are not treated as owner prompts.
  - Sources/SupervisorCore/AgentAdapter/CodexRolloutSource.swift +
    CodexRolloutParser.swift: rollout filename -> session id (the uuid
    is the LAST five hyphen groups of the stem), session_meta -> cwd,
    event_msg user_message/agent_message, response_item function_call.
  - Sources/SupervisorCore/Triage/TriagePrompt.swift
    (looksLikeQuestionToUser): the open-question heuristic.

Slug decoding is LOSSY: Claude Code builds the directory slug by
replacing "/" and "." with "-", so "-Users-x-my-app" could be
/Users/x/my-app or /Users/x/my/app. This script therefore reads the cwd
out of the transcript itself and only falls back to the naive decode
(marked "~lossy" in the table, "slug-decode-lossy" in JSON) when no
record carries a cwd.

If CLAUDE_SESSION_ID is set (Claude Code sets it in hook and tool
contexts), that session is excluded: do not supervise yourself.

Python 3.9+ stdlib only. Never writes anything.
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Redaction.
#
# Duplicated in tail_session.py ON PURPOSE: the skill's scripts are
# self-contained with no cross-script imports (per the skill design brief).
# If you change a pattern here, change it in tail_session.py too.
#
# Ported from Sources/SupervisorCore/Redact/Patterns.swift + Redactor.swift
# (release/v0.3.0-rc line): fixed "<redacted:type>" placeholders, patterns
# applied in the declared order, idempotent (re-redacting a redacted string
# is a no-op; the env-secret rule carries an explicit (?!<redacted) guard).
# Fail closed: any internal error withholds the content entirely.
# ---------------------------------------------------------------------------

_AWS_KEY_RE = re.compile(r"\bAKIA[0-9A-Z]{16}\b")
_AWS_SECRET_RE = re.compile(r"[A-Za-z0-9/+=]{40}")

# (kind, spec, placeholder); kind is "regex" (whole match replaced),
# "group" (spec is (pattern, group index), only the group replaced), or
# "aws" (AKIA id + paired 40-char secret within 200 chars forward).
_REDACTION_PATTERNS = [
    ("regex", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
     "<redacted:private-key>"),
    ("regex", re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"), "<redacted:anthropic-key>"),
    ("aws", None, "<redacted:aws-credential>"),
    ("group", (re.compile(r"(?i)\b(aws_secret_access_key\s*[=:]\s*[\"']?)([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"), 2),
     "<redacted:aws-credential>"),
    ("regex", re.compile(r"\bghp_[A-Za-z0-9]{36}\b"), "<redacted:github-token>"),
    ("regex", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{82}\b"), "<redacted:github-token>"),
    ("regex", re.compile(r"\bgho_[A-Za-z0-9]{36}\b"), "<redacted:github-token>"),
    ("regex", re.compile(r"\b(?:ghs|ghr|ghu)_[A-Za-z0-9]{36,}\b"), "<redacted:github-token>"),
    ("regex", re.compile(r"\bglpat-[A-Za-z0-9_\-]{20,}"), "<redacted:gitlab-token>"),
    ("regex", re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), "<redacted:npm-token>"),
    ("regex", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}"), "<redacted:google-api-key>"),
    ("regex", re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"), "<redacted:slack-token>"),
    ("regex", re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"), "<redacted:stripe-key>"),
    ("regex", re.compile(r"\bwhsec_[A-Za-z0-9]{16,}"), "<redacted:stripe-webhook-secret>"),
    ("regex", re.compile(r"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"), "<redacted:sendgrid-key>"),
    ("regex", re.compile(r"\b(?:AC|SK)[a-f0-9]{32}\b"), "<redacted:twilio-key>"),
    ("regex", re.compile(r"\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b"),
     "<redacted:jwt>"),
    ("regex", re.compile(r"\bsk-(?!ant-)[A-Za-z0-9_\-]{32,}"), "<redacted:api-key>"),
    ("group", (re.compile(r"(?i)(https?://)([^/\s:@\"\\\\]+:[^/\s@\"\\\\]+)@"), 2),
     "<redacted:url-credentials>"),
    ("group", (re.compile(r"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|rediss?|amqps?)://[^/\s:@\"\\\\]+:([^/\s@\"\\\\]+)@"), 1),
     "<redacted:url-credentials>"),
    ("group", (re.compile(r"(?i)([?&](?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|token|password|passwd|pwd)=)([^&\s#\"\\\\]+)"), 2),
     "<redacted:url-credentials>"),
    ("group", (re.compile(r"(?m)^(\s*export\s+[A-Za-z_][A-Za-z0-9_]*=)(\S+)"), 2), "<redacted>"),
    ("group", (re.compile(r"(?im)^(\s*[A-Z0-9_]*(?:SECRET|TOKEN|KEY|PASSWORD|PASSWD|APIKEY)[A-Z0-9_]*\s*[=:]\s*)(?!<redacted)(\S+)"), 2),
     "<redacted:env-secret>"),
]


def _replace_group(pattern, group, placeholder, text):
    """Replace only the given capture group of every match, applied from the
    last match to the first so earlier spans stay valid (port of
    Redactor.replaceCaptureGroup)."""
    out = text
    for m in reversed(list(pattern.finditer(text))):
        start, end = m.span(group)
        if start < 0:
            continue
        out = out[:start] + placeholder + out[end:]
    return out


def _replace_aws_pair(placeholder, text):
    """AKIA access-key id plus a paired 40-char secret within 200 chars
    forward; both replaced (port of Redactor.replaceAWSPair)."""
    matches = list(_AWS_KEY_RE.finditer(text))
    if not matches:
        return text
    spans = set()
    for m in matches:
        spans.add(m.span())
        window = text[m.end():m.end() + 200]
        sm = _AWS_SECRET_RE.search(window)
        if sm:
            spans.add((m.end() + sm.start(), m.end() + sm.end()))
    out = text
    for start, end in sorted(spans, reverse=True):
        out = out[:start] + placeholder + out[end:]
    return out


def redact(text):
    """Apply every pattern in declared order. Idempotent. Fail closed."""
    if not text:
        return text
    try:
        out = text
        for kind, spec, placeholder in _REDACTION_PATTERNS:
            if kind == "regex":
                out = spec.sub(placeholder, out)
            elif kind == "group":
                pattern, group = spec
                out = _replace_group(pattern, group, placeholder, out)
            else:
                out = _replace_aws_pair(placeholder, out)
        return out
    except Exception:
        return "<redaction-error: content withheld>"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def parse_iso_ts(raw):
    """Parse the ISO-8601 timestamps Claude Code / Codex write (with or
    without fractional seconds, Z suffix). Returns aware datetime or None."""
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(s)
    except ValueError:
        s2 = re.sub(r"\.\d+", "", s)
        try:
            return datetime.datetime.fromisoformat(s2)
        except ValueError:
            return None


def age_str(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


def read_tail_lines(path, max_bytes=262144):
    """Read the last max_bytes of a file and return its complete lines
    (drops the first, possibly partial, line when the read is offset)."""
    size = path.stat().st_size
    with open(path, "rb") as f:
        offset = max(0, size - max_bytes)
        f.seek(offset)
        data = f.read()
    text = data.decode("utf-8", errors="replace")
    lines = text.split("\n")
    if offset > 0 and lines:
        lines = lines[1:]
    return [ln for ln in lines if ln.strip()]


def read_head_lines(path, max_lines=100, max_bytes=524288):
    lines = []
    with open(path, "rb") as f:
        data = f.read(max_bytes)
    for ln in data.decode("utf-8", errors="replace").split("\n"):
        if ln.strip():
            lines.append(ln)
        if len(lines) >= max_lines:
            break
    return lines


def count_bytes(path, needles):
    """Count occurrences of each needle (bytes) in the file. Inside JSON
    string values a '\"' is escaped, so an unescaped '\"type\":\"user\"'
    can only appear as JSON structure; the count is a good approximation."""
    counts = {n: 0 for n in needles}
    with open(path, "rb") as f:
        while True:
            chunk = f.read(4 * 1024 * 1024)
            if not chunk:
                break
            for n in needles:
                counts[n] += chunk.count(n)
    return counts


# Port of TriagePrompt.looksLikeQuestionToUser (high recall on purpose).
_QUESTION_PHRASES = [
    "should i ", "do you want", "would you prefer", "let me know",
    "tell me how", "shall i ", "could you confirm", "want me to ",
    "ok to ", "okay to ", "any preference",
]


def looks_like_question(text):
    if "?" in text:
        return True
    lower = text.lower()
    return any(p in lower for p in _QUESTION_PHRASES)


# Port of EventParser.isMachineGeneratedUserText.
_MACHINE_PREFIXES = (
    "<command-name>",
    "<command-message>",
    "<local-command-stdout>",
    "This session is being continued from a previous conversation",
)


def is_machine_generated_user_text(text):
    return text.strip().startswith(_MACHINE_PREFIXES)


def decode_slug_lossy(slug):
    """Naive slug decode, fallback only. '-' stands for both '/' and '.',
    so this is lossy (see module docstring)."""
    if slug.startswith("-"):
        return "/" + slug[1:].replace("-", "/")
    return slug


def one_line(text, limit=90):
    flat = " ".join(text.split())
    if len(flat) > limit:
        return flat[:limit] + "..."
    return flat


# ---------------------------------------------------------------------------
# Claude Code sessions
# ---------------------------------------------------------------------------

def claude_first_meta(path):
    """cwd + gitBranch from the first record that carries a cwd (port of
    EventParser's sessionStart rule: lead-in lines have no cwd)."""
    for ln in read_head_lines(path):
        try:
            obj = json.loads(ln)
        except (ValueError, TypeError):
            continue
        cwd = obj.get("cwd")
        if isinstance(cwd, str) and cwd:
            branch = obj.get("gitBranch")
            return cwd, branch if isinstance(branch, str) else None
    return None, None


def classify_claude_tail(lines):
    """Walk the tail newest-first and classify the last meaningful record.
    Sidechain records (a subagent's interleaved transcript) are skipped,
    mirroring EventParser's provenance guard."""
    info = {
        "last_event_ts": None,
        "last_event_type": None,
        "end_turn": False,
        "open_question": False,
        "pending_tool_use": False,
        "snippet": "",
    }
    for ln in reversed(lines):
        try:
            obj = json.loads(ln)
        except (ValueError, TypeError):
            continue
        rtype = obj.get("type")
        if rtype not in ("user", "assistant", "system"):
            continue
        if obj.get("isSidechain") is True:
            continue
        info["last_event_ts"] = obj.get("timestamp")
        if rtype == "system":
            info["last_event_type"] = "SystemSignal(%s)" % obj.get("subtype", "?")
            return info
        message = obj.get("message") or {}
        content = message.get("content")
        if rtype == "user":
            if isinstance(content, str):
                info["last_event_type"] = "UserPrompt"
                info["snippet"] = one_line(content)
                return info
            if isinstance(content, list):
                kinds = {b.get("type") for b in content if isinstance(b, dict)}
                if "tool_result" in kinds:
                    info["last_event_type"] = "ToolResult"
                    return info
                texts = [b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
                if texts:
                    info["last_event_type"] = "UserPrompt"
                    info["snippet"] = one_line("\n".join(texts))
                    return info
            continue
        # assistant
        if not isinstance(content, list):
            continue
        tool_names = [b.get("name", "?") for b in content
                      if isinstance(b, dict) and b.get("type") == "tool_use"]
        texts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        if tool_names:
            info["last_event_type"] = "ToolCall(%s)" % ",".join(tool_names[:3])
            info["pending_tool_use"] = True
            return info
        if texts:
            text = "\n".join(texts)
            info["last_event_type"] = "AssistantText"
            info["snippet"] = one_line(text)
            # Stop-shape: an assistant text turn with no tool_use is
            # stop-shaped (TriageEngine.updateIdleState's "no_tool_use"
            # rule); an explicit stop_reason=end_turn confirms it.
            info["end_turn"] = True
            info["stop_reason"] = message.get("stop_reason")
            info["open_question"] = looks_like_question(text)
            return info
        continue
    return info


def scan_claude(projects_dir, cutoff, own_session_id):
    sessions = []
    if not projects_dir.is_dir():
        return sessions
    for project_dir in sorted(projects_dir.iterdir()):
        if not project_dir.is_dir():
            continue
        for jsonl in project_dir.glob("*.jsonl"):
            try:
                mtime = jsonl.stat().st_mtime
            except OSError:
                continue
            if mtime < cutoff:
                continue
            session_id = jsonl.stem
            if own_session_id and session_id == own_session_id:
                continue
            try:
                cwd, branch = claude_first_meta(jsonl)
                tail_info = classify_claude_tail(read_tail_lines(jsonl))
                counts = count_bytes(jsonl, [b'"type":"user"', b'"type":"tool_result"'])
                approx_turns = max(0, counts[b'"type":"user"'] - counts[b'"type":"tool_result"'])
            except OSError:
                continue
            if cwd:
                project, source = cwd, "transcript-cwd"
            else:
                project, source = decode_slug_lossy(project_dir.name), "slug-decode-lossy"
            sessions.append({
                "source": "claude",
                "session_id": session_id,
                "project_slug": project_dir.name,
                "project_dir": project,
                "project_dir_source": source,
                "git_branch": branch,
                "jsonl_path": str(jsonl),
                "last_activity_unix": mtime,
                "approx_turns": approx_turns,
                **tail_info,
            })
    return sessions


# ---------------------------------------------------------------------------
# Codex CLI sessions (port of CodexRolloutSource / CodexRolloutParser)
# ---------------------------------------------------------------------------

def codex_session_id(stem):
    """rollout-<ISO-ts>-<uuid>: the uuid is the LAST five hyphen groups."""
    parts = stem.split("-")
    if len(parts) >= 5:
        return "-".join(parts[-5:])
    return stem


def codex_first_meta(path):
    for ln in read_head_lines(path, max_lines=20):
        try:
            obj = json.loads(ln)
        except (ValueError, TypeError):
            continue
        if obj.get("type") != "session_meta":
            continue
        payload = obj.get("payload") or {}
        cwd = payload.get("cwd")
        branch = None
        git = payload.get("git")
        if isinstance(git, dict):
            branch = git.get("branch") or git.get("current_branch")
        return (cwd if isinstance(cwd, str) else None,
                branch if isinstance(branch, str) else None)
    return None, None


def classify_codex_tail(lines):
    info = {
        "last_event_ts": None,
        "last_event_type": None,
        "end_turn": False,
        "open_question": False,
        "pending_tool_use": False,
        "snippet": "",
    }
    for ln in reversed(lines):
        try:
            obj = json.loads(ln)
        except (ValueError, TypeError):
            continue
        rtype = obj.get("type")
        payload = obj.get("payload") or {}
        sub = payload.get("type")
        if rtype == "event_msg":
            if sub in ("task_started", "token_count"):
                continue
            if sub == "task_complete":
                info["end_turn"] = True
                continue  # keep walking for the content event
            if sub == "user_message":
                info["last_event_ts"] = obj.get("timestamp")
                info["last_event_type"] = "UserPrompt"
                info["snippet"] = one_line(payload.get("message") or "")
                return info
            if sub == "agent_message":
                text = payload.get("message") or ""
                info["last_event_ts"] = obj.get("timestamp")
                info["last_event_type"] = "AssistantText"
                info["snippet"] = one_line(text)
                info["open_question"] = looks_like_question(text)
                return info
            continue
        if rtype == "response_item":
            if sub in ("function_call", "local_shell_call"):
                info["last_event_ts"] = obj.get("timestamp")
                info["last_event_type"] = "ToolCall(%s)" % payload.get("name", sub)
                info["pending_tool_use"] = True
                return info
            if sub in ("function_call_output", "custom_tool_call_output"):
                info["last_event_ts"] = obj.get("timestamp")
                info["last_event_type"] = "ToolResult"
                return info
            continue
        if rtype == "session_meta":
            info["last_event_ts"] = obj.get("timestamp")
            info["last_event_type"] = "SessionStart"
            return info
    return info


def scan_codex(codex_dir, cutoff):
    sessions = []
    if not codex_dir.is_dir():
        return sessions
    for jsonl in codex_dir.rglob("rollout-*.jsonl"):
        try:
            mtime = jsonl.stat().st_mtime
        except OSError:
            continue
        if mtime < cutoff:
            continue
        try:
            cwd, branch = codex_first_meta(jsonl)
            tail_info = classify_codex_tail(read_tail_lines(jsonl))
            counts = count_bytes(jsonl, [b'"type":"user_message"'])
        except OSError:
            continue
        sessions.append({
            "source": "codex",
            "session_id": codex_session_id(jsonl.stem),
            "project_slug": None,
            "project_dir": cwd or "(unknown)",
            "project_dir_source": "session_meta" if cwd else "unavailable",
            "git_branch": branch,
            "jsonl_path": str(jsonl),
            "last_activity_unix": mtime,
            "approx_turns": counts[b'"type":"user_message"'],
            **tail_info,
        })
    return sessions


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def state_of(row, now):
    idle = now - row["last_activity_unix"]
    if row["open_question"]:
        return "open question"
    if row["pending_tool_use"]:
        return "tool pending" + (" (perm?)" if idle > 60 else "")
    if row["end_turn"]:
        return "end_turn"
    return "running"


def print_table(rows, hours, now):
    if not rows:
        print("No sessions active in the last %g hours." % hours)
        return
    headers = ["SESSION", "SRC", "AGE", "TURNS", "STATE", "LAST EVENT", "PROJECT"]
    table = []
    lossy = False
    for row in rows:
        project = row["project_dir"]
        if row["project_dir_source"] == "slug-decode-lossy":
            project += " ~lossy"
            lossy = True
        table.append([
            row["session_id"][:8],
            row["source"],
            age_str(now - row["last_activity_unix"]),
            str(row["approx_turns"]),
            state_of(row, now),
            row["last_event_type"] or "?",
            project,
        ])
    widths = [max(len(headers[i]), max(len(r[i]) for r in table)) for i in range(len(headers))]
    fmt = "  ".join("{:<%d}" % w for w in widths)
    print(fmt.format(*headers))
    for r in table:
        print(redact(fmt.format(*r)))
    snippets = [(r["session_id"][:8], r["snippet"]) for r in rows if r["snippet"]]
    if snippets:
        print()
        print("Last text per session (redacted):")
        for sid, snip in snippets:
            print(redact("  %s  %s" % (sid, snip)))
    if lossy:
        print()
        print("~lossy: no cwd record found; project dir decoded from the slug,")
        print("where '-' is ambiguous between '/', '.' and literal hyphens.")


def main(argv=None):
    ap = argparse.ArgumentParser(description="List agent sessions active in the last N hours.")
    ap.add_argument("--hours", type=float, default=24.0, help="activity window (default 24)")
    ap.add_argument("--json", action="store_true", help="JSON output")
    ap.add_argument("--projects-dir", default=None, help="override ~/.claude/projects")
    ap.add_argument("--codex-dir", default=None, help="override ~/.codex/sessions")
    ap.add_argument("--no-codex", action="store_true", help="skip Codex rollouts")
    args = ap.parse_args(argv)

    projects_dir = Path(args.projects_dir) if args.projects_dir else Path.home() / ".claude" / "projects"
    codex_dir = Path(args.codex_dir) if args.codex_dir else Path.home() / ".codex" / "sessions"
    now = datetime.datetime.now().timestamp()
    cutoff = now - args.hours * 3600
    own_session_id = os.environ.get("CLAUDE_SESSION_ID")

    rows = scan_claude(projects_dir, cutoff, own_session_id)
    if not args.no_codex:
        rows.extend(scan_codex(codex_dir, cutoff))
    rows.sort(key=lambda r: r["last_activity_unix"], reverse=True)

    if args.json:
        for row in rows:
            row["last_activity"] = datetime.datetime.fromtimestamp(
                row["last_activity_unix"]).astimezone().isoformat()
            row["state"] = state_of(row, now)
            row["snippet"] = redact(row["snippet"])
            row["looks_like_permission_prompt"] = bool(
                row["pending_tool_use"] and (now - row["last_activity_unix"]) > 60)
        print(redact(json.dumps({"hours": args.hours, "sessions": rows}, indent=2)))
    else:
        print_table(rows, args.hours, now)

    if not projects_dir.is_dir() and (args.no_codex or not codex_dir.is_dir()):
        print("warning: %s does not exist" % projects_dir, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
