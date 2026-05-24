// HoverHostAppsTests.swift — v0.1.6.1.
//
// Regression coverage for `HoverWindowController.claudeCodeHostApps`:
// the set of bundle IDs that count as "Claude Code might be running here,
// show the hover if a session is active."
//
// We test the *data* and the *predicate the production code uses* —
// not the panel visibility itself (that needs a screen + a workspace,
// which is harness-hostile and slow). The predicate is a one-liner:
// `bundleID.map(claudeCodeHostApps.contains) ?? false`. If that returns
// the wrong answer for a bundle ID, hover behavior breaks.

import XCTest
@testable import SupervisorUI

@MainActor
final class HoverHostAppsTests: XCTestCase {

    /// The five terminal emulators that have been in the set since
    /// v0.1.4 Gap 8. Locked in so a future rename or accidental
    /// deletion fails loudly.
    func testKnownTerminalsArePresent() {
        let expected: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "org.alacritty",
        ]
        for id in expected {
            XCTAssertTrue(
                HoverWindowController.claudeCodeHostApps.contains(id),
                "\(id) must remain in claudeCodeHostApps — removing it breaks the hover for users on that terminal"
            )
        }
    }

    /// v0.1.6.1: the Claude desktop app bundle ID was added so users
    /// running `claude` from inside Claude.app see the hover the same
    /// way they would in a terminal.
    func testClaudeDesktopBundleIDIsPresent() {
        XCTAssertTrue(
            HoverWindowController.claudeCodeHostApps.contains("com.anthropic.claudefordesktop"),
            "com.anthropic.claudefordesktop must be in claudeCodeHostApps as of v0.1.6.1"
        )
    }

    /// Mirror the exact production predicate from
    /// `HoverWindowController.applyVisibility()`:
    ///   `bundleID.map(Self.claudeCodeHostApps.contains) ?? false`
    /// so a refactor to the lookup shape (e.g. switching from Set to
    /// a function) gets caught here, not in the field.
    func testPredicateReturnsTrueForClaudeDesktop() {
        let bundleID: String? = "com.anthropic.claudefordesktop"
        let isHost = bundleID.map(HoverWindowController.claudeCodeHostApps.contains) ?? false
        XCTAssertTrue(isHost,
                      "the visibility predicate must return true for the Claude desktop bundle ID")
    }

    /// Negative case: a non-terminal, non-Claude bundle ID must NOT
    /// trigger hover visibility. Catches a future bug where someone
    /// accidentally short-circuits the predicate to always-true.
    func testPredicateReturnsFalseForUnrelatedApp() {
        let bundleID: String? = "com.apple.Safari"
        let isHost = bundleID.map(HoverWindowController.claudeCodeHostApps.contains) ?? false
        XCTAssertFalse(isHost,
                       "Safari is not a Claude Code host app; predicate must return false")
    }

    /// Nil bundle ID (no frontmost app, or a frontmost app with no
    /// bundle ID — rare but possible on macOS) must collapse to
    /// `false`, not crash and not show the hover.
    func testPredicateReturnsFalseForNilBundleID() {
        let bundleID: String? = nil
        let isHost = bundleID.map(HoverWindowController.claudeCodeHostApps.contains) ?? false
        XCTAssertFalse(isHost,
                       "nil bundle ID must collapse to false (hover hidden), not crash")
    }
}
