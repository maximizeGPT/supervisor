// RemoteNotifyConfigWriterTests.swift
//
// The panel's toggle writes into the SAME config.yaml the owner may edit by
// hand, so the writer's two contracts both get exercised here: everything
// outside the remote_notify block survives byte-for-byte, and everything the
// writer emits round-trips through UserConfig.parse (the parser is the
// authority on what a line means, so every assertion of record goes through
// it rather than through string expectations alone).

import XCTest
@testable import SupervisorCore

final class RemoteNotifyConfigWriterTests: XCTestCase {

    private func update(_ existing: String?, enabled: Bool, detail: RemoteNotifyDetail = .minimal) -> String {
        RemoteNotifyConfigWriter.updatedYAML(existing, values: .init(enabled: enabled, detail: detail))
    }

    // MARK: - From nothing

    func testNilFileProducesAParsableBlock() {
        let out = update(nil, enabled: true, detail: .full)
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .full)
    }

    func testEmptyFileProducesAParsableBlock() {
        let out = update("   \n", enabled: false)
        let parsed = UserConfig.parse(out)
        XCTAssertFalse(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .minimal)
    }

    // MARK: - Appending to an existing file without a block

    func testAppendPreservesEveryExistingLine() {
        let existing = """
        # my config
        known_terminals:
          - com.example.term   # my terminal
        cost:
          daily_cap_usd: 5.0
        """
        let out = update(existing, enabled: true)
        for line in existing.split(separator: "\n") {
            XCTAssertTrue(out.contains(line), "existing line must survive: \(line)")
        }
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.additionalHostApps, ["com.example.term"],
                       "the terminals list must still parse after the append")
        XCTAssertEqual(parsed.dailyCostCapUSD, 5.0, "the cost cap must still parse after the append")
    }

    // MARK: - Updating an existing block

    func testExistingKeysAreRewrittenInPlace() {
        let existing = """
        remote_notify:
          enabled: true
          detail: full
        supervise_codex: false
        """
        let out = update(existing, enabled: false, detail: .minimal)
        let parsed = UserConfig.parse(out)
        XCTAssertFalse(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .minimal)
        XCTAssertEqual(parsed.superviseCodex, false, "keys after the block must survive")
        XCTAssertEqual(out.components(separatedBy: "enabled:").count, 2,
                       "exactly one enabled key after the rewrite")
    }

    func testMissingKeysAreInsertedIntoAnExistingBlock() {
        // A block holding only an unknown key from a newer version: the
        // writer must add both scalars INSIDE the block (deeper indent than
        // the header) without dropping the unknown key.
        let existing = """
        remote_notify:
          future_key: whatever
        """
        let out = update(existing, enabled: true, detail: .full)
        XCTAssertTrue(out.contains("future_key: whatever"))
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .full)
    }

    func testCommentedHeaderAndInlineCommentsSurvive() {
        let existing = """
        remote_notify:   # the off-machine switch
          # keep this off normally
          enabled: false
          detail: minimal  # verdict only
        """
        let out = update(existing, enabled: true, detail: .full)
        XCTAssertTrue(out.contains("# keep this off normally"),
                      "comments inside the block must survive")
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .full)
    }

    func testInlineCommentsOnReplacedLinesSurviveTheRewrite() {
        // The owner annotated the very lines the panel toggles. Their notes
        // are their file; the rewrite carries them onto the new values.
        let existing = """
        remote_notify:
          enabled: false # flip from the panel
          detail: minimal  # verdict only, nothing quoted
          format: auto # host detection
        """
        let out = update(existing, enabled: true, detail: .full)
        XCTAssertTrue(out.contains("enabled: true # flip from the panel"), out)
        XCTAssertTrue(out.contains("detail: full # verdict only, nothing quoted"), out)
        XCTAssertTrue(out.contains("format: auto # host detection"), out)
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .full)
        // And the comment-carrying rewrite is still a fixed point.
        XCTAssertEqual(out, update(out, enabled: true, detail: .full))
    }

    func testTopLevelEnabledOutsideTheBlockIsNeverTouched() {
        // The parser's safety property: a stray top-level `enabled:` is NOT
        // part of remote_notify. The writer must honor the same boundary and
        // leave it alone rather than rewriting it.
        let existing = """
        enabled: true
        remote_notify:
          enabled: false
          detail: minimal
        """
        let out = update(existing, enabled: true)
        XCTAssertTrue(out.contains("\nremote_notify:"), "block header preserved")
        XCTAssertTrue(out.hasPrefix("enabled: true\n"),
                      "the stray top-level key must pass through untouched")
        XCTAssertTrue(UserConfig.parse(out).remoteNotifyEnabled)
    }

    func testIdempotentRewrite() {
        let once = update("known_terminals:\n  - com.a.b\n", enabled: true, detail: .full)
        let twice = update(once, enabled: true, detail: .full)
        XCTAssertEqual(once, twice, "re-writing the same values must be a fixed point")
    }

    // MARK: - Disk round trip

    func testWriteCreatesAndUpdatesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-config-writer-\(UUID().uuidString)", isDirectory: true)
        let path = dir.appendingPathComponent("config.yaml")
        defer { try? FileManager.default.removeItem(at: dir) }

        try RemoteNotifyConfigWriter.write(values: .init(enabled: true, detail: .minimal), to: path)
        XCTAssertTrue(UserConfig.load(from: path).remoteNotifyEnabled)

        try RemoteNotifyConfigWriter.write(values: .init(enabled: false, detail: .full), to: path)
        let reread = UserConfig.load(from: path)
        XCTAssertFalse(reread.remoteNotifyEnabled)
        XCTAssertEqual(reread.remoteNotifyDetail, .full)
    }
}
