#!/usr/bin/env python3
"""second_brain.py - iterative memory optimization for a project ("second
brain"): capture what the user actually said across agent sessions into a
locally-owned, plain-Markdown memory that measurably improves each iteration.

Why this exists: Nadella's "Reverse Information Paradox" (July 2026) - users
pay for AI twice, once in money and once in the proprietary knowledge they
reveal in prompts and corrections. Today that second payment evaporates when
the session ends. The second brain captures it into files that live in the
user's own repo, readable by any model or agent (no provider ties), and
whose growth is measured every iteration (a private learning loop).

Usage (the HOST AGENT drives this loop; the script does the deterministic
mechanics and redaction, the agent does the judgment - see
references/second-brain.md for the curation rubric):

    python3 second_brain.py extract [--project <cwd>] [--since-hours N]
                                    [--limit N] [--projects-dir P]
                                    [--codex-dir P] [--no-codex]
        Discover this project's transcripts (Claude Code + Codex CLI),
        pull USER-authored messages only, redact them, run narrow
        deterministic candidate heuristics, and print candidate entries
        as JSON on stdout for the host agent to curate.

    python3 second_brain.py merge [--brain-dir <dir>]  < curated.json
        Read the curated entries (JSON list, or a dict with an "entries"
        or "candidates" key) on stdin, run the merge/confirm/retire/
        measure loop against the existing brain, regenerate the
        artifacts, and print the iteration delta as JSON. An empty list
        [] is a valid no-op iteration (it still ages entries toward
        retirement). Empty or malformed stdin is an error and leaves the
        brain untouched.

    python3 second_brain.py show [--brain-dir <dir>]
        Print where the memory lives and its current iteration summary.

    python3 second_brain.py --self-test
        Build synthetic transcripts in a temp dir (including planted
        fake credentials to prove redaction), run the whole loop, and
        assert idempotence, confirm/retire behavior, artifact contents,
        and odd-payload safety. Prints case counts.

The brain lives at <project>/.supervisor/second-brain/ (default for
--brain-dir: ./.supervisor/second-brain):
    memory.md         human-readable, REGENERATED from brain.json on every
                      merge (one fact, one home; hand-edits are lost)
    brain.json        the machine ledger, source of truth
    iteration-log.md  append-only measurement table

Shared design contract (a Swift twin in the Supervisor app uses the same
vocabulary; keep these names aligned):
    kinds:  decision, correction, environment_fact, gotcha, preference
    fields: id (sha256 of normalized text+kind, first 12 hex), kind, text
            (one fact, one home; capped at 400 chars), provenance
            (session id + ISO timestamp), status (active/merged/retired),
            confidence (low/medium/high), first_seen_iteration,
            last_confirmed_iteration
    loop:   capture -> redact -> merge (id match = confirm: bump
            last_confirmed + confidence one step; normalized-text
            containment = merge) -> retire (unconfirmed for 5 iterations)
            -> measure (added/confirmed/merged/retired/active_total)
            -> render

Determinism: stable entry ordering, idempotent merge (the same stdin twice
means the second run confirms and adds nothing), ids carry no wall-clock.
Transcript discovery and parsing are reused from the sibling scripts
(tail_session.py / sessions.py) via importlib; they ship in this same
directory, so a failed import is a hard, clearly-messaged error for
extract (merge and show never need the parsers and keep working).
Redaction never depends on them. Malformed JSONL lines are skipped and
counted (never fatal).
Fail-safe throughout: an error never destroys the ledger and never breaks
the host session. Python 3.9+ stdlib only.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Redaction.
#
# Duplicated in tail_session.py and sessions.py ON PURPOSE: redaction must
# never depend on a sibling import succeeding. If you change a pattern here,
# change it in both of those scripts too.
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
# Sibling reuse: tail_session.py's parsers and sessions.py's discovery
# helpers, loaded via importlib from this script's own directory. Redaction
# stays local (above); only transcript PARSING reuses the siblings. The
# siblings ship in this same directory, so a failed load is a broken install,
# not a runtime mode: extract refuses to run without them (hard, clear
# error), while merge and show never touch them and keep working.
# ---------------------------------------------------------------------------

def _load_sibling(name):
    try:
        import importlib.util
        path = Path(__file__).resolve().parent / (name + ".py")
        spec = importlib.util.spec_from_file_location("_second_brain_" + name, str(path))
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


_TAIL = _load_sibling("tail_session")
_SESSIONS = _load_sibling("sessions")


def _require_siblings():
    """extract needs the sibling parsers; missing ones are a hard error."""
    missing = [name for name, mod in (("tail_session.py", _TAIL),
                                      ("sessions.py", _SESSIONS)) if mod is None]
    if missing:
        raise RuntimeError(
            "cannot load sibling script(s) %s from %s; extract needs their "
            "transcript parsers. Restore the skill's scripts directory."
            % (", ".join(missing), Path(__file__).resolve().parent))


# Per-transcript and per-project reading caps, kept in lockstep with the
# Swift twin (MemoryDistiller.defaultTailBytes / defaultMaxSessions): read
# only the last 256 KiB of each transcript, scan only the 20 most recently
# modified transcripts.
TAIL_BYTES = 256 * 1024
MAX_SESSIONS = 20


def _looks_like_codex(path):
    return path.name.startswith("rollout-")


def transcript_user_prompts(path):
    """USER-authored messages of one transcript via the sibling parsers (they
    carry the full machine-turn/sidechain rules), reading only the last
    TAIL_BYTES (the byte window's leading partial line is dropped). Each
    prompt carries "after_assistant": True when the previous main-chain turn
    was an assistant action (tool results are machinery and never touch the
    flag) - the correction gate. Returns ([{"ts", "text", "after_assistant"}],
    malformed_count)."""
    parser = _TAIL.CodexParser() if _looks_like_codex(path) else _TAIL.ClaudeParser()
    events = []
    for line in _SESSIONS.read_tail_lines(path, TAIL_BYTES):
        events.extend(parser.parse_line(line))
    prompts = []
    follows_assistant = False
    after = False
    last_user_uuid = None
    for ev in events:
        if ev["type"] in ("AssistantText", "ToolCall"):
            follows_assistant = True
            last_user_uuid = None
        elif ev["type"] == "UserPrompt":
            uuid = ev.get("uuid")
            same_turn = bool(uuid) and uuid != "-" and uuid == last_user_uuid
            if not same_turn:
                # A user message consumes the flag: the NEXT user message is
                # a new thought, not a correction of the assistant.
                after = follows_assistant
                follows_assistant = False
                last_user_uuid = uuid
            prompts.append({"ts": ev["ts"], "text": ev["body"],
                            "after_assistant": after})
    return prompts, parser.malformed


def transcript_cwd(path):
    try:
        if _looks_like_codex(path):
            return _SESSIONS.codex_first_meta(path)[0]
        return _SESSIONS.claude_first_meta(path)[0]
    except Exception:
        return None


def session_id_for(path):
    if _looks_like_codex(path):
        try:
            return _SESSIONS.codex_session_id(path.stem)
        except Exception:
            pass
    return path.stem


# ---------------------------------------------------------------------------
# Entry model (the shared design contract; see module docstring).
# ---------------------------------------------------------------------------

KINDS = ["decision", "correction", "environment_fact", "gotcha", "preference"]
_KIND_TITLES = {
    "decision": "Decisions",
    "correction": "Corrections",
    "environment_fact": "Environment facts",
    "gotcha": "Gotchas",
    "preference": "Preferences",
}
CONFIDENCE_ORDER = ["low", "medium", "high"]
TEXT_CAP = 400
RETIRE_AFTER = 5  # iterations without confirmation
# Containment shorter than this many normalized chars is coincidence, not a
# near-duplicate - "use ruff" is contained in far too many unrelated facts
# to merge on (Swift twin: SecondBrainOptimizer.minContainmentLength).
MIN_CONTAINMENT = 12


def normalize(text):
    """Normalization used for both ids and containment: lowercase, collapse
    whitespace, strip trailing sentence punctuation. No wall-clock input."""
    return re.sub(r"\s+", " ", str(text).strip().lower()).rstrip(".!,;")


def entry_id(kind, text):
    """Stable id: sha256 of kind + normalized text, first 12 hex chars."""
    digest = hashlib.sha256(("%s\n%s" % (kind, normalize(text))).encode("utf-8"))
    return digest.hexdigest()[:12]


def bump_confidence(conf):
    try:
        i = CONFIDENCE_ORDER.index(conf)
    except ValueError:
        i = 0
    return CONFIDENCE_ORDER[min(i + 1, len(CONFIDENCE_ORDER) - 1)]


def _sort_key(entry):
    try:
        k = KINDS.index(entry.get("kind"))
    except ValueError:
        k = len(KINDS)
    return (k, entry.get("first_seen_iteration", 0), entry.get("id", ""))


# ---------------------------------------------------------------------------
# extract: transcript discovery + deterministic candidate heuristics.
# Deliberately narrow and few: leading correction cues, explicit decision /
# preference phrasing. environment_fact and gotcha have no reliable surface
# cue, so no heuristic emits them; the curating agent adds those itself.
# ---------------------------------------------------------------------------

_CORRECTION_LEADS = ("no,", "don't", "do not", "actually", "instead", "stop ", "stop,", "wrong")
_DECISION_CUES = ("let's use", "lets use", "we should")
_DECISION_LEADS = ("always ", "never ")
_PREFERENCE_LEADS = ("prefer ", "i prefer ", "we prefer ")


def slug_for(project):
    """Claude Code's project-dir slug: every character that is not an ASCII
    letter or digit becomes '-' (MemoryDistiller.mungedDirectoryName)."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(project))


def _segments(text):
    """Split a message into sentence-ish segments (newlines first, then
    sentence boundaries)."""
    segs = []
    for line in text.splitlines():
        for part in re.split(r"(?<=[.!?])\s+", line.strip()):
            part = part.strip()
            if part:
                segs.append(part)
    return segs


def classify_segment(seg, follows_assistant):
    """Return (kind, cue) for a candidate-shaped segment, else (None, None).
    Honest and few: minimum length, statements only (no questions), no code
    fences, correction cues must LEAD the segment AND follow an assistant
    action (DESIGN.md: "a negation shape immediately following an assistant
    action" - a session-opening or user-after-user negation is a new thought,
    not a correction; it falls through to the other cue families). always/
    never lead a DECISION, prefer a preference (the Swift twin's classify)."""
    stripped = seg.strip()
    if len(stripped) < 15 or len(stripped.split()) < 4:
        return None, None
    if stripped.rstrip().endswith("?") or "```" in stripped:
        return None, None
    low = stripped.lower()
    if follows_assistant:
        for cue in _CORRECTION_LEADS:
            if low.startswith(cue):
                return "correction", cue.strip(" ,")
    for cue in _DECISION_CUES:
        if cue in low:
            return "decision", cue
    for cue in _DECISION_LEADS:
        if low.startswith(cue):
            return "decision", cue.strip()
    for cue in _PREFERENCE_LEADS:
        if low.startswith(cue):
            return "preference", cue.strip()
    return None, None


def discover_transcripts(project, projects_dir, codex_dir, cutoff, include_codex=True):
    """Transcripts of THIS project active since cutoff, capped at the
    MAX_SESSIONS most recently modified. Claude transcripts live under the
    project's slug directory, and every path munging to that slug lands
    there too, so the slug is a cheap collision-safe pre-filter: only files
    inside it are parsed at all, and the recorded cwd (when present) then
    disambiguates munge collisions. Claude transcripts with no cwd record
    keep the (lossy) slug match; Codex rollouts match on cwd alone."""
    accepted = {os.path.normpath(project), str(Path(project).resolve())}
    slug_dir = projects_dir / slug_for(str(Path(project).resolve()))
    found = []
    if slug_dir.is_dir():
        for jsonl in sorted(slug_dir.glob("*.jsonl")):
            try:
                mtime = jsonl.stat().st_mtime
            except OSError:
                continue
            if mtime < cutoff:
                continue
            cwd = transcript_cwd(jsonl)
            if cwd and os.path.normpath(cwd) not in accepted:
                continue  # munge collision: same slug, different project
            found.append((mtime, jsonl))
    if include_codex and codex_dir.is_dir():
        for jsonl in sorted(codex_dir.rglob("rollout-*.jsonl")):
            try:
                mtime = jsonl.stat().st_mtime
            except OSError:
                continue
            if mtime < cutoff:
                continue
            cwd = transcript_cwd(jsonl)
            if cwd and os.path.normpath(cwd) in accepted:
                found.append((mtime, jsonl))
    # The MAX_SESSIONS most recent (mtime desc, then name - the Swift twin's
    # recentTranscripts order), returned in stable path order.
    found.sort(key=lambda t: (-t[0], t[1].name))
    return sorted((jsonl for _, jsonl in found[:MAX_SESSIONS]), key=str)


def extract_data(project, projects_dir=None, codex_dir=None, since_hours=24.0,
                 limit=40, include_codex=True):
    """The extract phase as a dict (cmd_extract prints it). Every candidate
    text is redacted BEFORE the 400-char cap so a secret can never be split
    by the cap and slip past a pattern. Scanning stops as soon as `limit`
    candidates exist. Raises RuntimeError when the sibling parsers are
    missing (cmd_extract turns that into a clear stderr + exit 1)."""
    _require_siblings()
    project = str(Path(project or ".").resolve())
    projects_dir = Path(projects_dir) if projects_dir else Path.home() / ".claude" / "projects"
    codex_dir = Path(codex_dir) if codex_dir else Path.home() / ".codex" / "sessions"
    cutoff = time.time() - float(since_hours) * 3600
    transcripts = discover_transcripts(project, projects_dir, codex_dir, cutoff, include_codex)

    limit = max(0, int(limit))
    candidates = []
    seen_norms = set()
    messages = 0
    malformed = 0
    skipped_transcripts = 0
    done = limit == 0
    for path in transcripts:
        if done:
            break
        try:
            prompts, bad = transcript_user_prompts(path)
        except Exception:
            skipped_transcripts += 1
            continue
        malformed += bad
        sid = session_id_for(path)
        for prompt in prompts:
            if done:
                break
            messages += 1
            for seg in _segments(prompt["text"]):
                kind, cue = classify_segment(seg, prompt["after_assistant"])
                if kind is None:
                    continue
                text = " ".join(redact(seg).split())[:TEXT_CAP]
                norm = normalize(text)
                if not norm or norm in seen_norms:
                    continue
                seen_norms.add(norm)
                candidates.append({
                    "kind": kind,
                    "text": text,
                    "cue": cue,
                    "confidence": "low",
                    "provenance": {"session_id": sid, "ts": prompt["ts"] or ""},
                })
                if len(candidates) >= limit:
                    done = True
                    break
    return {
        "project": project,
        "since_hours": float(since_hours),
        "transcripts_scanned": len(transcripts) - skipped_transcripts,
        "transcripts_skipped": skipped_transcripts,
        "messages_scanned": messages,
        "malformed_lines_skipped": malformed,
        "candidates": candidates,
        "note": ("Deterministic heuristics over user-authored messages only; "
                 "environment_fact and gotcha entries have no surface cue, add them "
                 "during curation. Curate per references/second-brain.md before merging."),
    }


# ---------------------------------------------------------------------------
# merge: the deterministic loop against the ledger.
# ---------------------------------------------------------------------------

def parse_curated(raw):
    """Curated entries from stdin text: a JSON list, or a dict carrying
    "entries" or "candidates" (so a curated extract payload pipes straight
    through). Raises ValueError on empty or malformed input."""
    raw = (raw or "").strip()
    if not raw:
        raise ValueError("empty stdin: pass a JSON list of curated entries "
                         "([] is a valid no-op iteration)")
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError) as exc:
        raise ValueError("stdin is not valid JSON: %s" % exc)
    if isinstance(obj, dict):
        for key in ("entries", "candidates"):
            if key in obj:
                obj = obj[key]
                break
        else:
            raise ValueError('stdin dict has no "entries" or "candidates" key')
    if not isinstance(obj, list):
        raise ValueError("curated input must be a JSON list of entries")
    return obj


