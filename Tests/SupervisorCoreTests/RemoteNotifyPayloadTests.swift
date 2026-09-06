// RemoteNotifyPayloadTests.swift
//
// The privacy contract for the remote channel, asserted on the exact bytes
// that would go on the wire.
//
// The most important test in this file is
// `testMinimalNeverQuotesTheSession`. Supervisor's README says nothing leaves
// your machine; the remote channel is the one place that stops being
// unconditionally true, and `.minimal` is the shape that keeps it true about
// the SESSION even when a message is sent. If that test ever goes red, the
// marketing copy is wrong, not the test.

import XCTest
@testable import SupervisorCore

final class RemoteNotifyPayloadTests: XCTestCase {

    // MARK: - Fixtures

    private func decision(
        sessionId: String = "0123456789abcdef",
        cwd: String? = "/Users/test/code/supervisor",
        category: String = "destructive_action_pending",
        severity: FlagSeverity = .high,
        matchedCommand: String = "rm -rf /Users/test/code/supervisor/.build",
        reasoningPlain: String = "Claude Code is about to delete the build directory."
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            candidate: TriageCandidate(
                category: category,
                severity: severity,
                matchedCommand: matchedCommand,
                action: .pause,
                reasoningPlain: reasoningPlain,
                reasoningTechnical: "technical detail that must never ship"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId,
                command: matchedCommand,
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku",
            prePost: .preExecution
        )
    }

    private func compose(
        _ decision: TriageDecision,
        outcome: InterventionOutcome = .pauseSucceeded(pid: 4242, recoveryDocPath: nil),
        detail: RemoteNotifyDetail = .minimal
    ) -> RemoteNotifyPayload {
        RemoteNotifyPayload.compose(
            decision: decision,
            outcome: outcome,
            reason: "worker_paused",
            detail: detail,
            redactor: DefaultRedactor()
        )
    }

    // MARK: - Detail levels

    func testMinimalNeverQuotesTheSession() {
        let payload = compose(decision())
        XCTAssertFalse(payload.text.contains("rm -rf"),
                       "minimal detail must not carry the triggering command: \(payload.text)")
        XCTAssertFalse(payload.text.contains("about to delete"),
                       "minimal detail must not carry assistant-derived reasoning: \(payload.text)")
        XCTAssertFalse(payload.text.contains("/Users/test"),
                       "minimal detail must not carry any absolute path: \(payload.text)")
        XCTAssertFalse(payload.text.contains("technical detail"),
                       "reasoning_technical must never reach any remote payload")
        XCTAssertTrue(payload.text.contains("stayed on your Mac"),
                      "minimal must tell the owner where the detail actually is: \(payload.text)")
    }

    func testMinimalStillCarriesTheActionableFacts() {
        let payload = compose(decision())
        XCTAssertTrue(payload.text.contains("Supervisor paused Claude Code"))
        XCTAssertTrue(payload.text.contains("Project: supervisor"))
        XCTAssertTrue(payload.text.contains("Session: 01234567"))
        XCTAssertTrue(payload.text.contains("destructive_action_pending"))
        XCTAssertTrue(payload.text.contains("high"))
        XCTAssertEqual(payload.detail, .minimal)
        XCTAssertEqual(payload.sessionShort, "01234567")
        XCTAssertEqual(payload.project, "supervisor")
        XCTAssertEqual(payload.outcomeKind, "pause")
        XCTAssertEqual(payload.reason, "worker_paused")
    }

    func testFullAddsCommandAndReasoning() {
        let payload = compose(decision(), detail: .full)
        XCTAssertTrue(payload.text.contains("Command: rm -rf"), payload.text)
        XCTAssertTrue(payload.text.contains("Why: Claude Code is about to delete"), payload.text)
        XCTAssertFalse(payload.text.contains("stayed on your Mac"),
                       "the minimal disclaimer is wrong when the detail is actually present")
        XCTAssertFalse(payload.text.contains("technical detail"),
                       "reasoning_technical is engineer-fit and never leaves, even at full detail")
    }

