// KeyEventSequenceTests.swift
//
// Locks the modifier-strand crash fix. The injector used to post a chord whose
// key-UP still carried the modifier flag and never released the modifier key,
// so the window server kept e.g. Command latched, a later keystroke became
// Cmd+Tab (app switcher cycling), hijacking the keyboard and crashing the
// driven session. These tests assert the pure sequence builder NEVER strands a
// modifier: every key-down is paired with a key-up, the cumulative modifier
// state returns to empty, and a release-all guard brackets every sequence.

import CoreGraphics
import XCTest
@testable import SupervisorCore

final class KeyEventSequenceTests: XCTestCase {

    // MARK: - Helpers

    /// Replays the sequence the way the window server would: a key keyDown
    /// marks it held, its keyUp clears it, and a keyUp for a key that is NOT
    /// held is a harmless no-op (the OS ignores it), which is exactly the
    /// defensive release-all guard's behavior. Returns the set of keys still
    /// HELD DOWN at the end, so a test can assert nothing was stranded.
    private func keysLeftDown(after events: [KeyEvent]) -> Set<CGKeyCode> {
        var down: Set<CGKeyCode> = []
        for ev in events {
            if ev.keyDown { down.insert(ev.virtualKey) }
            else { down.remove(ev.virtualKey) }  // no-op when not held, like the OS
        }
        return down
    }

    /// The modifier subset of `keysLeftDown`, as a flag mask, "which modifiers
    /// are still latched after the sequence runs."
    private func finalHeldModifiers(after events: [KeyEvent]) -> CGEventFlags {
        var held: CGEventFlags = []
        for vk in keysLeftDown(after: events) {
            held.insert(flagForModifierKey(vk))
        }
        return held
    }

    private func flagForModifierKey(_ vk: CGKeyCode) -> CGEventFlags {
        SyntheticModifier.allCases.first { $0.virtualKey == vk }?.flag ?? []
    }

    /// The real invariant: when the sequence finishes, NO key is left held
    /// down. (Extra key-UP events with no matching down are fine, they are
    /// no-ops, and the release-all guard relies on that, so this checks the
    /// end state, not a naive down/up count.)
    private func assertNothingLeftDown(_ events: [KeyEvent], file: StaticString = #filePath, line: UInt = #line) {
        let stuck = keysLeftDown(after: events)
        XCTAssertTrue(stuck.isEmpty, "keys left held down after sequence: \(stuck.sorted())", file: file, line: line)
    }

    // MARK: - releaseAllModifiers guard

    func testReleaseAllModifiersReleasesEveryModifierAndEndsClean() {
        let events = KeyEventSequence.releaseAllModifiers()
        // One key-up per modifier, all key-ups (a release-only guard).
        XCTAssertEqual(events.count, SyntheticModifier.allCases.count)
        XCTAssertTrue(events.allSatisfy { !$0.keyDown }, "the guard must be all key-UP events")
        XCTAssertTrue(events.allSatisfy { $0.isModifier }, "the guard only touches modifier keys")
        // Every modifier is covered exactly once.
        let touched = Set(events.map { $0.virtualKey })
        XCTAssertEqual(touched, Set(SyntheticModifier.allCases.map { $0.virtualKey }))
        // The last event carries an empty mask, the post-condition is "nothing held".
        XCTAssertEqual(events.last?.flags, [], "release-all must end with an empty flag mask")
    }

    // MARK: - chord: Cmd-V (the real paste path)

    func testCommandVChordPairsAndLeavesNoResidualModifier() {
        let events = KeyEventSequence.chord(virtualKey: 9, modifiers: [.command])  // Cmd-V
        assertNothingLeftDown(events)
        // After replaying the whole sequence, Command (and every modifier) is up.
        XCTAssertEqual(finalHeldModifiers(after: events), [], "Cmd-V must not strand Command down")
    }

    func testCommandVActuallyPressesAndReleasesCommandAroundTheKey() {
        let core = KeyEventSequence.chordCore(virtualKey: 9, modifiers: [.command])
        // Order: Cmd down, V down (with Cmd flag), V up (with Cmd flag), Cmd up.
        XCTAssertEqual(core.count, 4)
        XCTAssertEqual(core[0], KeyEvent(virtualKey: 55, keyDown: true, flags: .maskCommand, isModifier: true))
        XCTAssertEqual(core[1], KeyEvent(virtualKey: 9, keyDown: true, flags: .maskCommand, isModifier: false))
        XCTAssertEqual(core[2], KeyEvent(virtualKey: 9, keyDown: false, flags: .maskCommand, isModifier: false))
        XCTAssertEqual(core[3], KeyEvent(virtualKey: 55, keyDown: false, flags: [], isModifier: true))
        // The modifier key-UP drains the flag mask to empty, the bug was that
        // the modifier was never released at all.
        XCTAssertEqual(core.last?.flags, [])
    }

