#!/usr/bin/env python3
"""tail_session.py - print the last N events of an agent session transcript
in Supervisor's compact triage form, with every printed body redacted.

Usage:
    python3 tail_session.py <path-or-session-id>       # last 40 events
    python3 tail_session.py <session-id> --events 80
    python3 tail_session.py <session-id> --json
    python3 tail_session.py --self-test                # redaction tests

A bare session id (or unique prefix) is resolved against
~/.claude/projects/*/<id>.jsonl and ~/.codex/sessions/**/rollout-*<id>.jsonl.

Line format (the compact event form from DESIGN.md section 4.2):
    [uuid=<first-8>] [ts=<HH:MM:SS local>] <EventType> <compact body>
Bodies are redacted FIRST, then truncated to ~400 chars (marked
" ...[truncated]"), so a secret can never be split by the cap and slip
past a pattern. Newlines inside a body are shown as literal "\\n".

Ported from (paths relative to the supervisor repo root):
  - Sources/SupervisorCore/Observation/EventParser.swift: record shapes,
    sessionStart on the first cwd-carrying record, sidechain lines
    skipped, machine-generated user turns (slash-command echoes, isMeta
    caveats, compact-continuation summaries) never rendered as
    UserPrompt, tool_result stringification with its 4 KB cap.
    Deviation, per the skill brief: EventParser v0.1.0 emits Bash tool
    calls (plus Edit/Write/MultiEdit as fileEdit); this script renders
    EVERY tool_use (name plus key input fields) and every tool_result
    (tool name, ok/error, snippet), because a supervising agent wants
    Read/Grep/MCP visibility too.
  - Sources/SupervisorCore/AgentAdapter/CodexRolloutParser.swift: Codex
    rollout mapping (session_meta, event_msg user_message/agent_message,
    response_item function_call / local_shell_call /
    function_call_output; bash -lc argv unwrapping; "Output:" header
    stripping; "Process exited with code N" error detection).
  - Sources/SupervisorCore/Redact/Patterns.swift + Redactor.swift
    (release/v0.3.0-rc set): the redaction table below.
  - Tests/SupervisorCoreTests/RedactorTests.swift: the --self-test cases.

Malformed JSONL lines are skipped and counted (never fatal).
Python 3.9+ stdlib only. Read-only.
"""

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Redaction.
#
# Duplicated in sessions.py ON PURPOSE: the skill's scripts are
# self-contained with no cross-script imports (per the skill design brief).
# If you change a pattern here, change it in sessions.py too.
#
# Ported from Sources/SupervisorCore/Redact/Patterns.swift + Redactor.swift
# (release/v0.3.0-rc line): fixed "<redacted:type>" placeholders, patterns
# applied in the declared order, idempotent (re-redacting a redacted string
# is a no-op; the env-secret rule carries an explicit (?!<redacted) guard).
# Fail closed: any internal error withholds the content entirely.
# ---------------------------------------------------------------------------

_AWS_KEY_RE = re.compile(r"\bAKIA[0-9A-Z]{16}\b")
_AWS_SECRET_RE = re.compile(r"[A-Za-z0-9/+=]{40}")

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
    """Replace only the given capture group of every match, applied last
    match first so earlier spans stay valid (Redactor.replaceCaptureGroup)."""
    out = text
    for m in reversed(list(pattern.finditer(text))):
        start, end = m.span(group)
        if start < 0:
            continue
        out = out[:start] + placeholder + out[end:]
    return out


def _replace_aws_pair(placeholder, text):
    """AKIA access-key id plus a paired 40-char secret within 200 chars
    forward; both replaced (Redactor.replaceAWSPair)."""
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
# Shared parsing helpers
# ---------------------------------------------------------------------------

BODY_CAP = 400          # display cap per event body (brief: keep first ~400)
RESULT_CAP = 4096       # EventParser.stringifyToolResultContent's cap
FIELD_CAP = 160         # per input field in a ToolCall body


def parse_iso_ts(raw):
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


def hhmmss(raw_ts):
    dt = parse_iso_ts(raw_ts)
    if dt is None:
        return "??:??:??"
    return dt.astimezone().strftime("%H:%M:%S")


