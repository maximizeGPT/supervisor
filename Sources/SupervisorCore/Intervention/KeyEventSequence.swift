// KeyEventSequence.swift, v0.9.x (modifier-strand crash fix).
//
// A PURE, testable description of the ordered synthetic key events an
// injection posts. No CoreGraphics here, just plain data, so the
// modifier-handling invariants can be unit-tested without driving the
// live event tap. CGEventInjector turns each KeyEvent into a real
// CGEvent and posts it.
//
// WHY THIS EXISTS (the bug it fixes):
// The old chord path posted a key-DOWN and a key-UP that BOTH carried the
// modifier flags (e.g. .maskCommand on both the V-down AND the V-up of a
// Cmd-V), and never posted a separate modifier release. The window server
// then kept Command latched: a later keystroke (or an interrupted
// sequence) became Cmd+<key>, most visibly Cmd+Tab, which cycles the
// macOS app switcher for seconds and hijacks the keyboard, and could crash
// the driven session. The builder below makes the modifier lifecycle
// explicit and self-closing so a modifier is NEVER stranded:
//
//   1. press modifier(s)   (flags accumulate)
//   2. press the key       (key-down carries the live modifier flags)
//   3. release the key     (key-up carries the live modifier flags)
//   4. release modifier(s) (flags drain back to empty)
//
// Plus a "release all modifiers" guard emitted at the START and END of
// every sequence, so even if a PREVIOUS injection was interrupted
// mid-chord and left a modifier down, this sequence clears it before
// typing and clears it again after.

import CoreGraphics

/// The four modifiers Supervisor ever synthesizes or has to defensively
/// release. Each maps to its virtual key code and its CGEventFlags bit so
/// the builder can both press/release the physical modifier key AND keep
/// the running flag mask correct on the keys pressed while it is held.
public enum SyntheticModifier: CaseIterable, Sendable {
    case command
    case option
    case control
    case shift

    /// Left-hand virtual key code for the modifier (kVK_Command, etc.).
    public var virtualKey: CGKeyCode {
        switch self {
        case .command: return 55  // kVK_Command
        case .option:  return 58  // kVK_Option
        case .control: return 59  // kVK_Control
        case .shift:   return 56  // kVK_Shift
        }
    }

    /// The device-independent flag bit this modifier contributes.
    public var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .control: return .maskControl
        case .shift:   return .maskShift
        }
    }
}

/// One synthetic key event: which virtual key, down or up, and the FULL
/// modifier-flag mask that must be live on the event when it is posted.
/// `isModifier` marks the events that press/release a modifier key itself
/// (vs. an ordinary key pressed while a modifier is held) so tests can
/// reason about the modifier lifecycle.
public struct KeyEvent: Equatable, Sendable {
    public let virtualKey: CGKeyCode
    public let keyDown: Bool
    public let flags: CGEventFlags
    public let isModifier: Bool

    public init(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags, isModifier: Bool) {
        self.virtualKey = virtualKey
        self.keyDown = keyDown
        self.flags = flags
        self.isModifier = isModifier
    }
}

/// Builds the ordered KeyEvent list for an injection. Pure: no posting, no
/// CoreGraphics side effects. The poster (CGEventInjector) walks the list
/// and posts each event; this type owns the ORDERING and the MODIFIER
/// LIFECYCLE so the invariants live in one tested place.
public struct KeyEventSequence {

    /// The virtual key code that, with Command held, triggers the macOS app
    /// switcher (Cmd+Tab). The builder asserts (in debug) that it never
    /// emits this combination, so an injection can't accidentally drive the
    /// switcher.
    public static let tabVirtualKey: CGKeyCode = 48

    /// Emit key-up events for EVERY modifier, with a draining flag mask, to
    /// guarantee nothing is left held. Posted both before a sequence (in case
    /// a prior injection was interrupted mid-chord) and after it (so this
    /// sequence is self-closing even if it threw partway). Ordered command,
    /// option, control, shift; each event's flags reflect the modifiers still
    /// nominally down AFTER that release, ending at empty.
    public static func releaseAllModifiers() -> [KeyEvent] {
        // Start from "all four nominally down" and drain one per event so the
        // final event carries an empty mask, the post-condition tests assert.
        var remaining: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        var events: [KeyEvent] = []
        for mod in SyntheticModifier.allCases {
            remaining.remove(mod.flag)
            events.append(KeyEvent(virtualKey: mod.virtualKey, keyDown: false, flags: remaining, isModifier: true))
        }
        return events
    }

    /// A single chord: hold `modifiers`, tap `virtualKey`, release. Wrapped in
    /// release-all guards on both ends. With no modifiers this is a plain
    /// keytap (e.g. Return) that still gets the defensive guards.
    public static func chord(virtualKey: CGKeyCode, modifiers: [SyntheticModifier]) -> [KeyEvent] {
        precondition(
            !(virtualKey == tabVirtualKey && modifiers.contains(.command)),
            "refusing to synthesize Cmd+Tab, that drives the app switcher"
        )
        var events: [KeyEvent] = releaseAllModifiers()
        events.append(contentsOf: chordCore(virtualKey: virtualKey, modifiers: modifiers))
        events.append(contentsOf: releaseAllModifiers())
        return events
    }

    /// Per-character unicode typing. Each character is its own down/up pair on
    /// virtual key 0 (the unicode string is attached by the poster). No
    /// modifiers are ever held during text typing, so every event carries an
    /// empty flag mask, this is what guarantees a stray modifier from a prior
    /// event can never combine with a typed character. Optionally appends a
    /// Return. Wrapped in release-all guards on both ends.
    public static func typing(scalarCount: Int, appendReturn: Bool) -> [KeyEvent] {
        var events: [KeyEvent] = releaseAllModifiers()
        for _ in 0..<max(0, scalarCount) {
            events.append(KeyEvent(virtualKey: 0, keyDown: true, flags: [], isModifier: false))
            events.append(KeyEvent(virtualKey: 0, keyDown: false, flags: [], isModifier: false))
        }
        if appendReturn {
            events.append(contentsOf: chordCore(virtualKey: 36, modifiers: []))  // Return, no modifiers
        }
        events.append(contentsOf: releaseAllModifiers())
        return events
    }

    /// The press-key-release core of a chord WITHOUT the surrounding guards:
    /// press each modifier (flags accumulate), key-down + key-up while the
    /// modifiers are held (both carry the live mask), then release the
    /// modifiers in reverse order (flags drain back to empty).
    static func chordCore(virtualKey: CGKeyCode, modifiers: [SyntheticModifier]) -> [KeyEvent] {
        var events: [KeyEvent] = []
        var live: CGEventFlags = []
        // Press modifiers, accumulating the flag mask.
        for mod in modifiers {
            live.insert(mod.flag)
            events.append(KeyEvent(virtualKey: mod.virtualKey, keyDown: true, flags: live, isModifier: true))
        }
        // Tap the key while the modifiers are held.
        events.append(KeyEvent(virtualKey: virtualKey, keyDown: true, flags: live, isModifier: false))
        events.append(KeyEvent(virtualKey: virtualKey, keyDown: false, flags: live, isModifier: false))
        // Release modifiers in reverse order, draining the flag mask to empty.
        for mod in modifiers.reversed() {
            live.remove(mod.flag)
            events.append(KeyEvent(virtualKey: mod.virtualKey, keyDown: false, flags: live, isModifier: true))
        }
        return events
    }
}
