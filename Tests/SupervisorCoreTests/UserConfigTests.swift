// UserConfigTests.swift
//
// Issue #3: tests for the config.yaml parser. Covers the happy path,
// comments, inline comments, empty file, no file, malformed YAML, and
// the additive-merge contract with the default host-apps set.

import XCTest
@testable import SupervisorCore

final class UserConfigTests: XCTestCase {

    func testParseHappyPath() {
        let yaml = """
        hover:
          known_terminals:
            - com.microsoft.VSCode
            - com.todesktop.230313mzl4w4u92
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
        ])
    }

    func testParseWithComments() {
        let yaml = """
        # My Supervisor config
        hover:
          known_terminals:
            # Cursor (Electron-based)
            - com.todesktop.230313mzl4w4u92  # Cursor
            - com.microsoft.VSCode
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, [
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
        ])
    }

    func testParseEmptyYaml() {
        let config = UserConfig.parse("")
        XCTAssertTrue(config.additionalHostApps.isEmpty)
    }

    func testParseNilYaml() {
        let config = UserConfig.parse(nil)
        XCTAssertTrue(config.additionalHostApps.isEmpty)
    }

    func testParseNoKnownTerminalsKey() {
        let yaml = """
        hover:
          some_other_key: true
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.additionalHostApps.isEmpty)
    }

    func testParseKnownTerminalsAtTopLevel() {
        // known_terminals without the hover: parent still works —
        // the parser is forgiving about nesting depth.
        let yaml = """
        known_terminals:
          - com.microsoft.VSCode
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, ["com.microsoft.VSCode"])
    }

    func testParseStopsListAtNextKey() {
        let yaml = """
        hover:
          known_terminals:
            - com.microsoft.VSCode
          other_setting: true
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, ["com.microsoft.VSCode"])
    }

    func testLoadFromNonexistentFile() {
        let bogusPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID()).yaml")
        let config = UserConfig.load(from: bogusPath)
        XCTAssertTrue(config.additionalHostApps.isEmpty,
                      "missing config file must degrade to empty, not crash")
    }

    func testLoadFromDisk() throws {
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-test-\(UUID()).yaml")
        defer { try? FileManager.default.removeItem(at: tmpPath) }

        let yaml = """
        hover:
          known_terminals:
            - com.jetbrains.intellij
        """
        try yaml.write(to: tmpPath, atomically: true, encoding: .utf8)

        let config = UserConfig.load(from: tmpPath)
        XCTAssertEqual(config.additionalHostApps, ["com.jetbrains.intellij"])
    }

    func testParseSkipsEmptyDashEntries() {
        let yaml = """
        known_terminals:
          -
          - com.microsoft.VSCode
          -
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, ["com.microsoft.VSCode"],
                       "empty list entries must be skipped")
    }

    // MARK: - cost.daily_cap_usd (v0.3.0)

    func testParseDailyCapUnderCostKey() {
        let yaml = """
        cost:
          daily_cap_usd: 5.0
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.dailyCostCapUSD, 5.0)
    }

    func testParseDailyCapAbsentIsNil() {
        let yaml = """
        hover:
          known_terminals:
            - com.microsoft.VSCode
        """
        XCTAssertNil(UserConfig.parse(yaml).dailyCostCapUSD)
        XCTAssertNil(UserConfig.parse(nil).dailyCostCapUSD)
        XCTAssertNil(UserConfig.parse("").dailyCostCapUSD)
    }

    func testParseDailyCapGarbageIsNilAndDoesNotCrash() {
        for bad in ["daily_cap_usd: lots", "daily_cap_usd:", "daily_cap_usd: $5", "daily_cap_usd: 5,00"] {
            let config = UserConfig.parse("cost:\n  \(bad)")
            XCTAssertNil(config.dailyCostCapUSD, "'\(bad)' must degrade to nil, not crash")
        }
    }

    func testParseDailyCapNonPositiveIsNil() {
        XCTAssertNil(UserConfig.parse("cost:\n  daily_cap_usd: 0").dailyCostCapUSD,
                     "a zero cap would block every call — never used as the cap value")
        XCTAssertNil(UserConfig.parse("cost:\n  daily_cap_usd: -3.5").dailyCostCapUSD)
    }

    // MARK: - The default cap (2026-09-05)

    /// The defect: `dailyCostCapUSD` was nil by default, so an owner who never
    /// opened config.yaml had NO ceiling on a background process that calls a
    /// metered API on a timer. $10 of DeepSeek credit went overnight.
    func testAbsentDailyCapYieldsTheDefaultCap() {
        XCTAssertEqual(UserConfig.parse(nil).effectiveDailyCostCapUSD, 5.00)
        XCTAssertEqual(UserConfig.parse("").effectiveDailyCostCapUSD, 5.00)
        XCTAssertEqual(UserConfig.parse("hover:\n  known_terminals:\n    - com.apple.Terminal")
                        .effectiveDailyCostCapUSD, 5.00)
        XCTAssertEqual(UserConfig().effectiveDailyCostCapUSD, 5.00,
                       "the bare default config carries the cap too")
        XCTAssertEqual(UserConfig.defaultDailyCostCapUSD, 5.00)
    }

    /// The default cap has to sit ABOVE the heaviest use the product documents,
    /// or it throttles correct use instead of catching a runaway. Onboarding
    /// tells an Anthropic user to expect about $80/month at heavy use, which is
    /// $2.67/day; the first default, $2.00, was below that, so the documented
    /// normal user hit it mid-day and lost supervision. The runaway this
    /// release fixed was about $11/day.
    func testDefaultCapIsARunawayBackstopNotAThrottle() {
        let heavyAnthropicDayUSD = 80.0 / 30.0    // the onboarding estimate
        let runawayDayUSD = 11.0                  // what the idle bug burned
        let cap = UserConfig.defaultDailyCostCapUSD
        XCTAssertGreaterThan(cap, heavyAnthropicDayUSD * 1.5,
                             "a cap the documented heavy user can reach is a throttle, and a throttle teaches owners to switch the cap off")
        XCTAssertLessThan(cap, runawayDayUSD / 2,
                          "and it still has to stop a runaway well before the bill is interesting")
    }

    func testWrittenDailyCapWinsOverTheDefault() {
        XCTAssertEqual(UserConfig.parse("cost:\n  daily_cap_usd: 25").effectiveDailyCostCapUSD, 25.0)
        XCTAssertEqual(UserConfig.parse("cost:\n  daily_cap_usd: 0.25").effectiveDailyCostCapUSD, 0.25)
    }

    /// An explicit zero (or negative) is the owner turning capping off. It has
    /// to stay distinguishable from "absent," or raising the default would take
    /// away the opt-out.
    func testExplicitZeroDisablesTheCapEntirely() {
        let off = UserConfig.parse("cost:\n  daily_cap_usd: 0")
        XCTAssertTrue(off.dailyCostCapDisabled)
        XCTAssertNil(off.effectiveDailyCostCapUSD)

        let negative = UserConfig.parse("cost:\n  daily_cap_usd: -3.5")
        XCTAssertTrue(negative.dailyCostCapDisabled)
        XCTAssertNil(negative.effectiveDailyCostCapUSD)
    }

    /// A typo is not an opt-out. `daily_cap_usd: lots` must leave the ceiling
    /// standing, not remove it.
    func testGarbageDailyCapKeepsTheDefaultCap() {
        for bad in ["daily_cap_usd: lots", "daily_cap_usd:", "daily_cap_usd: $5", "daily_cap_usd: 5,00"] {
            let config = UserConfig.parse("cost:\n  \(bad)")
            XCTAssertFalse(config.dailyCostCapDisabled, "'\(bad)' is a typo, not an opt-out")
            XCTAssertEqual(config.effectiveDailyCostCapUSD, 5.00, "'\(bad)' must not remove the ceiling")
        }
    }

    func testParseDailyCapWithInlineComment() {
        let config = UserConfig.parse("cost:\n  daily_cap_usd: 2.50  # two fifty a day")
        XCTAssertEqual(config.dailyCostCapUSD, 2.5)
    }

    func testParseDailyCapCoexistsWithKnownTerminals() {
        let yaml = """
        hover:
          known_terminals:
            - com.microsoft.VSCode
        cost:
          daily_cap_usd: 10
        """
        let config = UserConfig.parse(yaml)
        XCTAssertEqual(config.additionalHostApps, ["com.microsoft.VSCode"])
        XCTAssertEqual(config.dailyCostCapUSD, 10.0)
    }

    // MARK: - remote_notify block

    func testRemoteNotifyDefaultsOff() {
        // An install that never touches config.yaml must never post
        // anywhere. This is the default that makes the feature safe.
        let config = UserConfig.parse("hover:\n  known_terminals:\n    - com.microsoft.VSCode")
        XCTAssertFalse(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .minimal)
        XCTAssertFalse(UserConfig().remoteNotifyEnabled)
        XCTAssertEqual(UserConfig().remoteNotifyDetail, .minimal)
    }

    func testRemoteNotifyEnabledAndDetail() {
        let yaml = """
        remote_notify:
          enabled: true
          detail: full
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .full)
    }

    func testRemoteNotifyUnknownDetailFallsBackToMinimal() {
        // A typo must never widen what leaves the machine.
        let yaml = """
        remote_notify:
          enabled: true
          detail: everything
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .minimal)
    }

    func testRemoteNotifyAcceptsQuotedAndCommentedValues() {
        let yaml = """
        remote_notify:
          enabled: "yes"   # webhook URL lives in the Keychain
          detail: 'FULL'
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .full)
    }

    func testRemoteNotifyExplicitFalse() {
        let yaml = """
        remote_notify:
          enabled: false
          detail: full
        """
        let config = UserConfig.parse(yaml)
        XCTAssertFalse(config.remoteNotifyEnabled,
                       "detail: full must not imply the channel is on")
    }

    func testRemoteNotifyCoexistsWithHoverBlockInEitherOrder() {
        let hoverFirst = """
        hover:
          known_terminals:
            - com.microsoft.VSCode
        remote_notify:
          enabled: true
        """
        let remoteFirst = """
        remote_notify:
          enabled: true
        hover:
          known_terminals:
            - com.microsoft.VSCode
        """
        for yaml in [hoverFirst, remoteFirst] {
            let config = UserConfig.parse(yaml)
            XCTAssertEqual(config.additionalHostApps, ["com.microsoft.VSCode"])
            XCTAssertTrue(config.remoteNotifyEnabled)
        }
    }

    func testRemoteNotifyCoexistsWithCostAndCodexKeys() {
        // The three scalar keys are parsed by different branches; each has to
        // close the remote_notify block so a later `enabled:` cannot be read
        // back into it.
        let yaml = """
        remote_notify:
          enabled: true
          detail: full
        cost:
          daily_cap_usd: 4.25
        supervise_codex: false
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .full)
        XCTAssertEqual(config.dailyCostCapUSD, 4.25)
        XCTAssertEqual(config.superviseCodex, false)
    }

    func testEnabledOutsideRemoteNotifyBlockIsIgnored() {
        // A stray top-level `enabled: true` must not switch on a network
        // channel the owner never asked for.
        let yaml = """
        enabled: true
        hover:
          known_terminals:
            - com.microsoft.VSCode
        """
        let config = UserConfig.parse(yaml)
        XCTAssertFalse(config.remoteNotifyEnabled)
    }

    func testEnabledAfterAnInterveningKeyIsIgnored() {
        let yaml = """
        remote_notify:
          detail: minimal
        cost:
          daily_cap_usd: 3
        enabled: true
        """
        XCTAssertFalse(UserConfig.parse(yaml).remoteNotifyEnabled,
                       "the block ended at cost:, so this enabled: belongs to nothing")
    }

    func testUnrecognizedKeyInsideTheBlockDoesNotCloseIt() {
        // A typo, or a key from a newer Supervisor, sits at block depth. It
        // must be skipped, not end the block: closing early would silently
        // drop every recognized key after it.
        let yaml = """
        remote_notify:
          dedupe_seconds: 30
          enabled: true
          some_future_knob: whatever
          detail: full
        """
        let config = UserConfig.parse(yaml)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertEqual(config.remoteNotifyDetail, .full)
    }

    func testHeaderWithTrailingCommentStillOpensTheBlock() {
        let yaml = """
        remote_notify:  # the URL itself lives in the Keychain
          enabled: true
        """
        XCTAssertTrue(UserConfig.parse(yaml).remoteNotifyEnabled,
                      "a trailing comment on the header must not hide the whole block")
    }

    func testIndentedBlockUnderAParentKeyParses() {
        // Membership is by indentation relative to the HEADER, not by column
        // zero, so a remote_notify block nested under some parent key still
        // parses and still closes when the indentation returns to its level.
        let yaml = """
        notifications:
          remote_notify:
            enabled: true
          other: thing
        enabled_after: true
        """
        XCTAssertTrue(UserConfig.parse(yaml).remoteNotifyEnabled)
    }

    func testTopLevelEnabledAfterDeeperBlockStaysOutside() {
        let yaml = """
        remote_notify:
          detail: minimal
        enabled: true
        """
        XCTAssertFalse(UserConfig.parse(yaml).remoteNotifyEnabled,
                       "a line back at the header's own indentation ends the block before it is read")
    }
}