def stringify_tool_result_content(raw):
    """Port of EventParser.stringifyToolResultContent: string, list of
    text-bearing blocks, or anything else; capped at 4 KB."""
    if isinstance(raw, str):
        s = raw
    elif isinstance(raw, list):
        parts = []
        for block in raw:
            if isinstance(block, dict):
                text = block.get("text") or block.get("content")
                if isinstance(text, str):
                    parts.append(text)
        s = "\n".join(parts)
        if not s:
            try:
                s = json.dumps(raw)
            except (TypeError, ValueError):
                s = ""
    elif raw is not None:
        s = str(raw)
    else:
        s = ""
    if len(s.encode("utf-8", errors="replace")) > RESULT_CAP:
        s = s[:RESULT_CAP] + " ...[truncated]"
    return s


def clip(value, limit=FIELD_CAP):
    s = str(value)
    if len(s) > limit:
        return s[:limit] + "..."
    return s


# Port of EventParser.isMachineGeneratedUserText.
_MACHINE_PREFIXES = (
    "<command-name>",
    "<command-message>",
    "<local-command-stdout>",
    "This session is being continued from a previous conversation",
)


def is_machine_generated_user_text(text):
    return text.strip().startswith(_MACHINE_PREFIXES)


# ---------------------------------------------------------------------------
# Claude Code transcript parser
# ---------------------------------------------------------------------------

_PREFERRED_INPUT_KEYS = [
    "command", "description", "file_path", "path", "pattern", "query",
    "url", "prompt", "skill", "old_string", "new_string", "content",
]


def compact_tool_input(input_obj):
    """name(k=v, ...) body: preferred keys first, then remaining scalars."""
    if not isinstance(input_obj, dict):
        return clip(input_obj)
    parts = []
    seen = set()
    for key in _PREFERRED_INPUT_KEYS:
        if key in input_obj and isinstance(input_obj[key], (str, int, float, bool)):
            parts.append("%s=%s" % (key, clip(input_obj[key])))
            seen.add(key)
    for key, value in input_obj.items():
        if key in seen or len(parts) >= 6:
            continue
        if isinstance(value, (str, int, float, bool)):
            parts.append("%s=%s" % (key, clip(value)))
    return " ".join(parts)


class ClaudeParser:
    """EventParser.swift port, generalized to all tools (see module doc)."""

    def __init__(self):
        self.tool_names = {}          # tool_use_id -> tool name
        self.malformed = 0
        self.sidechain_skipped = 0
        self.meta_skipped = 0
        self.emitted_session_start = False

    def parse_line(self, line):
        line = line.strip()
        if not line:
            return []
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            self.malformed += 1
            return []
        if not isinstance(obj, dict):
            self.malformed += 1
            return []
        rtype = obj.get("type")
        if not isinstance(rtype, str):
            return []
        events = []
        # sessionStart on the first record that carries a cwd (the lead-in
        # lines have none) - EventParser's rule.
        if not self.emitted_session_start:
            cwd = obj.get("cwd")
            if isinstance(cwd, str) and cwd and obj.get("sessionId"):
                events.append(self._event(obj, "SessionStart",
                                          "cwd=%s branch=%s" % (cwd, obj.get("gitBranch") or "?")))
                self.emitted_session_start = True
        # Sidechain lines are a subagent's transcript; skip past sessionStart
        # (EventParser's provenance guard).
        if obj.get("isSidechain") is True:
            self.sidechain_skipped += 1
            return events
        if rtype == "user":
            events.extend(self._parse_user(obj))
        elif rtype == "assistant":
            events.extend(self._parse_assistant(obj))
        elif rtype == "system":
            subtype = obj.get("subtype", "unknown")
            prevented = bool(obj.get("preventedContinuation"))
            body = "%s preventedContinuation=%s" % (subtype, str(prevented).lower())
            content = obj.get("content")
            if isinstance(content, str) and content:
                body += ": " + clip(content, 200)
            events.append(self._event(obj, "SystemSignal", body))
        return events

    def _parse_user(self, obj):
        message = obj.get("message") or {}
        content = message.get("content")
        is_meta = obj.get("isMeta") is True
        events = []
        if isinstance(content, str) and content:
            if is_meta or is_machine_generated_user_text(content):
                self.meta_skipped += 1
            else:
                events.append(self._event(obj, "UserPrompt", content))
            return events
        if not isinstance(content, list):
            return events
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_result":
                tool_use_id = block.get("tool_use_id", "?")
                name = self.tool_names.get(tool_use_id, "?")
                is_error = bool(block.get("is_error"))
                snippet = stringify_tool_result_content(block.get("content"))
                body = "tool=%s %s: %s" % (name, "ERROR" if is_error else "ok", snippet)
                events.append(self._event(obj, "ToolResult", body))
            elif btype == "text":
                text = block.get("text", "")
                if not text:
                    continue
                if is_meta or is_machine_generated_user_text(text):
                    self.meta_skipped += 1
                else:
                    events.append(self._event(obj, "UserPrompt", text))
        return events

    def _parse_assistant(self, obj):
        message = obj.get("message") or {}
        content = message.get("content")
        if not isinstance(content, list):
            return []
        events = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                text = block.get("text", "")
                if text:
                    events.append(self._event(obj, "AssistantText", text))
            elif btype == "tool_use":
                name = block.get("name", "?")
                tool_use_id = block.get("id")
                if isinstance(tool_use_id, str):
                    self.tool_names[tool_use_id] = name
                body = "%s %s" % (name, compact_tool_input(block.get("input") or {}))
                events.append(self._event(obj, "ToolCall", body))
            # thinking blocks etc.: not consumed (EventParser parity)
        return events

    @staticmethod
    def _event(obj, etype, body):
        return {
            "uuid": obj.get("uuid") or "-",
            "ts": obj.get("timestamp"),
            "type": etype,
            "body": body,
        }


