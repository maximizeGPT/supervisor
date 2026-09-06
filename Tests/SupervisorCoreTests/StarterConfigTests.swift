import XCTest
@testable import SupervisorCore

/// Nothing used to create config.yaml. Every message that told the owner to
/// edit it — including the cap-hit message naming the exact key to raise — was
/// pointing at a file a fresh install did not have.
final class StarterConfigTests: XCTestCase {

    private func tempConfig() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("starter-config-\(UUID()).yaml")
    }

    /// The property everything else rests on: the seeded file must behave
    /// exactly like no file. If a commented line ever became an active one,
    /// seeding would silently change behavior for every new install.
    func testSeededFileParsesToTheSameConfigAsNoFileAtAll() {
        let seeded = UserConfig.parse(StarterConfig.template)
        let absent = UserConfig.parse(nil)
        XCTAssertEqual(seeded, absent,
                       "the starter file documents the defaults; it must not set any of them")
        XCTAssertEqual(seeded.effectiveDailyCostCapUSD, UserConfig.defaultDailyCostCapUSD)
        XCTAssertFalse(seeded.remoteNotifyEnabled,
                       "seeding must never switch on off-machine delivery")
    }

    /// The documented cap has to be the cap actually in force, or the file is
    /// a lie the day someone changes the default.
    func testTemplateQuotesTheRealDefaultCap() {
        let expected = String(format: "daily_cap_usd: %.2f", UserConfig.defaultDailyCostCapUSD)
        XCTAssertTrue(StarterConfig.template.contains(expected), StarterConfig.template)
    }

    func testSeedWritesTheFileWhenAbsent() throws {
        let path = tempConfig()
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertTrue(StarterConfig.seedIfAbsent(at: path, trace: TraceLog(path: tempConfig())))
        let written = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(written, StarterConfig.template)
    }

    /// The rule that keeps this safe to run on every launch. An owner's
    /// config.yaml is theirs; a seeder that rewrites it is a seeder that
    /// eventually eats a hand-tuned cap.
    func testSeedNeverTouchesAnExistingFile() throws {
        let path = tempConfig()
        defer { try? FileManager.default.removeItem(at: path) }
        let owned = "cost:\n  daily_cap_usd: 0.50\n# my notes\n"
        try owned.write(to: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(StarterConfig.seedIfAbsent(at: path, trace: TraceLog(path: tempConfig())))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), owned)
    }

    /// Even an EMPTY config.yaml is a file the owner made. Seeding over it
    /// would be a write nobody asked for.
    func testSeedLeavesAnEmptyFileAlone() throws {
        let path = tempConfig()
        defer { try? FileManager.default.removeItem(at: path) }
        try "".write(to: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(StarterConfig.seedIfAbsent(at: path, trace: TraceLog(path: tempConfig())))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "")
    }

    // MARK: - Owner-facing location

    /// The cap-hit message names this file, and that message is delivered to
    /// Discord, Slack and phones. The home directory must come back as `~`, or
    /// a message about spending publishes the account name.
    func testDisplayPathIsHomeRelativeAndCarriesNoAccountName() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let config = home.appendingPathComponent("Library/Application Support/Supervisor/config.yaml")
        XCTAssertEqual(
            StarterConfig.displayPath(for: config, home: home),
            "~/Library/Application Support/Supervisor/config.yaml"
        )
        XCTAssertFalse(StarterConfig.displayPath(for: config, home: home).contains("/Users"))
    }

    /// A path outside the home directory degrades to the bare filename rather
    /// than leaking the tree it lives in.
    func testDisplayPathOutsideHomeDegradesToTheFilename() {
        XCTAssertEqual(
            StarterConfig.displayPath(
                for: URL(fileURLWithPath: "/etc/supervisor/config.yaml"),
                home: URL(fileURLWithPath: "/Users/someone")
            ),
            "config.yaml"
        )
    }

    /// The whole point of item (c): the cap-hit copy names where the file
    /// actually is, not a bare filename the owner has to search for.
    func testCapHitMessageNamesTheResolvedConfigLocation() {
        let body = SystemEscalationEvent.costCapHit(spentUSD: 5.10, capUSD: 5.00).body
        XCTAssertTrue(body.contains(StarterConfig.ownerFacingLocation), body)
        XCTAssertTrue(body.contains("config.yaml"), body)
        XCTAssertFalse(body.contains("/Users"),
                       "and it still must not carry the account name off the machine")
    }
}