def sanitize_curated(raw):
    """One curated entry -> (kind, text, confidence, provenance), or None if
    the shape is invalid. Text is re-redacted on ingest (defense in depth:
    the ledger must hold no secret even if the curator pasted one), then
    whitespace-collapsed and capped at 400 chars, redaction first."""
    if not isinstance(raw, dict):
        return None
    kind = raw.get("kind")
    text = raw.get("text")
    if kind not in KINDS or not isinstance(text, str):
        return None
    text = " ".join(redact(text).split())[:TEXT_CAP]
    if len(text) < 3:
        return None
    conf = raw.get("confidence")
    if conf not in CONFIDENCE_ORDER:
        conf = "low"
    prov_raw = raw.get("provenance")
    prov = {"session_id": "curated", "ts": ""}
    if isinstance(prov_raw, dict):
        if isinstance(prov_raw.get("session_id"), str) and prov_raw["session_id"]:
            prov["session_id"] = prov_raw["session_id"][:64]
        if isinstance(prov_raw.get("ts"), str):
            prov["ts"] = prov_raw["ts"][:40]
    return kind, text, conf, prov


def _empty_brain():
    return {"version": 1, "iteration": 0, "entries": []}


def load_brain(brain_dir):
    """Load brain.json, or a fresh state when it does not exist. A corrupt
    or wrong-shaped file raises ValueError: the merge REFUSES to overwrite a
    ledger it cannot read (fail-safe: never destroy the record)."""
    path = Path(brain_dir) / "brain.json"
    if not path.exists():
        return _empty_brain()
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except (ValueError, OSError) as exc:
        raise ValueError("%s is unreadable (%s); refusing to overwrite it. "
                         "Fix or move the file, then re-run." % (path, exc))
    if (not isinstance(state, dict) or not isinstance(state.get("iteration"), int)
            or not isinstance(state.get("entries"), list)):
        raise ValueError("%s has an unexpected shape; refusing to overwrite it." % path)
    return state