# ---------------------------------------------------------------------------
# Codex rollout parser (CodexRolloutParser.swift port)
# ---------------------------------------------------------------------------

_CODEX_SHELL_TOOLS = {"exec_command", "shell", "bash", "local_shell", "container.exec"}


def codex_join_argv(argv):
    """['bash','-lc','<script>'] -> the script; otherwise space-join
    (CodexRolloutParser.joinArgv)."""
    if len(argv) >= 3:
        head = argv[0].rsplit("/", 1)[-1]
        if head in ("bash", "zsh", "sh") and argv[1] in ("-lc", "-c"):
            return " ".join(argv[2:])
    return " ".join(argv)


def codex_extract_shell_command(payload):
    args_str = payload.get("arguments")
    if isinstance(args_str, str):
        try:
            args = json.loads(args_str)
        except (ValueError, TypeError):
            args = None
        if isinstance(args, dict):
            cmd = args.get("cmd")
            if isinstance(cmd, str) and cmd:
                return cmd
            cmd = args.get("command")
            if isinstance(cmd, str) and cmd:
                return cmd
            if isinstance(cmd, list) and cmd:
                return codex_join_argv([str(x) for x in cmd])
    action = payload.get("action")
    if isinstance(action, dict):
        cmd = action.get("command")
        if isinstance(cmd, str) and cmd:
            return cmd
        if isinstance(cmd, list) and cmd:
            return codex_join_argv([str(x) for x in cmd])
    return None


def codex_clean_output(raw):
    """Strip the 'Output:\\n' wrapper header; cap at 4 KB
    (CodexRolloutParser.cleanOutput)."""
    marker = "Output:\n"
    idx = raw.find(marker)
    body = raw[idx + len(marker):] if idx >= 0 else raw
    if len(body.encode("utf-8", errors="replace")) > RESULT_CAP:
        return body[:RESULT_CAP] + " ...[truncated]"
    return body


def codex_output_indicates_error(raw):
    marker = "Process exited with code "
    idx = raw.find(marker)
    if idx < 0:
        return False
    digits = ""
    for ch in raw[idx + len(marker):]:
        if ch.isdigit():
            digits += ch
        else:
            break
    return bool(digits) and int(digits) != 0


def codex_stringify_output(raw):
    if isinstance(raw, str):
        return raw
    if isinstance(raw, dict):
        for key in ("output", "content"):
            if isinstance(raw.get(key), str):
                return raw[key]
        try:
            return json.dumps(raw)
        except (TypeError, ValueError):
            return ""
    if raw is not None:
        return str(raw)
    return ""


