# Security policy

## Supported versions

Only the latest minor release of Supervisor receives security fixes.

| Version | Supported          |
|---------|--------------------|
| 0.4.x   | :white_check_mark: |
| < 0.4.0 | :x:                |

## Reporting a vulnerability

**Email rayedwasif@hotmail.com.** Do not file a public GitHub issue for
security reports — that just publishes the vulnerability before there's
a fix.

A useful report includes: a description of the issue, the affected
Supervisor version, repro steps, and (if relevant) a redacted trace
log snippet from `~/Library/Logs/Supervisor/supervisor.log`. I'll
acknowledge within 48 hours and ship a patch on the v0.1.x line if
the issue confirms.

## Scope

**In scope** — anything that lets the published Supervisor binary leak
the user's provider API keys, the user's session transcripts, the
contents of their watched JSONL files, or trace-log contents beyond
the local filesystem. The redaction layer is part of this scope — if
a pattern lets sensitive data through to a model provider, that's a
security bug.

The remote escalation channel is in scope on both of its sensitive
edges:

- **The webhook URL is a bearer credential.** Anyone holding it can
  post as the user (and on ntfy, the topic URL is also readable by
  anyone holding it). Anything that exposes the stored URL — writing
  it to the trace log, an error message, config.yaml, a session
  report, or the UI — is a security bug. It belongs only in the
  Keychain.
- **Payload leakage past the detail level.** This is the exhaustive
  list of what each level sends, because "quotes nothing from the
  session" was too loose to hold anyone to.

  At `detail: minimal`, the message carries: Supervisor's own verdict
  and the intervention kind, the rubric category and severity, the
  first 8 characters of the session UUID, and **the basename of the
  session's working directory** (the folder name only, never the path).
  It carries no command text, no model reasoning, no file contents and
  no transcript.

  The folder name is deliberate: with several sessions running it is
  the only thing in the message that tells the owner which one is
  blocked, and without it people set `detail: full` to get their
  bearings, which sends strictly more. But it can itself be sensitive:
  a consultant working in `~/work/acme-bankruptcy` publishes that name
  to their webhook. If that is your situation, work in a neutrally
  named directory or leave `remote_notify.enabled` off. The basename
  passes through the same redaction layer as everything else, which
  catches token-shaped and credential-shaped names, not meaningful
  ones.

  At `detail: full`, the message adds the triggering command and the
  plain-language reasoning, both through the same redaction layer the
  model calls use.

  Anything crossing the network beyond the list above for the level in
  force is a security bug.

**Out of scope** — vulnerabilities in third-party dependencies (GRDB,
KeychainAccess), in Anthropic's API itself, in Claude Code's session
log format, or in macOS frameworks Supervisor builds on. File those
upstream. The redactor's pattern set evolves at the speed of bug
reports — patterns that don't yet exist aren't a security bug, they're
a feature request.