def _resolve_merged(entry, by_id):
    """Follow a merged entry's merged_into chain to its surviving entry."""
    seen = set()
    while (entry.get("status") == "merged" and entry.get("merged_into") in by_id
           and entry["id"] not in seen):
        seen.add(entry["id"])
        entry = by_id[entry["merged_into"]]
    return entry


def _confirm(entry, iteration):
    entry["last_confirmed_iteration"] = iteration
    entry["confidence"] = bump_confidence(entry.get("confidence"))
    if entry.get("status") != "active":
        entry["status"] = "active"
        entry.pop("retired_iteration", None)


def _new_entry(eid, kind, text, prov, confidence, first_seen, iteration):
    """A fresh active ledger entry (the add and supersede branches differ
    only in the confidence and inherited first_seen values)."""
    return {
        "id": eid, "kind": kind, "text": text, "provenance": prov,
        "status": "active", "confidence": confidence,
        "first_seen_iteration": first_seen,
        "last_confirmed_iteration": iteration,
    }


def merge_brain(brain_dir, curated):
    """Run one iteration of the loop and write the artifacts. Returns the
    delta dict. Raises ValueError when the existing ledger is unreadable
    (and touches nothing in that case)."""
    brain_dir = Path(brain_dir)
    state = load_brain(brain_dir)
    iteration = state["iteration"] + 1
    entries = state["entries"]
    by_id = {e.get("id"): e for e in entries if isinstance(e, dict)}
    added = confirmed = merged = skipped = 0
    seen_batch = set()
    confirmed_ids = set()

    # Cheap-loop caches, kept in sync as the batch mutates the ledger:
    # normalize() once per entry, and the active entries per kind in the
    # containment scan order (instead of re-filtering + re-sorting the whole
    # ledger for every candidate).
    norm_by_id = {eid: normalize(e.get("text", "")) for eid, e in by_id.items()}
    active_by_kind = {}
    for e in sorted((e for e in entries if isinstance(e, dict)
                     and e.get("status") == "active"), key=_sort_key):
        active_by_kind.setdefault(e.get("kind"), []).append(e)

    def track_active(entry):
        """A newly added or revived entry joins the containment scan order."""
        rows = active_by_kind.setdefault(entry.get("kind"), [])
        rows.append(entry)
        rows.sort(key=_sort_key)

    for raw in curated:
        clean = sanitize_curated(raw)
        if clean is None:
            skipped += 1
            continue
        kind, text, conf, prov = clean
        eid = entry_id(kind, text)
        if eid in seen_batch:
            continue
        seen_batch.add(eid)

        existing = by_id.get(eid)
        if existing is not None:
            # id match = confirm (re-observation of the same fact).
            survivor = _resolve_merged(existing, by_id)
            if survivor["id"] not in confirmed_ids:
                revived = survivor.get("status") != "active"
                _confirm(survivor, iteration)
                confirmed_ids.add(survivor["id"])
                confirmed += 1
                if revived:
                    track_active(survivor)
            continue

        # Near-duplicate: normalized-text containment within the same kind,
        # only when the SHORTER side is long enough not to be coincidence.
        norm = normalize(text)
        host = None
        for e in active_by_kind.get(kind, []):
            if e.get("status") != "active":
                continue  # merged away earlier in this same batch
            other = norm_by_id.get(e.get("id"), "")
            if (other and min(len(norm), len(other)) >= MIN_CONTAINMENT
                    and (norm in other or other in norm)):
                host = e
                break
        if host is not None:
            if norm in norm_by_id[host["id"]]:
                # Incoming is subsumed: the existing entry survives. At most
                # one confidence step per entry per iteration, however many
                # batch items re-observe it (same guard as the id match).
                if host["id"] not in confirmed_ids:
                    _confirm(host, iteration)
                    confirmed_ids.add(host["id"])
            else:
                # Incoming is the fuller statement: it supersedes the host,
                # inheriting its history.
                new = _new_entry(eid, kind, text, prov,
                                 bump_confidence(host.get("confidence")),
                                 host.get("first_seen_iteration", iteration), iteration)
                host["status"] = "merged"
                host["merged_into"] = eid
                entries.append(new)
                by_id[eid] = new
                norm_by_id[eid] = norm
                track_active(new)
                confirmed_ids.add(eid)
            merged += 1
            continue

        new = _new_entry(eid, kind, text, prov, conf, iteration, iteration)
        entries.append(new)
        by_id[eid] = new
        norm_by_id[eid] = norm
        track_active(new)
        # Load-bearing: a brand-new entry must not ALSO gain a confidence
        # step from a containment hit later in this same batch.
        confirmed_ids.add(eid)
        added += 1

    # Retire: active entries unconfirmed for RETIRE_AFTER iterations.
    retired = 0
    for e in entries:
        if (isinstance(e, dict) and e.get("status") == "active"
                and iteration - e.get("last_confirmed_iteration", iteration) >= RETIRE_AFTER):
            e["status"] = "retired"
            e["retired_iteration"] = iteration
            retired += 1

    active_total = sum(1 for e in entries if isinstance(e, dict) and e.get("status") == "active")
    entries.sort(key=_sort_key)
    state = {"version": 1, "iteration": iteration, "entries": entries}
    delta = {
        "iteration": iteration,
        "added": added,
        "confirmed": confirmed,
        "merged": merged,
        "retired": retired,
        "active_total": active_total,
        "skipped_invalid": skipped,
    }
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    _write_artifacts(brain_dir, state, delta, ts)
    return delta


