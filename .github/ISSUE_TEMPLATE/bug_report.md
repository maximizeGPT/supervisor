---
name: Bug report
about: Something Supervisor did that you didn't expect
title: "[BUG] "
labels: bug
assignees: ''
---

## What happened

A clear description of the surprise. One or two sentences.

## What you expected

What Supervisor should have done instead. One or two sentences.

## Reproduction steps

1.
2.
3.

## Trace log

Paste the last ~50 lines of `~/Library/Logs/Supervisor/supervisor.log`
covering the moment the surprise happened. Trim or redact any line you
don't want public — the trace log is local-only and isn't filtered.

```
<paste here>
```

## Environment

- macOS version: <output of `sw_vers -productVersion`>
- Supervisor version: <e.g. v0.1.0, or commit SHA if built from main>
- Claude Code version: <if reproducible against a specific version>

## Anything else

Optional. Screenshots, related issues, hypotheses.