    // MARK: - Redaction

    func testFullRedactsSecretsInTheCommand() {
        let secret = "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let payload = compose(
            decision(matchedCommand: "curl -H 'x-api-key: \(secret)' https://api.anthropic.com"),
            detail: .full
        )
        XCTAssertFalse(payload.text.contains(secret),
                       "a key in the triggering command must be redacted before it crosses the network")
        XCTAssertTrue(payload.text.contains("<redacted:anthropic-key>"), payload.text)
    }

    func testFullRedactsSecretsInTheReasoning() {
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let payload = compose(
            decision(reasoningPlain: "The session pasted \(secret) into a shell command."),
            detail: .full
        )
        XCTAssertFalse(payload.text.contains(secret))
        XCTAssertTrue(payload.text.contains("<redacted:github-token>"), payload.text)
    }

    func testProjectNameIsRedactedToo() {
        // A directory name can itself be secret-shaped. The redactor runs on
        // it even in minimal, because minimal is not the same as harmless.
        let payload = compose(decision(cwd: "/Users/test/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        XCTAssertEqual(payload.project, "<redacted:github-token>")
    }

    // MARK: - Shape

    func testProjectIsBasenameOnly() {
        XCTAssertEqual(RemoteNotifyPayload.basename(of: "/Users/test/code/repo"), "repo")
        XCTAssertEqual(RemoteNotifyPayload.basename(of: "/Users/test/code/repo/"), "repo")
        XCTAssertEqual(RemoteNotifyPayload.basename(of: "repo"), "repo")
        XCTAssertEqual(RemoteNotifyPayload.basename(of: "/"), "/")
    }

    func testMissingCwdYieldsNoProjectLine() {
        let payload = compose(decision(cwd: nil))
        XCTAssertNil(payload.project)
        XCTAssertFalse(payload.text.contains("Project:"))
    }

    /// SECURITY.md is the promise; this file is the enforcement. They
    /// disagreed: the policy said `minimal` "must quote nothing from the
    /// session" while the payload has always sent the working directory's
    /// basename, pinned by the test above. The basename stays (with several
    /// sessions running it is the only thing that says which one is blocked,
    /// and removing it pushes people to `detail: full`, which sends strictly
    /// more), so the DOCUMENT had to change. This keeps it changed.
    func testSecurityPolicyDocumentsTheBasenameThatMinimalActuallySends() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SupervisorCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo>/
        let policy = try String(
            contentsOf: repoRoot.appendingPathComponent("SECURITY.md"),
            encoding: .utf8
        )
        XCTAssertTrue(policy.contains("basename"),
                      "SECURITY.md must say that detail: minimal sends the working directory's basename")
        XCTAssertFalse(policy.contains("must quote nothing from the session"),
                       "that promise is false while the basename ships; state what minimal sends instead")
    }

    func testClipMarksTruncationAndLeavesShortInputAlone() {
        XCTAssertEqual(RemoteNotifyPayload.clip("short", to: 10), "short")
        XCTAssertEqual(RemoteNotifyPayload.clip("0123456789", to: 10), "0123456789",
                       "exactly at the limit is not truncated")
        XCTAssertEqual(RemoteNotifyPayload.clip("0123456789x", to: 10), "0123456789...")
    }

    func testTextIsCapped() {
        let long = String(repeating: "x", count: 9000)
        let payload = compose(decision(reasoningPlain: long), detail: .full)
        XCTAssertLessThanOrEqual(payload.text.count, RemoteNotifyPayload.maxTextLength + 3,
                                 "text must stay inside the cap so Discord does not reject the post outright")
    }

    func testQuotedFieldsAreClippedIndividually() {
        let long = String(repeating: "y", count: 900)
        let payload = compose(decision(matchedCommand: long), detail: .full)
        XCTAssertTrue(payload.text.contains("..."), "a clipped field must show it was clipped")
        XCTAssertLessThan(payload.text.count, 900,
                          "one very long field must not consume the whole message budget")
    }

    func testTitleMatchesTheLocalBanner() {
        // One copy surface. If these ever diverge the owner gets two
        // different sentences about the same event.
        for outcome: InterventionOutcome in [
            .notifyOnly,
            .pauseSucceeded(pid: 1, recoveryDocPath: nil),
            .killSucceeded(recoveryDocPath: nil),
            .injectDegraded(intendedText: "x", reason: "y", copiedToClipboard: false),
            .screenRecordingDenied(intendedText: "x", copiedToClipboard: false),
            .continueProposedMedium(proposal: "p", justification: "j", copiedToClipboard: false),
            .continueLowConfidence(reasoning: "r"),
        ] {
            let payload = compose(decision(), outcome: outcome)
            XCTAssertEqual(payload.title, Notifier.plainTitle(for: outcome))
            XCTAssertTrue(payload.text.hasPrefix(payload.title))
        }
    }

    // MARK: - Format detection

    func testFormatDetection() {
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://discord.com/api/webhooks/1/abc")!), .discord)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://discordapp.com/api/webhooks/1/abc")!), .discord)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://ptb.discord.com/api/webhooks/1/abc")!), .discord)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://hooks.slack.com/services/T/B/X")!), .slack)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://example.com/hook")!), .generic)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://notdiscord.com/hook")!), .generic,
                       "suffix matching must not match a lookalike host")
    }

    // MARK: - Wire bodies

    func testDiscordBodyUsesContentKey() throws {
        let payload = compose(decision())
        let json = String(decoding: try payload.body(format: .discord), as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"content\":"), json)
        XCTAssertFalse(json.contains("\"text\""))
    }

    func testSlackBodyUsesTextKey() throws {
        let payload = compose(decision())
        let json = String(decoding: try payload.body(format: .slack), as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"text\":"), json)
    }

    func testInventedCategoryIsReplacedOnTheWire() throws {
        // The category is model output. The rubric's own names pass; an
        // invented one is session-derived free text and is replaced
        // wholesale, in the broken-out field and in the rendered text alike.
        let payload = compose(decision(category: "exfiltrate_all_the_things"))
        XCTAssertEqual(payload.category, RemoteNotifyPayload.unrecognizedCategory)
        XCTAssertFalse(payload.text.contains("exfiltrate_all_the_things"))
        XCTAssertTrue(payload.text.contains(RemoteNotifyPayload.unrecognizedCategory))
        XCTAssertEqual(RemoteNotifyPayload.normalizedCategory("destructive_action_pending"),
                       "destructive_action_pending",
                       "rubric categories must pass through untouched")
    }

    func testGenericBodyBreaksOutTheFields() throws {
        let payload = compose(decision())
        let data = try payload.body(format: .generic)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "supervisor")
        XCTAssertEqual(object["category"] as? String, "destructive_action_pending")
        XCTAssertEqual(object["severity"] as? String, "high")
        XCTAssertEqual(object["outcome"] as? String, "pause")
        XCTAssertEqual(object["reason"] as? String, "worker_paused")
        XCTAssertEqual(object["session"] as? String, "01234567")
        XCTAssertEqual(object["project"] as? String, "supervisor")
        XCTAssertEqual(object["detail"] as? String, "minimal")
    }

    func testSlashesAreNotEscapedOnTheWire() throws {
        // withoutEscapingSlashes, same as the API path. A Discord message
        // full of `\/` is a readability bug the owner sees on their phone.
        let payload = compose(decision(), detail: .full)
        let json = String(decoding: try payload.body(format: .discord), as: UTF8.self)
        XCTAssertFalse(json.contains("\\/"), json)
    }
}