def _atomic_write(path, content):
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


_LOG_HEADER = (
    "# Second brain iteration log\n\n"
    "Append-only: one row per merge. memory.md is regenerated every merge;\n"
    "this file never is.\n\n"
    "| iteration | timestamp (UTC) | added | confirmed | merged | retired | active_total |\n"
    "|---|---|---|---|---|---|---|\n"
)


def _write_artifacts(brain_dir, state, delta, ts):
    brain_dir.mkdir(parents=True, exist_ok=True)
    _atomic_write(brain_dir / "brain.json", json.dumps(state, indent=2) + "\n")
    _atomic_write(brain_dir / "memory.md", redact(render_memory(state, ts)))
    log_path = brain_dir / "iteration-log.md"
    if not log_path.exists():
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(_LOG_HEADER)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write("| %d | %s | %d | %d | %d | %d | %d |\n" % (
            delta["iteration"], ts, delta["added"], delta["confirmed"],
            delta["merged"], delta["retired"], delta["active_total"]))


def render_memory(state, ts):
    """memory.md, regenerated in full from the ledger: one fact, one home,
    no hand-edit drift. Sections per kind in contract order, retired at the
    bottom, each entry with a confidence + provenance footer."""
    entries = [e for e in state["entries"] if isinstance(e, dict)]
    active = [e for e in entries if e.get("status") == "active"]
    retired = sorted((e for e in entries if e.get("status") == "retired"), key=_sort_key)
    lines = [
        "# Second brain",
        "",
        "<!-- REGENERATED FILE: rendered from brain.json on every merge; hand-edits",
        "     here are lost. To change an entry, put the corrected entry through the",
        "     Supervisor skill's second-brain loop (extract -> curate -> merge);",
        "     brain.json is the source of truth. -->",
        "",
        "Iteration %d. %d active entr%s. Updated %s." % (
            state["iteration"], len(active), "y" if len(active) == 1 else "ies", ts),
        "",
        "Plain Markdown plus JSON, owned by this repo. No model or provider ties.",
    ]
    for kind in KINDS:
        lines.append("")
        lines.append("## %s" % _KIND_TITLES[kind])
        lines.append("")
        rows = sorted((e for e in active if e.get("kind") == kind), key=_sort_key)
        if not rows:
            lines.append("(none yet)")
        for e in rows:
            lines.append(_render_entry(e))
    lines.append("")
    lines.append("## Retired")
    lines.append("")
    if not retired:
        lines.append("(none)")
    for e in retired:
        prov = e.get("provenance") or {}
        lines.append("- ~~%s~~" % e.get("text", ""))
        lines.append("  (retired it%s, last confirmed it%s, session %s, id %s)" % (
            e.get("retired_iteration", "?"), e.get("last_confirmed_iteration", "?"),
            str(prov.get("session_id", "?"))[:8], e.get("id", "?")))
    lines.append("")
    return "\n".join(lines)


def _render_entry(e):
    prov = e.get("provenance") or {}
    return ("- %s\n  (confidence %s, first seen it%s, last confirmed it%s, "
            "session %s @ %s, id %s)" % (
                e.get("text", ""), e.get("confidence", "low"),
                e.get("first_seen_iteration", "?"), e.get("last_confirmed_iteration", "?"),
                str(prov.get("session_id", "?"))[:8], prov.get("ts") or "-",
                e.get("id", "?")))


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_extract(args):
    try:
        payload = extract_data(args.project, args.projects_dir, args.codex_dir,
                               args.since_hours, args.limit, not args.no_codex)
    except RuntimeError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    print(redact(json.dumps(payload, indent=2)))
    return 0


def cmd_merge(args):
    try:
        curated = parse_curated(sys.stdin.read())
    except ValueError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    try:
        delta = merge_brain(args.brain_dir, curated)
    except ValueError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    print(json.dumps(delta, indent=2))
    return 0


