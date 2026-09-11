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

    private func update(
        _ existing: String?,
        enabled: Bool,
        detail: RemoteNotifyDetail = .minimal,
        replyEnabled: Bool = false
    ) -> String {
        RemoteNotifyConfigWriter.updatedYAML(
            existing,
            values: .init(enabled: enabled, detail: detail, replyEnabled: replyEnabled)
        )
    }

    /// Lines inside the file whose trimmed form starts with `key:`. The
    /// two switches share a suffix, so counting them needs the line and not
    /// the substring.
    private func keyLineCount(_ key: String, in yaml: String) -> Int {
        yaml.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }
            .count
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
        // Counted as LINES beginning with the key, not as occurrences of
        // the substring: `reply_enabled:` contains `enabled:` and is a
        // different key, and a substring count would call the correct
        // output a duplicate.
        XCTAssertEqual(keyLineCount("enabled", in: out), 1,
                       "exactly one enabled key after the rewrite")
        XCTAssertEqual(keyLineCount("reply_enabled", in: out), 1)
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

        try RemoteNotifyConfigWriter.write(values: .init(enabled: true, detail: .minimal, replyEnabled: false), to: path)
        XCTAssertTrue(UserConfig.load(from: path).remoteNotifyEnabled)

        try RemoteNotifyConfigWriter.write(values: .init(enabled: false, detail: .full, replyEnabled: false), to: path)
        let reread = UserConfig.load(from: path)
        XCTAssertFalse(reread.remoteNotifyEnabled)
        XCTAssertEqual(reread.remoteNotifyDetail, .full)
    }

    // MARK: - reply_enabled (the inbound half's switch)

    func testReplyEnabledRoundTripsThroughTheParser() {
        let on = update(nil, enabled: true, replyEnabled: true)
        XCTAssertTrue(UserConfig.parse(on).remoteReplyEnabled)
        XCTAssertTrue(on.contains("reply_enabled: true"))

        let off = update(on, enabled: true, replyEnabled: false)
        XCTAssertFalse(UserConfig.parse(off).remoteReplyEnabled)
        XCTAssertTrue(off.contains("reply_enabled: false"))
    }

    func testReplyEnabledIsAddedToABlockThatPredatesIt() {
        // Every install that had remote escalation before v0.4.2 has a
        // block with no reply key in it. The first panel save has to insert
        // one INSIDE the block, not append it past the end where the
        // parser's first-line-back rule would drop it on the floor.
        let existing = "remote_notify:\n  enabled: true\n  detail: full\n\nother_key: 1\n"
        let out = update(existing, enabled: true, detail: .full, replyEnabled: true)
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteReplyEnabled)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertEqual(parsed.remoteNotifyDetail, .full)
        XCTAssertTrue(out.contains("other_key: 1"), "everything outside the block is untouched")
    }

    func testWritingTheOutboundSwitchNeverLandsOnTheReplyKey() {
        // The two keys mean different things and one of them opens an
        // inbound path. A write of `enabled` that matched `reply_enabled`
        // by a looser rule would switch on a channel the owner never asked
        // for, which is the exact failure the parser guards against too.
        let existing = "remote_notify:\n  reply_enabled: true\n  enabled: false\n  detail: minimal\n"
        let out = update(existing, enabled: true, replyEnabled: true)
        let parsed = UserConfig.parse(out)
        XCTAssertTrue(parsed.remoteNotifyEnabled)
        XCTAssertTrue(parsed.remoteReplyEnabled)
        XCTAssertEqual(keyLineCount("reply_enabled", in: out), 1,
                       "one reply_enabled line, not a duplicate inserted alongside the one already there")
        XCTAssertEqual(keyLineCount("enabled", in: out), 1)
    }

    func testAnInlineCommentSurvivesAReplyToggle() {
        let existing = "remote_notify:\n  enabled: true\n  reply_enabled: false   # answered from the phone\n"
        let out = update(existing, enabled: true, replyEnabled: true)
        XCTAssertTrue(out.contains("reply_enabled: true # answered from the phone"),
                      "the owner's note rides along onto the rewritten value")
        XCTAssertTrue(UserConfig.parse(out).remoteReplyEnabled)
    }

    func testReplyToggleIsAFixedPoint() {
        let once = update(nil, enabled: true, detail: .full, replyEnabled: true)
        let twice = update(once, enabled: true, detail: .full, replyEnabled: true)
        XCTAssertEqual(once, twice)
    }
}
