# Security policy

## Supported versions

Only the latest minor release of Supervisor receives security fixes
during the v0.1.x line.

| Version | Supported          |
|---------|--------------------|
| 0.1.x   | :white_check_mark: |
| < 0.1.0 | :x:                |

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
the user's Anthropic API key, the user's session transcripts, the
contents of their watched JSONL files, or trace-log contents beyond
the local filesystem. The redaction layer is part of this scope — if
a pattern lets sensitive data through to `api.anthropic.com`, that's
a security bug.

**Out of scope** — vulnerabilities in third-party dependencies (GRDB,
KeychainAccess), in Anthropic's API itself, in Claude Code's session
log format, or in macOS frameworks Supervisor builds on. File those
upstream. The redactor's pattern set evolves at the speed of bug
reports — patterns that don't yet exist aren't a security bug, they're
a feature request.
