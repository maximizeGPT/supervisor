# CGEvent bypasses Accessibility — research note

**Status:** observed in passing, NOT yet a verified spike. Queued for a
dedicated test before any inject-intervention code depends on it.

**Why this matters:** the v0.1.2/3 onboarding flow asks the user to grant
Accessibility because the inject intervention (still queued, originally
v0.1.2 scope) is documented as needing AX to deliver text into a terminal.
If CGEventPost against the HID event tap reliably bypasses AX, the
onboarding's AX-permission step may be unnecessary for inject — which
means users who skipped onboarding's AX step (a common path on unsigned
v0.1.x builds where macOS keeps invalidating the grant) may still get the
inject surface working.

This would be a material change to the v0.1.x trust story. Hence the note.
Do not rely on this until the scratch test below has been run.

## What was observed

During the v0.1.3 onboarding audit on 2026-05-23, an osascript-driven
synthetic click stopped working mid-session with error code -25211
(`"osascript is not allowed assistive access"`). The session's parent
process — Cowork / Claude Code — had been granted Accessibility earlier
in the day; sometime around when the user opened System Settings →
Privacy & Security → Accessibility to look at Supervisor's AX entry,
the grant for osascript/its parent appears to have been invalidated or
session-scoped out.

A workaround was needed to click the onboarding's Skip button without
re-granting AX. The Swift one-liner below succeeded immediately:

```swift
import CoreGraphics
import Foundation
let p = CGPoint(x: 750, y: 513)
let down = CGEvent(mouseEventSource: nil,
                   mouseType: .leftMouseDown,
                   mouseCursorPosition: p,
                   mouseButton: .left)
let up   = CGEvent(mouseEventSource: nil,
                   mouseType: .leftMouseUp,
                   mouseCursorPosition: p,
                   mouseButton: .left)
down?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
up?.post(tap: .cghidEventTap)
```

The click landed in Supervisor's onboarding window, the Skip button
fired, the onboarding state advanced to the notif-check step. All this
**with AX explicitly revoked** for the calling process — confirmed by
the `osascript` failure preceding the Swift snippet's success.

Specific API: `CGEventCreate(MouseEvent|KeyboardEvent)` → `CGEventPost`
against `.cghidEventTap`. The HID event tap is the lowest-level tap in
the Quartz event chain, sitting at the kernel/system-event boundary.

## Implication (unverified)

If `CGEventPost(.cghidEventTap)` works without AX for **mouse clicks**,
it likely also works for **keyboard events** via `CGEventCreateKeyboardEvent`.
That's the API path the inject intervention would use to push corrective
text into a terminal session.

If verified, the inject design's AX dependency softens:

- AX is still needed for *reading* UI element state (e.g. detecting that
  Claude Code's terminal window is in vim/less TUI mode before injecting,
  per the DESIGN.md §5.2 fallback rules).
- AX is *not* needed for the actual keystroke delivery.

Which would mean the v0.1.x onboarding's AX-skip path produces a
**partially-degraded** inject surface (no TUI detection, but keystrokes
land), not a fully-degraded one (notify-only).

## The scratch test before this can be trusted

A dedicated test, NOT run yet. Specification:

1. Revoke Accessibility for Supervisor (System Settings → Privacy &
   Security → Accessibility → toggle Supervisor off, confirm it's
   off via `AXIsProcessTrustedWithOptions` returning false).
2. Run a minimal Swift script (this could live as
   `spikes/cgevent_inject_spike.swift`) that:
   - Opens a Terminal.app window with a known title or known
     command-line prompt.
   - Brings Terminal.app frontmost via `NSWorkspace.openApplication`.
   - Sends a sequence of `CGEventCreateKeyboardEvent` events spelling
     out, say, `echo hello-from-supervisor` and a Return.
3. Verify in Terminal.app that the keystrokes landed AND that the
   shell executed the command (i.e. the events weren't silently
   dropped by the OS event filter).
4. Capture the result. If keystrokes land → CGEvent bypasses AX for
   keystroke delivery; update the inject design's AX-dependency
   section accordingly. If keystrokes don't land → false alarm; the
   mouse-click case worked for a different reason and AX stays a
   hard dependency.

Edge cases to also cover in the test:

- Sending keystrokes when the target window is on a different Space —
  does Quartz auto-route, or does the user have to be on that Space?
- Sending into a TUI app (vim) vs a shell — same delivery path either
  way, but the user-visible outcome differs.
- Sending special keys (modifiers, function keys) — the simple
  printable-character path may work where a chord doesn't.

## Why this isn't a finding yet, just a note

One mouse-click event landing isn't the same as a string of keystrokes
landing in the right process. The test above is what turns the note
into a verified spike. Until then the inject design stays AX-dependent
as documented and the onboarding's AX-skip path is treated as fully
degrading to notify-only for the inject intervention.

Queued: v0.1.x inject task scope.
