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
                     "a zero cap would block every call — treated as unset")
        XCTAssertNil(UserConfig.parse("cost:\n  daily_cap_usd: -3.5").dailyCostCapUSD)
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
}