def cmd_show(args):
    brain_dir = Path(args.brain_dir)
    if not (brain_dir / "brain.json").exists():
        print("no second brain at %s yet; run the merge subcommand first" % brain_dir)
        return 1
    try:
        state = load_brain(brain_dir)
    except ValueError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    entries = [e for e in state["entries"] if isinstance(e, dict)]
    by_status = {"active": 0, "merged": 0, "retired": 0}
    per_kind = {k: 0 for k in KINDS}
    for e in entries:
        status = e.get("status")
        if status in by_status:
            by_status[status] += 1
        if status == "active" and e.get("kind") in per_kind:
            per_kind[e["kind"]] += 1
    print("brain:     %s" % brain_dir)
    print("memory:    %s" % (brain_dir / "memory.md"))
    print("log:       %s" % (brain_dir / "iteration-log.md"))
    print("iteration: %d" % state["iteration"])
    print("active:    %d (%s)" % (by_status["active"],
                                  ", ".join("%s %d" % (k, per_kind[k]) for k in KINDS)))
    print("merged:    %d   retired: %d" % (by_status["merged"], by_status["retired"]))
    log_path = brain_dir / "iteration-log.md"
    if log_path.exists():
        rows = [ln for ln in log_path.read_text(encoding="utf-8").splitlines()
                if ln.startswith("| ") and not ln.startswith("| iteration")]
        if rows:
            print("last:      %s" % rows[-1])
    return 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

_FAKE_ANTHROPIC = "sk-ant-api03-selftest-AbCdEf1234567890"
_FAKE_GITHUB = "ghp_" + "A" * 36


def _write_jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(rec if isinstance(rec, str) else json.dumps(rec))
            f.write("\n")


def _claude_rec(i, sid, cwd, text, **extra):
    rec = {"type": "user", "sessionId": sid, "cwd": cwd, "gitBranch": "main",
           "uuid": "u%03d" % i, "timestamp": "2026-07-15T10:%02d:00Z" % (i % 60),
           "message": {"role": "user", "content": text}}
    rec.update(extra)
    return rec