class CodexParser:
    """CodexRolloutParser.swift port. Owner prompts and assistant text come
    ONLY from event_msg (user_message / agent_message); shell commands and
    their outputs come from response_item. Non-shell function_calls are
    rendered too (generalization, same rationale as the Claude parser)."""

    def __init__(self):
        self.call_names = {}          # call_id -> tool name
        self.malformed = 0
        self.sidechain_skipped = 0    # unused for Codex; kept for symmetry
        self.meta_skipped = 0
        self.emitted_session_start = False

    def parse_line(self, line):
        line = line.strip()
        if not line:
            return []
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            self.malformed += 1
            return []
        if not isinstance(obj, dict):
            self.malformed += 1
            return []
        rtype = obj.get("type")
        payload = obj.get("payload")
        if not isinstance(rtype, str) or not isinstance(payload, dict):
            return []
        ts = obj.get("timestamp")
        if rtype == "session_meta":
            if self.emitted_session_start:
                return []
            cwd = payload.get("cwd")
            if not isinstance(cwd, str) or not cwd:
                return []
            branch = None
            git = payload.get("git")
            if isinstance(git, dict):
                branch = git.get("branch") or git.get("current_branch")
            self.emitted_session_start = True
            return [self._event(payload.get("id"), ts, "SessionStart",
                                "cwd=%s branch=%s" % (cwd, branch or "?"))]
        if rtype == "event_msg":
            sub = payload.get("type")
            msg = payload.get("message")
            if sub == "user_message" and isinstance(msg, str) and msg:
                return [self._event(None, ts, "UserPrompt", msg)]
            if sub == "agent_message" and isinstance(msg, str) and msg:
                return [self._event(None, ts, "AssistantText", msg)]
            return []
        if rtype == "response_item":
            sub = payload.get("type")
            if sub in ("function_call", "local_shell_call"):
                name = payload.get("name") or sub
                call_id = payload.get("call_id") or payload.get("id")
                command = codex_extract_shell_command(payload)
                if isinstance(call_id, str):
                    self.call_names[call_id] = name
                if command is not None and (name in _CODEX_SHELL_TOOLS or sub == "local_shell_call"):
                    body = "%s command=%s" % (name, command)
                else:
                    body = "%s args=%s" % (name, clip(payload.get("arguments") or ""))
                return [self._event(call_id, ts, "ToolCall", body)]
            if sub in ("function_call_output", "custom_tool_call_output"):
                call_id = payload.get("call_id")
                name = self.call_names.get(call_id, "?")
                raw = codex_stringify_output(payload.get("output"))
                body = "tool=%s %s: %s" % (
                    name,
                    "ERROR" if codex_output_indicates_error(raw) else "ok",
                    codex_clean_output(raw),
                )
                return [self._event(call_id, ts, "ToolResult", body)]
            return []
        return []  # turn_context and future types: ignored

    @staticmethod
    def _event(uuid, ts, etype, body):
        return {"uuid": uuid or "-", "ts": ts, "type": etype, "body": body}


# ---------------------------------------------------------------------------
# Transcript resolution + rendering
# ---------------------------------------------------------------------------

def looks_like_codex(path):
    return path.name.startswith("rollout-")


def resolve_transcript(arg):
    """Accept a file path, a full session id, or a unique id prefix."""
    p = Path(arg).expanduser()
    if p.is_file():
        return p
    if "/" in arg:
        raise FileNotFoundError("no such transcript: %s" % arg)
    candidates = []
    claude_root = Path.home() / ".claude" / "projects"
    if claude_root.is_dir():
        candidates.extend(claude_root.glob("*/%s*.jsonl" % arg))
    codex_root = Path.home() / ".codex" / "sessions"
    if codex_root.is_dir():
        candidates.extend(c for c in codex_root.rglob("rollout-*.jsonl")
                          if arg in c.stem)
    if not candidates:
        raise FileNotFoundError("no transcript matches %r" % arg)
    exact = [c for c in candidates if c.stem == arg or c.stem.endswith(arg)]
    pool = exact or candidates
    pool.sort(key=lambda c: c.stat().st_mtime, reverse=True)
    if len(pool) > 1:
        print("note: %d transcripts match %r; using most recent %s"
              % (len(pool), arg, pool[0]), file=sys.stderr)
    return pool[0]


def format_line(event):
    body = redact(event["body"]).replace("\r", "").replace("\n", "\\n")
    if len(body) > BODY_CAP:
        body = body[:BODY_CAP] + " ...[truncated]"
    uuid_short = str(event["uuid"])[:8]
    return "[uuid=%s] [ts=%s] %s %s" % (uuid_short, hhmmss(event["ts"]), event["type"], body)


