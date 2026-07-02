// HoverHostAppsTests.swift — v0.1.6.1.
//
// Regression coverage for `HoverWindowController.defaultHostApps`:
// the set of bundle IDs that count as "Claude Code might be running here,
// show the hover if a session is active."
//
// We test the *data* and the *predicate the production code uses* —
// not the panel visibility itself (that needs a screen + a workspace,
// which is harness-hostile and slow). The predicate is a one-liner:
// `bundleID.map(claudeCodeHostApps.contains) ?? false`. If that returns
// the wrong answer for a bundle ID, hover behavior breaks.

import SwiftUI
import XCTest
@testable import SupervisorCore
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
                HoverWindowController.defaultHostApps.contains(id),
                "\(id) must remain in claudeCodeHostApps — removing it breaks the hover for users on that terminal"
            )
        }
    }

    /// v0.1.6.1: the Claude desktop app bundle ID was added so users
    /// running `claude` from inside Claude.app see the hover the same
    /// way they would in a terminal.
    func testClaudeDesktopBundleIDIsPresent() {
        XCTAssertTrue(
            HoverWindowController.defaultHostApps.contains("com.anthropic.claudefordesktop"),
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
        let isHost = bundleID.map(HoverWindowController.defaultHostApps.contains) ?? false
        XCTAssertTrue(isHost,
                      "the visibility predicate must return true for the Claude desktop bundle ID")
    }

    /// Negative case: a non-terminal, non-Claude bundle ID must NOT
    /// trigger hover visibility. Catches a future bug where someone
    /// accidentally short-circuits the predicate to always-true.
    func testPredicateReturnsFalseForUnrelatedApp() {
        let bundleID: String? = "com.apple.Safari"
        let isHost = bundleID.map(HoverWindowController.defaultHostApps.contains) ?? false
        XCTAssertFalse(isHost,
                       "Safari is not a Claude Code host app; predicate must return false")
    }

    /// Nil bundle ID (no frontmost app, or a frontmost app with no
    /// bundle ID — rare but possible on macOS) must collapse to
    /// `false`, not crash and not show the hover.
    func testPredicateReturnsFalseForNilBundleID() {
        let bundleID: String? = nil
        let isHost = bundleID.map(HoverWindowController.defaultHostApps.contains) ?? false
        XCTAssertFalse(isHost,
                       "nil bundle ID must collapse to false (hover hidden), not crash")
    }

    /// Issue #3: user-configured additional host apps are merged with
    /// defaults at init time.
    func testAdditionalHostAppsMergedAtInit() {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace)
        let controller = HoverWindowController(
            vm: vm,
            additionalHostApps: ["com.microsoft.VSCode"]
        )
        XCTAssertTrue(controller.claudeCodeHostApps.contains("com.microsoft.VSCode"),
                      "user-added bundle ID must appear in claudeCodeHostApps")
        XCTAssertTrue(controller.claudeCodeHostApps.contains("com.apple.Terminal"),
                      "defaults must be preserved after merge")
    }

    /// Issue #3: mergeUserConfig updates the live set and preserves defaults.
    func testMergeUserConfigUpdatesLiveSet() {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace)
        let controller = HoverWindowController(vm: vm)
        XCTAssertFalse(controller.claudeCodeHostApps.contains("com.jetbrains.intellij"))

        controller.mergeUserConfig(additionalHostApps: ["com.jetbrains.intellij"])

        XCTAssertTrue(controller.claudeCodeHostApps.contains("com.jetbrains.intellij"),
                      "live set must include the newly-merged bundle ID")
        XCTAssertTrue(controller.claudeCodeHostApps.contains("com.apple.Terminal"),
                      "defaults must survive the merge")
    }

    // MARK: - Hover dot mapping (v0.3.0, P0-3)

    /// `.degraded` must render an amber dot — the trust-critical mapping.
    /// A green dot with a dead API key is the exact lie v0.3.0 exists to
    /// remove; the other states are pinned so a refactor can't swap them.
    func testDegradedActivityRendersAmberDot() {
        XCTAssertEqual(
            HoverView.dotColor(for: .degraded(reason: "Can't reach Anthropic — check your API key")),
            .orange)
        XCTAssertEqual(HoverView.dotColor(for: .idle), .green)
        XCTAssertEqual(HoverView.dotColor(for: .triaging), .blue)
        XCTAssertEqual(
            HoverView.dotColor(for: .flagged(severity: .high, action: .pause, reasoningPlain: nil)),
            .red)
    }
}