def self_test():
    import contextlib
    import io
    import tempfile

    failures = []
    checks = [0]

    def check(name, condition, detail=""):
        checks[0] += 1
        if not condition:
            failures.append("%s%s" % (name, (" - " + detail) if detail else ""))

    with tempfile.TemporaryDirectory(prefix="second-brain-selftest-") as tmp:
        tmp = Path(tmp)
        project = tmp / "proj"
        project.mkdir()
        proj = str(project.resolve())
        projects_dir = tmp / "claude-projects"
        codex_dir = tmp / "codex-sessions"

        # --- synthetic Claude transcript: cues, noise, planted secrets ---
        sid = "11111111-2222-3333-4444-555555555555"

        def _assistant_rec(i, text):
            return {"type": "assistant", "uuid": "a%03d" % i,
                    "timestamp": "2026-07-15T10:%02d:30Z" % (i % 60),
                    "message": {"role": "assistant", "content": [
                        {"type": "text", "text": text}]}}

        recs = [
            _claude_rec(0, sid, proj, "bootstrap"),
            # A session-opening / user-after-user negation is NOT a
            # correction: no assistant action precedes it.
            _claude_rec(1, sid, proj, "don't start from the templates directory"),
            _claude_rec(2, sid, proj, "let's use ruff for linting in this repo"),
            _assistant_rec(3, "I regenerated the fixtures under tests/golden."),
            _claude_rec(4, sid, proj, "don't touch the generated fixtures under tests/golden"),
            # user-after-user: record 4 consumed the assistant flag.
            _claude_rec(5, sid, proj, "actually the fixtures under tests/manual are editable"),
            _claude_rec(6, sid, proj, "always run make check before pushing anything"),
            _claude_rec(7, sid, proj, "i prefer small focused commits in this repo"),
            _claude_rec(8, sid, proj,
                        "always export the anthropic key %s before the eval" % _FAKE_ANTHROPIC),
            _assistant_rec(9, "I committed the deploy token to the repo."),
            _claude_rec(10, sid, proj,
                        "no, the deploy token %s must never be committed" % _FAKE_GITHUB),
            # noise: short, question, machine-generated, meta, sidechain,
            # code fence, and an assistant turn with a decision cue.
            _claude_rec(11, sid, proj, "ok thanks"),
            _claude_rec(12, sid, proj, "should we use postgres or sqlite here?"),
            _claude_rec(13, sid, proj, "<command-name>/clear</command-name>"),
            _claude_rec(14, sid, proj, "we should skip this meta turn entirely", isMeta=True),
            _claude_rec(15, sid, proj, "we should skip this sidechain turn too", isSidechain=True),
            _claude_rec(16, sid, proj, "we should keep the snippet ```rm -rf /``` around"),
            _assistant_rec(17, "we should refactor the whole module now"),
            "this line is not json {{{",
        ]
        _write_jsonl(projects_dir / slug_for(proj) / (sid + ".jsonl"), recs)

        # A transcript for a DIFFERENT project: must not contribute.
        other_sid = "99999999-8888-7777-6666-555555555555"
        _write_jsonl(projects_dir / slug_for("/elsewhere/app") / (other_sid + ".jsonl"),
                     [_claude_rec(0, other_sid, "/elsewhere/app",
                                  "let's use tabs everywhere in this other repo")])

        # --- synthetic Codex rollout for the same project ---
        codex_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        _write_jsonl(codex_dir / "2026" / "07" / "15" /
                     ("rollout-2026-07-15T10-00-00-%s.jsonl" % codex_uuid),
                     [{"type": "session_meta", "timestamp": "2026-07-15T10:00:00Z",
                       "payload": {"id": codex_uuid, "cwd": proj, "git": {"branch": "main"}}},
                      {"type": "event_msg", "timestamp": "2026-07-15T10:01:00Z",
                       "payload": {"type": "user_message",
                                   "message": "we should pin python 3.11 in ci"}},
                      {"type": "event_msg", "timestamp": "2026-07-15T10:02:00Z",
                       "payload": {"type": "agent_message",
                                   "message": "I wrapped the client calls in a retry loop."}},
                      {"type": "event_msg", "timestamp": "2026-07-15T10:03:00Z",
                       "payload": {"type": "user_message",
                                   "message": "no, the client retries internally already"}}])

        # 1. extract-basic: expected candidates with expected kinds
        # (always/never lead decisions, prefer a preference; corrections
        # only right after an assistant action).
        data = extract_data(proj, projects_dir, codex_dir, since_hours=24, limit=40)
        got = {(c["kind"], c["text"]) for c in data["candidates"]}
        check("extract:decision",
              ("decision", "let's use ruff for linting in this repo") in got, str(got))
        check("extract:correction",
              ("correction", "don't touch the generated fixtures under tests/golden") in got)
        check("extract:correction-redacted",
              ("correction", "no, the deploy token <redacted:github-token> "
                             "must never be committed") in got)
        check("extract:always-decision",
              ("decision", "always run make check before pushing anything") in got)
        check("extract:preference",
              ("preference", "i prefer small focused commits in this repo") in got)
        check("extract:counts", data["transcripts_scanned"] == 2
              and data["malformed_lines_skipped"] >= 1,
              "scanned=%s malformed=%s" % (data["transcripts_scanned"],
                                           data["malformed_lines_skipped"]))

        # 2. extract-noise: neither the noise turns nor the ungated
        # correction cues (session-opening / user-after-user) become
        # candidates.
        all_texts = " | ".join(c["text"] for c in data["candidates"])
        for frag in ("ok thanks", "postgres or sqlite", "command-name",
                     "meta turn", "sidechain turn", "snippet", "refactor the whole module",
                     "tabs everywhere", "templates directory", "tests/manual"):
            check("noise:%s" % frag.split()[0], frag not in all_texts, all_texts)

        # 3. extract-redaction: planted secrets never leave the script.
        rendered = redact(json.dumps(data))
        check("redact:anthropic-gone", _FAKE_ANTHROPIC not in rendered)
        check("redact:github-gone", _FAKE_GITHUB not in rendered)
        check("redact:anthropic-marker", "<redacted:anthropic-key>" in rendered)
        check("redact:github-marker", "<redacted:github-token>" in rendered)
        check("redact:pre-cap", all(_FAKE_ANTHROPIC not in c["text"]
                                    and _FAKE_GITHUB not in c["text"]
                                    for c in data["candidates"]))

        # 4. extract-codex: the rollout's user_message is a candidate with
        # the rollout's uuid as session id.
        codex_cands = [c for c in data["candidates"]
                       if c["text"] == "we should pin python 3.11 in ci"]
        check("codex:candidate", len(codex_cands) == 1)
        if codex_cands:
            check("codex:session-id",
                  codex_cands[0]["provenance"]["session_id"] == codex_uuid,
                  codex_cands[0]["provenance"]["session_id"])
        check("codex:gated-correction",
              ("correction", "no, the client retries internally already") in got)

        # 5. extract-odd: missing dirs are safe, empty result, no crash.
        empty = extract_data(proj, tmp / "nope-a", tmp / "nope-b")
        check("odd:missing-dirs", empty["candidates"] == []
              and empty["transcripts_scanned"] == 0)

        # 6. slug munging + slug-first discovery: every non-alphanumeric
        # char becomes '-', colliding paths share the slug dir and the
        # recorded cwd disambiguates them, and transcripts outside the slug
        # dir are never even parsed.
        check("slug:munge", slug_for("/home/user/my_proj.x") == "-home-user-my-proj-x",
              slug_for("/home/user/my_proj.x"))
        twin_a = tmp / "twin.proj"
        twin_b = tmp / "twin-proj"
        twin_a.mkdir()
        twin_b.mkdir()
        check("slug:collision-shared",
              slug_for(str(twin_a.resolve())) == slug_for(str(twin_b.resolve())))
        coll_dir = projects_dir / slug_for(str(twin_a.resolve()))
        sid_a = "aaaa0000-0000-0000-0000-000000000001"
        sid_b = "aaaa0000-0000-0000-0000-000000000002"
        _write_jsonl(coll_dir / (sid_a + ".jsonl"),
                     [_claude_rec(0, sid_a, str(twin_a.resolve()),
                                  "let's use postgres for the twin-a store")])
        _write_jsonl(coll_dir / (sid_b + ".jsonl"),
                     [_claude_rec(0, sid_b, str(twin_b.resolve()),
                                  "let's use sqlite for the twin-b store")])
        twin_texts = [c["text"] for c in
                      extract_data(twin_a, projects_dir, codex_dir)["candidates"]]
        check("slug:cwd-disambiguates",
              "let's use postgres for the twin-a store" in twin_texts
              and "let's use sqlite for the twin-b store" not in twin_texts,
              str(twin_texts))
        stray_sid = "bbbb0000-0000-0000-0000-000000000001"
        _write_jsonl(projects_dir / "not-the-slug" / (stray_sid + ".jsonl"),
                     [_claude_rec(0, stray_sid, proj,
                                  "let's use yarn for the stray transcript")])
        stray = extract_data(proj, projects_dir, codex_dir)
        check("slug:dir-prefilter",
              all("stray transcript" not in c["text"] for c in stray["candidates"]))

        # 7. parity caps (Swift twin): only the last TAIL_BYTES of each
        # transcript are read (leading partial line dropped), and only the
        # MAX_SESSIONS most recently modified transcripts are scanned.
        cap_proj = tmp / "capproj"
        cap_proj.mkdir()
        cproj = str(cap_proj.resolve())
        big_sid = "cccc0000-0000-0000-0000-000000000001"
        filler = "filler " * 300
        big_recs = [_claude_rec(0, big_sid, cproj,
                                "let's use mercurial before the tail window")]
        big_recs += [_claude_rec(i % 60, big_sid, cproj, filler) for i in range(1, 200)]
        big_recs.append(_claude_rec(59, big_sid, cproj,
                                    "let's use git lfs inside the tail window"))
        _write_jsonl(projects_dir / slug_for(cproj) / (big_sid + ".jsonl"), big_recs)
        cap_texts = [c["text"] for c in
                     extract_data(cap_proj, projects_dir, codex_dir)["candidates"]]
        check("tail:inside", "let's use git lfs inside the tail window" in cap_texts,
              str(cap_texts))
        check("tail:outside",
              "let's use mercurial before the tail window" not in cap_texts)
        many_proj = tmp / "manyproj"
        many_proj.mkdir()
        mproj = str(many_proj.resolve())
        many_dir = projects_dir / slug_for(mproj)
        now_ts = time.time()
        for i in range(MAX_SESSIONS + 5):
            msid = "dddd0000-0000-0000-0000-%012d" % i
            mp = many_dir / (msid + ".jsonl")
            _write_jsonl(mp, [_claude_rec(0, msid, mproj,
                                          "let's use plugin %02d for the session cap" % i)])
            os.utime(mp, (now_ts - (MAX_SESSIONS + 5 - i) * 60,) * 2)
        many = extract_data(many_proj, projects_dir, codex_dir, limit=100)
        many_texts = [c["text"] for c in many["candidates"]]
        check("cap:sessions", many["transcripts_scanned"] == MAX_SESSIONS
              and len(many_texts) == MAX_SESSIONS,
              "scanned=%s candidates=%d" % (many["transcripts_scanned"], len(many_texts)))
        check("cap:newest-kept",
              "let's use plugin 24 for the session cap" in many_texts
              and "let's use plugin 00 for the session cap" not in many_texts,
              str(many_texts))

        # 8. early exit: scanning stops the moment the candidate limit is
        # hit (messages_scanned proves the walk ended early).
        lim = extract_data(many_proj, projects_dir, codex_dir, limit=2)
        check("limit:early-exit", len(lim["candidates"]) == 2
              and lim["messages_scanned"] == 2,
              "candidates=%d messages=%d" % (len(lim["candidates"]),
                                             lim["messages_scanned"]))
        zero = extract_data(many_proj, projects_dir, codex_dir, limit=0)
        check("limit:zero", zero["candidates"] == [] and zero["messages_scanned"] == 0)

        # 9. merge-initial: curate three candidates, first iteration.
        brain_dir = project / ".supervisor" / "second-brain"
        curated = [c for c in data["candidates"] if c["text"] in (
            "let's use ruff for linting in this repo",
            "don't touch the generated fixtures under tests/golden",
            "always run make check before pushing anything")]
        check("curate:three", len(curated) == 3)
        delta1 = merge_brain(brain_dir, curated)
        check("merge1:delta", (delta1["iteration"], delta1["added"], delta1["confirmed"],
                               delta1["merged"], delta1["retired"], delta1["active_total"])
              == (1, 3, 0, 0, 0, 3), str(delta1))
        memory = (brain_dir / "memory.md").read_text(encoding="utf-8")
        check("merge1:artifacts", (brain_dir / "brain.json").exists()
              and (brain_dir / "iteration-log.md").exists())
        check("merge1:memory-text", "let's use ruff for linting in this repo" in memory)
        check("merge1:memory-note", "REGENERATED FILE" in memory
              and "brain.json is the source of truth" in memory)
        check("merge1:memory-sections", all("## " + _KIND_TITLES[k] in memory for k in KINDS)
              and "## Retired" in memory)
        log = (brain_dir / "iteration-log.md").read_text(encoding="utf-8")
        check("merge1:log-row", "| 1 |" in log and "| 3 | 0 | 0 | 0 | 3 |" in log)

        # 10. merge-idempotent: identical stdin again confirms, adds nothing.
        ids_before = [e["id"] for e in load_brain(brain_dir)["entries"]]
        delta2 = merge_brain(brain_dir, curated)
        check("merge2:delta", (delta2["iteration"], delta2["added"], delta2["confirmed"],
                               delta2["merged"], delta2["active_total"])
              == (2, 0, 3, 0, 3), str(delta2))
        state = load_brain(brain_dir)
        check("merge2:ids-stable", [e["id"] for e in state["entries"]] == ids_before)
        check("merge2:confidence-bumped",
              all(e["confidence"] == "medium" for e in state["entries"]), str(state["entries"]))
        check("merge2:last-confirmed",
              all(e["last_confirmed_iteration"] == 2 for e in state["entries"]))

        # 11. containment merge, both directions plus confirm-via-merged-id.
        cbrain = tmp / "containment-brain"
        merge_brain(cbrain, [{"kind": "decision", "text": "use ruff for linting"}])
        d = merge_brain(cbrain, [{"kind": "decision",
                                  "text": "use ruff for linting, not flake8"}])
        check("contain:supersede", (d["added"], d["merged"], d["active_total"]) == (0, 1, 1),
              str(d))
        st = load_brain(cbrain)
        old = [e for e in st["entries"] if e["text"] == "use ruff for linting"][0]
        new = [e for e in st["entries"] if "not flake8" in e["text"]][0]
        check("contain:old-merged", old["status"] == "merged"
              and old.get("merged_into") == new["id"])
        check("contain:history-carried", new["first_seen_iteration"] == 1
              and new["last_confirmed_iteration"] == 2 and new["confidence"] == "medium")
        d = merge_brain(cbrain, [{"kind": "decision", "text": "ruff for linting, not flake8"}])
        check("contain:subsumed", (d["added"], d["merged"], d["active_total"]) == (0, 1, 1),
              str(d))
        st = load_brain(cbrain)
        new = [e for e in st["entries"] if e["status"] == "active"][0]
        check("contain:subsumed-confirms", new["last_confirmed_iteration"] == 3
              and new["confidence"] == "high")
        d = merge_brain(cbrain, [{"kind": "decision", "text": "use ruff for linting"}])
        check("contain:merged-id-redirects", d["confirmed"] == 1 and d["added"] == 0
              and d["active_total"] == 1, str(d))
        check("contain:kind-scoped", merge_brain(
            cbrain, [{"kind": "preference", "text": "use ruff for linting"}])["added"] == 1)

        # 12. containment guards: a sub-MIN_CONTAINMENT containment is
        # coincidence ("use ruff" must NOT be absorbed by the unrelated
        # ruffles fact), and one entry gains at most one confidence step per
        # iteration - including a brand-new entry containment-hit later in
        # the SAME batch, and two subsumed fragments hitting one host.
        gbrain = tmp / "guard-brain"
        merge_brain(gbrain, [{"kind": "decision",
                              "text": "never use ruffles brand assets in the docs"}])
        d = merge_brain(gbrain, [{"kind": "decision", "text": "use ruff"}])
        check("guard:min-containment", (d["added"], d["merged"]) == (1, 0), str(d))
        st = load_brain(gbrain)
        check("guard:own-entry", any(e["text"] == "use ruff" and e["status"] == "active"
                                     for e in st["entries"]), str(st["entries"]))
        bbrain = tmp / "bump-brain"
        d = merge_brain(bbrain, [
            {"kind": "decision", "text": "use black for formatting in ci"},
            {"kind": "decision", "text": "use black for formatting"},
        ])
        st = load_brain(bbrain)
        host = [e for e in st["entries"] if e["status"] == "active"][0]
        check("guard:new-then-contained", (d["added"], d["merged"]) == (1, 1), str(d))
        check("guard:no-bump-same-batch", host["confidence"] == "low", host["confidence"])
        d = merge_brain(bbrain, [
            {"kind": "decision", "text": "use black for formatting"},
            {"kind": "decision", "text": "black for formatting in ci"},
        ])
        st = load_brain(bbrain)
        host = [e for e in st["entries"] if e["status"] == "active"][0]
        check("guard:two-fragments", (d["added"], d["merged"]) == (0, 2), str(d))
        check("guard:one-step-per-batch", host["confidence"] == "medium",
              host["confidence"])

        # 13. confirm/retire across 6 simulated iterations: A confirmed every
        # time, B never after iteration 1 -> retired exactly at iteration 6.
        rbrain = tmp / "retire-brain"
        entry_a = {"kind": "decision", "text": "deploys go through the staging lane first"}
        entry_b = {"kind": "gotcha", "text": "ci runners have no network during tests"}
        d = merge_brain(rbrain, [entry_a, entry_b])
        check("retire:it1", (d["added"], d["active_total"]) == (2, 2))
        for i in range(2, 6):
            d = merge_brain(rbrain, [entry_a])
            check("retire:it%d" % i, (d["confirmed"], d["retired"], d["active_total"])
                  == (1, 0, 2), str(d))
        d = merge_brain(rbrain, [entry_a])
        check("retire:it6", (d["confirmed"], d["retired"], d["active_total"]) == (1, 1, 1),
              str(d))
        st = load_brain(rbrain)
        b = [e for e in st["entries"] if e["kind"] == "gotcha"][0]
        a = [e for e in st["entries"] if e["kind"] == "decision"][0]
        check("retire:status", b["status"] == "retired" and b["retired_iteration"] == 6)
        check("retire:confidence-capped", a["confidence"] == "high")
        mem = (rbrain / "memory.md").read_text(encoding="utf-8")
        check("retire:memory-section",
              "~~ci runners have no network during tests~~" in mem)
        check("retire:revive", merge_brain(rbrain, [entry_b])["confirmed"] == 1
              and load_brain(rbrain)["entries"][-1] is not None)
        st = load_brain(rbrain)
        b = [e for e in st["entries"] if e["kind"] == "gotcha"][0]
        check("retire:revived-active", b["status"] == "active"
              and "retired_iteration" not in b)

        # 14. id determinism: normalization folds case/whitespace/trailing
        # punctuation; provenance carries no weight.
        check("id:stable", entry_id("decision", "Use Ruff,  not flake8.")
              == entry_id("decision", "use ruff, not flake8"))
        check("id:kind-scoped", entry_id("decision", "x y z") != entry_id("gotcha", "x y z"))
        check("id:shape", re.fullmatch(r"[0-9a-f]{12}", entry_id("decision", "abc")) is not None)

        # 15. text cap: redaction happens before the 400-char truncation.
        long_text = ("the key is %s and " % _FAKE_ANTHROPIC) + "pad " * 120
        clean = sanitize_curated({"kind": "gotcha", "text": long_text})
        check("cap:length", clean is not None and len(clean[1]) <= TEXT_CAP)
        check("cap:redacted-first", clean is not None
              and _FAKE_ANTHROPIC not in clean[1] and "<redacted:anthropic-key>" in clean[1])

        # 16. odd merge payloads: empty stdin, malformed JSON, bad kinds,
        # [] as a valid aging iteration, corrupt ledger never overwritten;
        # plus: extract without the sibling parsers is a hard, clear error
        # while merge (which never needs them) keeps working.
        for bad in ("", "   ", "{oops", '{"no_entries_key": 1}', '"just a string"'):
            try:
                parse_curated(bad)
                check("odd:parse:%r" % bad[:8], False, "should have raised")
            except ValueError:
                check("odd:parse:%r" % bad[:8], True)
        d = merge_brain(rbrain, [{"kind": "bogus", "text": "x y z w"}, "not a dict",
                                 {"kind": "decision"}, {"kind": "decision", "text": ""}])
        check("odd:skipped-invalid", d["skipped_invalid"] == 4 and d["added"] == 0, str(d))
        before = load_brain(rbrain)
        d = merge_brain(rbrain, [])
        check("odd:empty-list-ages", d["iteration"] == before["iteration"] + 1
              and d["added"] == 0 and d["confirmed"] == 0, str(d))
        corrupt = tmp / "corrupt-brain"
        corrupt.mkdir()
        (corrupt / "brain.json").write_text("{this is not json", encoding="utf-8")
        try:
            merge_brain(corrupt, [{"kind": "decision", "text": "x y z w"}])
            check("odd:corrupt-raises", False, "should have raised")
        except ValueError:
            check("odd:corrupt-raises", True)
        check("odd:corrupt-untouched",
              (corrupt / "brain.json").read_text(encoding="utf-8") == "{this is not json"
              and not (corrupt / "memory.md").exists())
        global _TAIL
        saved_tail = _TAIL
        _TAIL = None
        try:
            try:
                extract_data(proj, projects_dir, codex_dir)
                check("siblings:extract-raises", False, "should have raised")
            except RuntimeError as exc:
                check("siblings:extract-raises", "tail_session.py" in str(exc), str(exc))
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                rc = cmd_extract(argparse.Namespace(
                    project=proj, projects_dir=str(projects_dir),
                    codex_dir=str(codex_dir), since_hours=24.0, limit=40,
                    no_codex=False))
            check("siblings:extract-rc", rc == 1 and "tail_session.py" in err.getvalue(),
                  err.getvalue())
            check("siblings:merge-works", merge_brain(
                tmp / "nosib-brain",
                [{"kind": "decision", "text": "merge runs without the parsers"}])["added"] == 1)
        finally:
            _TAIL = saved_tail

        # 17. show: prints the paths and the iteration summary.
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_show(argparse.Namespace(brain_dir=str(brain_dir)))
        out = buf.getvalue()
        check("show:rc", rc == 0)
        check("show:content", "memory.md" in out and "iteration: 2" in out
              and "active:    3" in out, out)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_show(argparse.Namespace(brain_dir=str(tmp / "no-brain")))
        check("show:missing", rc == 1 and "no second brain" in buf.getvalue())

    groups = 17
    if failures:
        for f in failures:
            print("FAIL %s" % f)
        print("self-test: %d case groups (%d checks), %d FAILURES"
              % (groups, checks[0], len(failures)))
        return 1
    print("self-test: %d case groups (%d checks), all passed" % (groups, checks[0]))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--self-test" in argv:
        return self_test()
    ap = argparse.ArgumentParser(
        description="Second brain: capture, merge, and measure a project memory "
                    "distilled from your own agent sessions.")
    sub = ap.add_subparsers(dest="command")

    ex = sub.add_parser("extract", help="emit redacted candidate entries as JSON")
    ex.add_argument("--project", default=None, help="project directory (default: cwd)")
    ex.add_argument("--since-hours", type=float, default=24.0,
                    help="transcript activity window (default 24)")
    ex.add_argument("--limit", type=int, default=40, help="max candidates (default 40)")
    ex.add_argument("--projects-dir", default=None, help="override ~/.claude/projects")
    ex.add_argument("--codex-dir", default=None, help="override ~/.codex/sessions")
    ex.add_argument("--no-codex", action="store_true", help="skip Codex rollouts")
    ex.set_defaults(func=cmd_extract)

    default_brain = str(Path.cwd() / ".supervisor" / "second-brain")
    mg = sub.add_parser("merge", help="merge curated entries (JSON on stdin) into the brain")
    mg.add_argument("--brain-dir", default=default_brain,
                    help="brain directory (default: ./.supervisor/second-brain)")
    mg.set_defaults(func=cmd_merge)

    sh = sub.add_parser("show", help="print the memory location and iteration summary")
    sh.add_argument("--brain-dir", default=default_brain,
                    help="brain directory (default: ./.supervisor/second-brain)")
    sh.set_defaults(func=cmd_show)

    args = ap.parse_args(argv)
    if not getattr(args, "func", None):
        ap.print_usage(sys.stderr)
        print("error: a subcommand (extract, merge, show) or --self-test is required",
              file=sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