def run_tail(args):
    try:
        path = resolve_transcript(args.session)
    except FileNotFoundError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    parser = CodexParser() if looks_like_codex(path) else ClaudeParser()
    events = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            events.extend(parser.parse_line(line))
    shown = events[-args.events:]
    if args.json:
        out_events = []
        for ev in shown:
            body = redact(ev["body"])
            if len(body) > BODY_CAP:
                body = body[:BODY_CAP] + " ...[truncated]"
            out_events.append({
                "uuid": ev["uuid"], "ts": ev["ts"], "type": ev["type"], "body": body,
            })
        print(redact(json.dumps({
            "transcript": str(path),
            "format": "codex" if looks_like_codex(path) else "claude",
            "events_total": len(events),
            "events_shown": len(out_events),
            "malformed_lines_skipped": parser.malformed,
            "sidechain_lines_skipped": parser.sidechain_skipped,
            "machine_user_turns_skipped": parser.meta_skipped,
            "events": out_events,
        }, indent=2)))
    else:
        print(redact("# %s (%s format)" % (path, "codex" if looks_like_codex(path) else "claude")))
        print("# showing last %d of %d events; %d malformed line(s) skipped, "
              "%d sidechain line(s) skipped, %d machine-generated user turn(s) skipped"
              % (len(shown), len(events), parser.malformed,
                 parser.sidechain_skipped, parser.meta_skipped))
        for ev in shown:
            print(format_line(ev))
    return 0


# ---------------------------------------------------------------------------
# Self-test: redaction cases ported from RedactorTests.swift
# ---------------------------------------------------------------------------

