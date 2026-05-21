# Spike 1 — kqueue reliability on active JSONL

## What it tested

Whether `DispatchSourceFileSystemObject` (the Swift wrapper around macOS
`kqueue`) reliably fires for every append to a JSONL file that is being
actively written by another process (Claude Code).

The realistic worry: some macOS versions / file system combinations have
been subtly different about whether `EVFILT_VNODE` events coalesce or
get dropped under append-heavy load. If kqueue ever misses an event
during a write burst, `SessionTail` would silently drop lines and
Supervisor would observe a fractured event stream.

## How it tested it

`kqueue_spike.swift` opens the target file with `O_EVTONLY`, seeks to
EOF, registers a `DispatchSource` on the FD with mask
`write | extend | delete | rename | attrib`, and on every event reads to
EOF, counting bytes and lines.

Run for 75s against one of my own live Claude Code session JSONLs
(`a00b739d-...jsonl`) while I made varied tool calls (single-line bash,
multi-line bash, paused intervals, back-to-back bursts).

## What it found

| Metric | Spike captured | Ground truth | Match |
|---|---|---|---|
| Bytes appended | 38,194 | 38,194 | ✅ exact |
| Lines appended | 26 | 26 | ✅ exact |
| Events fired | 8 | — | (kqueue coalesces; expected) |
| Missed events | 0 | — | ✅ none |
| Handler latency | < 5ms from append to handler entry | — | ✅ tight |

Observations:

- Events fired with mask `write|extend` — file is being **extended**, not
  rewritten in place. Means we don't need to handle truncation/rotation
  in v0.1 unless Claude Code starts rotating session files.
- kqueue **coalesces bursts**: one event came in with `this_bytes=0`
  because two writes arrived inside the same notification cycle (3ms
  apart). This is normal kqueue behavior. The spike's "read until EOF on
  every event, regardless of byte count" pattern handles it correctly.
- No `delete` / `rename` events fired during normal use. Session files
  are append-only for their lifetime.

## What v0.1.0 does because of this

- `SessionTail` is implemented on `DispatchSourceFileSystemObject` only —
  no polling fallback path was ever needed.
- The read-loop documents the coalescing behavior explicitly:
  > read until EOF on every event, even if data == 0; kqueue coalesces
  > bursts and the only safe contract is "something changed; drain
  > whatever's new."

## What this spike does NOT cover

- Behavior across an unmount / external-disk scenario. Not in scope —
  session files always live on `~/.claude/`.
- Behavior across a `sudo rm` of the file mid-tail. The `delete`/`rename`
  events would fire and the source would cancel; tail would have to be
  re-established. v0.1 doesn't recover from this case automatically — we
  rebuild tails on `NSWorkspace.didWakeNotification` and on the 60-second
  watchdog, which would catch it within a minute.
- Behavior under disk pressure or low memory. Untested.

## When to re-run

Re-run this spike if:
- We upgrade past macOS 27 (or whatever the next major is).
- Claude Code changes its session-file write pattern (e.g. starts using
  `mmap` instead of `write`).
- A user reports "Supervisor is missing events" — first thing to verify.

## Artifacts

- `kqueue_spike.swift` — source
- `spike1.log` — captured run output, kept for reference