    func testChordIsBracketedByReleaseAllGuardsBothEnds() {
        let events = KeyEventSequence.chord(virtualKey: 9, modifiers: [.command])
        let guardCount = SyntheticModifier.allCases.count
        // First N events are the leading release-all guard...
        let leading = Array(events.prefix(guardCount))
        XCTAssertEqual(leading, KeyEventSequence.releaseAllModifiers(), "chord must open with a release-all guard")
        // ...and the last N are the trailing release-all guard.
        let trailing = Array(events.suffix(guardCount))
        XCTAssertEqual(trailing, KeyEventSequence.releaseAllModifiers(), "chord must close with a release-all guard")
    }

    // MARK: - Return (no-modifier chord still gets guarded)

    func testReturnChordHasNoHeldModifiersAndIsBalanced() {
        let events = KeyEventSequence.chord(virtualKey: 36, modifiers: [])  // Return
        assertNothingLeftDown(events)
        XCTAssertEqual(finalHeldModifiers(after: events), [])
        // The Return keytap itself (chordCore) must carry no modifier flag -
        // checked on the core, since the bracketing release-all guards
        // intentionally post key-UPs with a draining mask.
        let core = KeyEventSequence.chordCore(virtualKey: 36, modifiers: [])
        XCTAssertTrue(core.allSatisfy { $0.flags == [] }, "a no-modifier keytap must never set a modifier flag")
    }

    // MARK: - typing path

    func testTypingNeverHoldsAModifierAndStaysBalanced() {
        let events = KeyEventSequence.typing(scalarCount: 5, appendReturn: true)
        assertNothingLeftDown(events)
        XCTAssertEqual(finalHeldModifiers(after: events), [], "typing must never strand a modifier")
        // Every character event carries an empty mask, so a stray modifier can
        // never combine with a typed character (the Cmd+Tab failure mode).
        let charEvents = events.filter { !$0.isModifier && $0.virtualKey == 0 }
        XCTAssertEqual(charEvents.count, 10, "5 characters => 5 down + 5 up")
        XCTAssertTrue(charEvents.allSatisfy { $0.flags == [] }, "character events must carry no modifier flags")
    }

    func testTypingBracketedByReleaseAllGuards() {
        let events = KeyEventSequence.typing(scalarCount: 1, appendReturn: false)
        let guardCount = SyntheticModifier.allCases.count
        XCTAssertEqual(Array(events.prefix(guardCount)), KeyEventSequence.releaseAllModifiers())
        XCTAssertEqual(Array(events.suffix(guardCount)), KeyEventSequence.releaseAllModifiers())
    }

    func testEmptyTypingStillEmitsBothGuards() {
        let events = KeyEventSequence.typing(scalarCount: 0, appendReturn: false)
        XCTAssertEqual(events, KeyEventSequence.releaseAllModifiers() + KeyEventSequence.releaseAllModifiers(),
                       "even an empty type must clear modifiers before and after")
    }

    // MARK: - the app-switcher guard

    func testEveryBuiltSequenceNeverProducesCommandPlusTab() {
        // Cmd+Tab (Command held while virtualKey 48 is down) is the app-switcher
        // combination that caused the hijack. No built sequence may contain it.
        let sequences: [[KeyEvent]] = [
            KeyEventSequence.chord(virtualKey: 9, modifiers: [.command]),
            KeyEventSequence.chord(virtualKey: 36, modifiers: []),
            KeyEventSequence.typing(scalarCount: 3, appendReturn: true),
            KeyEventSequence.releaseAllModifiers(),
        ]
        for seq in sequences {
            for ev in seq where ev.keyDown && ev.virtualKey == KeyEventSequence.tabVirtualKey {
                XCTAssertFalse(ev.flags.contains(.maskCommand),
                               "a Tab key-down must never carry Command (that is the app switcher)")
            }
        }
    }
}