def self_test():
    failures = []

    def check(name, condition, detail=""):
        if not condition:
            failures.append("%s%s" % (name, (" - " + detail) if detail else ""))

    # --- positive cases: (name, input, must_contain, must_not_contain) ---
    jwt = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
           "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4iLCJpYXQiOjE1MTYyMzkwMjJ9."
           "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
    positives = [
        ("anthropic-key", "my key is sk-ant-api03-AbCdEf12345678_xyz-AbCdEf12345",
         ["<redacted:anthropic-key>"], ["sk-ant-api03"]),
        ("generic-api-key", "OPENAI_KEY=sk-AbCdEf1234567890abcdefghijklmnop12345678",
         ["<redacted:api-key>"], ["sk-AbCdEf"]),
        ("github-classic", "TOKEN=%s blah" % ("ghp_" + "A" * 36),
         ["<redacted:github-token>"], ["ghp_" + "A" * 36]),
        ("github-fine-grained", "use %s for the call" % ("github_pat_" + "B" * 82),
         ["<redacted:github-token>"], ["github_pat_" + "B" * 82]),
        ("github-oauth", "gho_" + "9" * 36, ["<redacted:github-token>"], ["gho_" + "9" * 36]),
        ("github-server", "token: %s" % ("ghs_" + "C" * 36),
         ["<redacted:github-token>"], ["ghs_" + "C" * 36]),
        ("gitlab", "clone with %s" % ("glpat-" + "x" * 20),
         ["<redacted:gitlab-token>"], ["glpat-" + "x" * 20]),
        ("npm", "//registry.npmjs.org/:_authToken=%s" % ("npm_" + "a" * 36),
         ["<redacted:npm-token>"], ["npm_" + "a" * 36]),
        ("google", "maps key is AIzaSy%s" % ("D" * 33),
         ["<redacted:google-api-key>"], ["AIzaSy" + "D" * 33]),
        ("slack-bot", "xoxb-1234567890-AbCdEfGhIjKlMnOp1234", ["<redacted:slack-token>"], ["xoxb-1234"]),
        ("stripe-live", "the stripe key is sk_live_%s done" % ("a" * 24),
         ["<redacted:stripe-key>"], ["sk_live_" + "a" * 24]),
        ("stripe-webhook", "STRIPE_WEBHOOK=whsec_%s" % ("b" * 24),
         ["<redacted:stripe-webhook-secret>"], ["whsec_" + "b" * 24]),
        ("sendgrid", "sendgrid key: SG.%s.%s" % ("a" * 22, "b" * 43),
         ["<redacted:sendgrid-key>"], ["SG." + "a" * 22]),
        ("twilio", "twilio sid AC%s here" % ("a" * 32),
         ["<redacted:twilio-key>"], ["AC" + "a" * 32]),
        ("aws-pair",
         "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
         "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
         ["<redacted:aws-credential>"],
         ["AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"]),
        ("aws-key-alone", "the access key is AKIAIOSFODNN7EXAMPLE and we'll grab the secret separately",
         ["<redacted:aws-credential>"], ["AKIAIOSFODNN7EXAMPLE"]),
        ("aws-secret-assignment", "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
         ["aws_secret_access_key = <redacted:aws-credential>"],
         ["wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"]),
        ("aws-secret-41-env-rule", "aws_secret_access_key=%s" % ("A" * 41),
         ["aws_secret_access_key=<redacted:env-secret>"], ["A" * 41]),
        ("jwt", "token=%s" % jwt, ["<redacted:jwt>"], [jwt]),
        ("pem-private-key",
         "writing key to disk\n-----BEGIN RSA PRIVATE KEY-----\n"
         "MIIEpAIBAAKCAQEAfakebody0123456789\nmoreFakeBody/lines+here==\n"
         "-----END RSA PRIVATE KEY-----\ndone",
         ["<redacted:private-key>", "writing key to disk", "done"],
         ["MIIEpAIBAAKCAQEA", "BEGIN RSA PRIVATE KEY"]),
        ("url-basic-auth", "git clone https://alice:s3cret@github.com/maximizeGPT/secret-repo.git",
         ["<redacted:url-credentials>", "github.com/maximizeGPT/secret-repo.git"], ["alice:s3cret"]),
        ("connection-string", "psql postgres://admin:hunter2@db.internal:5432/prod",
         ["postgres://admin:<redacted:url-credentials>@db.internal:5432/prod"], ["hunter2"]),
        ("mongodb-srv", "mongodb+srv://app:s3cr3tpw@cluster0.mongodb.net/db",
         ["mongodb+srv://app:<redacted:url-credentials>@cluster0.mongodb.net/db"], ["s3cr3tpw"]),
        ("query-param", "GET https://api.example.com/v1/resource?api_key=verysecret123&other=ok",
         ["api_key=<redacted:url-credentials>", "other=ok"], ["verysecret123"]),
        ("json-quote-stop", '{"url":"https://x.test/?token=abc123","next":"keep-me"}',
         ['token=<redacted:url-credentials>","next":"keep-me"'], ["abc123"]),
        ("shell-export", "export ANTHROPIC_API_KEY=sk-stub-not-real-but-keeps-shape",
         ["export ANTHROPIC_API_KEY=<redacted>"], ["sk-stub-not-real-but-keeps-shape"]),
        ("multiline-exports",
         "running setup\nexport AWS_SECRET=wJalrXUtnFEMIabcd1234567890bPxRfiCYEXAMPLEKEY\n"
         "export GITHUB_TOKEN=ghp_realtoken_here_with_extra_chars\nall done",
         ["export AWS_SECRET=<redacted>", "export GITHUB_TOKEN=<redacted>", "running setup", "all done"],
         ["wJalrXUtnFEMIabcd"]),
        ("indented-export", "setting up environment\n  export SECRET_TOKEN=hunter2abc\ndone",
         ["export SECRET_TOKEN=<redacted>"], ["hunter2abc"]),
        ("line-leading-token", "output\n%s" % ("ghp_" + "Z" * 36),
         ["<redacted:github-token>"], ["ghp_" + "Z" * 36]),
        ("bare-env-secret", "DATABASE_PASSWORD=hunter2super",
         ["DATABASE_PASSWORD=<redacted:env-secret>"], ["hunter2super"]),
        ("colon-env-secret", "API_TOKEN: abc123def456ghi789",
         ["API_TOKEN: <redacted:env-secret>"], ["abc123def456ghi789"]),
        ("env-secret-later-line", "loading config\nSERVICE_SECRET=s0m3-s3cr3t-value\ndone",
         ["SERVICE_SECRET=<redacted:env-secret>"], ["s0m3-s3cr3t-value"]),
    ]
    for name, text, must, must_not in positives:
        out = redact(text)
        for m in must:
            check("pos:" + name, m in out, "missing %r in %r" % (m, out))
        for m in must_not:
            check("pos:" + name, m not in out, "leaked %r" % m)

    # env-secret must not re-wrap a provider placeholder.
    out = redact("OPENAI_KEY=sk-AbCdEf1234567890abcdefghijklmnop12345678")
    check("pos:no-double-wrap", "<redacted:api-key>" in out and "<redacted:env-secret>" not in out, out)

    # Anthropic pattern wins over generic sk-: exactly one marker.
    out = redact("sk-ant-api03-abcdefghij1234567890abcdefghij1234567890")
    check("pos:one-marker", out.count("<redacted:") == 1, out)

    # Composition blob (testRedactsMultipleSecretsInOneBlob).
    blob = ("Loading credentials...\n"
            "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
            "export AWS_SECRET=wJalrXUtnFEMIabcdefghijklmnopqrstuvwxyz123456\n"
            "export GITHUB_TOKEN=ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n"
            "export ANTHROPIC=sk-ant-api03-real-shape-abc123def456ghi789\n"
            "Hitting endpoint: https://bot:p4ss@hooks.slack.com/services/T00/B00\n"
            "Bearer eyJabcdefghij1234567890.eyJabcdefghij1234567890.eyJabcdefghij1234567890XX\n"
            "Done.")
    out = redact(blob)
    for leaked in ["AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMIabcdef", "ghp_BBBBBBBBBB",
                   "sk-ant-api03", "bot:p4ss"]:
        check("pos:blob", leaked not in out, "leaked %r" % leaked)
    for kept in ["Loading credentials...", "export AWS_ACCESS_KEY_ID=", "hooks.slack.com", "Done."]:
        check("pos:blob", kept in out, "lost %r" % kept)

    # --- negative cases: input must be unchanged ---
    negatives = [
        ("plain-sk-prefix", "the prefix is sk- and that's it"),
        ("short-sk", "sk-" + "a" * 31),
        ("short-ghp", "ghp_" + "A" * 35),
        ("unknown-gh-prefix", "ghx_" + "C" * 36),
        ("short-gitlab", "glpat-" + "x" * 19),
        ("short-npm", "npm_" + "a" * 35),
        ("short-aiza", "AIzaSy" + "D" * 20),
        ("akib", "AKIBIOSFODNN7EXAMPLE is not an AWS key"),
        ("short-stripe", "sk_live_short"),
        ("short-sendgrid", "SG." + "a" * 10 + "." + "b" * 10),
        ("short-twilio", "AC" + "a" * 31),
        ("short-jwt", "eyJ.eyJ.eyJ"),
        ("pem-public-key", "-----BEGIN PUBLIC KEY-----\nMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJ\n-----END PUBLIC KEY-----"),
        ("random-query-param", "https://example.com/?key=value&name=alice"),
        ("api-key-path-segment", "https://example.com/v1/api_key/list"),
        ("conn-string-no-creds", "postgres://db.example.com:5432/mydb"),
        ("export-no-value", "export FOO"),
        ("non-secret-env-name", "username = alice"),
        ("plain-prose", "The eval harness runs Claude Sonnet 4.6 against the netsuite fixture suite.\n"
                        "We measured 12/15 pass on baseline, 13/15 on Opus."),
        ("code-with-key-names", 'let apiKey = config.apiKey\nif let token = headers["Authorization"] {\n'
                                '    print("found token")\n}'),
        ("empty", ""),
    ]
    for name, text in negatives:
        check("neg:" + name, redact(text) == text, "changed: %r -> %r" % (text, redact(text)))

    # --- idempotence (testRedactionIsIdempotent) ---
    idem = ("sk-ant-api03-realish-anthropic-key-shape-xyz1234567890\n"
            "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n"
            "https://alice:s3cret@example.com/?api_key=topsecret\n"
            "export OPENAI_KEY=sk-1234567890abcdefghijklmnopqrstuvwxyz12345")
    once = redact(idem)
    twice = redact(once)
    check("idempotence", once == twice, "once != twice")
    check("idempotence-leak", "s3cret" not in once and "topsecret" not in once, once)

    total = len(positives) + len(negatives) + 5
    if failures:
        for f in failures:
            print("FAIL %s" % f)
        print("self-test: %d case groups, %d FAILURES" % (total, len(failures)))
        return 1
    print("self-test: %d case groups, all passed" % total)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Print the last N events of a session transcript, redacted.")
    ap.add_argument("session", nargs="?", help="transcript path, session id, or id prefix")
    ap.add_argument("--events", type=int, default=40, help="events to show (default 40)")
    ap.add_argument("--json", action="store_true", help="JSON output")
    ap.add_argument("--self-test", action="store_true", help="run embedded redaction tests")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.session:
        ap.print_usage(sys.stderr)
        print("error: a transcript path or session id is required", file=sys.stderr)
        return 2
    return run_tail(args)


if __name__ == "__main__":
    sys.exit(main())
