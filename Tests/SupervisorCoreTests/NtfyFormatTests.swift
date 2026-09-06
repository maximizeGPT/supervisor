// NtfyFormatTests.swift
//
// C13: the ntfy wire shape, mirrored against ntfy's documented publish API
// (https://docs.ntfy.sh/publish/): a plain-text POST to the topic URL with
// the title in the `Title` header — not JSON, unlike every other format.
// Covers detection (ntfy.sh and subdomains), the explicit override for
// self-hosted servers, the body/header split, and the end-to-end request a
// RemoteNotifier actually sends through the transport seam.

import XCTest
@testable import SupervisorCore

final class NtfyFormatTests: XCTestCase {

    // MARK: - Detection

    func testNtfyShHostsDetect() throws {
        XCTAssertEqual(try RemoteWebhookURL(validating: "https://ntfy.sh/my-secret-topic").format, .ntfy)
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://alerts.ntfy.sh/topic")!), .ntfy)
    }

    func testSelfHostedNtfyDoesNotDetect() throws {
        // The host says nothing; that is exactly what the explicit override
        // exists for.
        XCTAssertEqual(try RemoteWebhookURL(validating: "https://ntfy.example.com/topic").format, .generic)
    }

    func testLookalikeHostDoesNotDetect() {
        XCTAssertEqual(RemoteNotifyFormat.detect(from: URL(string: "https://evilntfy.sh/topic")!), .generic,
                       "suffix matching must respect the label boundary")
    }

    // MARK: - Wire shape

    private func payload(
        title: String = "Supervisor paused Claude Code",
        text: String? = nil
    ) -> RemoteNotifyPayload {
        RemoteNotifyPayload(
            title: title,
            text: text ?? "\(title)\nProject: repo\nSession: abcd1234\nFlag: destructive_action_pending (high)\nSupervisor: pause",
            category: "destructive_action_pending",
            severity: "high",
            outcomeKind: "pause",
            reason: "worker_paused",
            sessionShort: "abcd1234",
            project: "repo",
            detail: .minimal
        )
    }

    func testNtfyBodyIsPlainTextNotJSON() throws {
        let wire = try payload().wireBody(format: .ntfy)
        XCTAssertEqual(wire.contentType, "text/plain; charset=utf-8")
        let body = String(decoding: wire.data, as: UTF8.self)
        XCTAssertFalse(body.hasPrefix("{"), "ntfy takes the message as the raw body: \(body)")
        XCTAssertTrue(body.contains("Flag: destructive_action_pending (high)"), body)
    }

    func testNtfyTitleTravelsAsTheTitleHeaderAndNotInTheBody() throws {
        let wire = try payload().wireBody(format: .ntfy)
        XCTAssertEqual(wire.headers["Title"], "Supervisor paused Claude Code")
        let body = String(decoding: wire.data, as: UTF8.self)
        XCTAssertFalse(body.hasPrefix("Supervisor paused Claude Code"),
                       "ntfy renders the header title above the body; repeating it reads twice: \(body)")
    }

    func testNtfyBodyKeepsTextWhoseFirstLineIsNotTheTitle() throws {
        let wire = try payload(text: "custom body without a title line").wireBody(format: .ntfy)
        XCTAssertEqual(String(decoding: wire.data, as: UTF8.self), "custom body without a title line")
    }

    func testJSONFormatsCarryNoExtraHeaders() throws {
        for format in [RemoteNotifyFormat.discord, .slack, .generic] {
            let wire = try payload().wireBody(format: format)
            XCTAssertEqual(wire.contentType, "application/json", "\(format)")
            XCTAssertTrue(wire.headers.isEmpty, "\(format) carries everything in the body")
        }
    }

    func testHeaderSafeStripsNewlinesAndNonASCII() {
        XCTAssertEqual(
            RemoteNotifyPayload.headerSafe("Line\r\nInjection: attempt\u{2014}done\u{7F}"),
            "LineInjection: attemptdone",
            "header values must never carry newlines or non-printable bytes"
        )
    }

    // MARK: - Through the notifier (detection and override end to end)

    private func scratchTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfy-format-\(UUID()).log"))
    }

    private func decision() -> TriageDecision {
        TriageDecision(
            sessionId: "sess-ntfy",
            cwd: "/Users/test/repo",
            candidate: TriageCandidate(
                category: "destructive_action_pending", severity: .high,
                matchedCommand: "rm -rf x", action: .pause,
                reasoningPlain: "plain", reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "sess-ntfy", command: "rm -rf x", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku", prePost: .preExecution
        )
    }

    func testNtfyShEndpointDeliversNtfyShapedRequest() async throws {
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://ntfy.sh/supervisor-alerts"),
            configuration: .init(enabled: true, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        let outcome = await notifier.postInterventionResult(
            decision: decision(),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        XCTAssertEqual(outcome, .posted)
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.absoluteString, "https://ntfy.sh/supervisor-alerts",
                       "the topic URL is the destination; ntfy has no separate publish path")
        XCTAssertEqual(sent.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(sent.headers["Title"], "Supervisor paused Claude Code")
        XCTAssertFalse(String(decoding: sent.body, as: UTF8.self).hasPrefix("{"),
                       "no JSON envelope on the ntfy wire")
    }

    func testFormatOverrideMakesASelfHostedServerNtfy() async throws {
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://ntfy.example.com/supervisor"),
            configuration: .init(enabled: true, retryDelay: 0, formatOverride: .ntfy),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        _ = await notifier.postInterventionResult(
            decision: decision(),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.contentType, "text/plain; charset=utf-8",
                       "the override must win over the generic host detection")
        XCTAssertEqual(sent.headers["Title"], "Supervisor paused Claude Code")
    }

    func testConfigParsesTheFormatKey() {
        let config = UserConfig.parse("""
        remote_notify:
          enabled: true
          detail: minimal
          format: ntfy
        """)
        XCTAssertEqual(config.remoteNotifyFormat, .ntfy)

        XCTAssertNil(UserConfig.parse("remote_notify:\n  format: auto\n").remoteNotifyFormat)
        XCTAssertNil(UserConfig.parse("remote_notify:\n  format: nfty\n").remoteNotifyFormat,
                     "a typo must fall back to detection, never to a wrong pinned shape")
    }

    func testConfigWriterRoundTripsTheFormatKey() {
        let out = RemoteNotifyConfigWriter.updatedYAML(
            "remote_notify:\n  enabled: true\n  detail: minimal\n",
            values: .init(enabled: true, detail: .minimal, format: .ntfy)
        )
        XCTAssertEqual(UserConfig.parse(out).remoteNotifyFormat, .ntfy)

        let backToAuto = RemoteNotifyConfigWriter.updatedYAML(
            out,
            values: .init(enabled: true, detail: .minimal, format: nil)
        )
        XCTAssertNil(UserConfig.parse(backToAuto).remoteNotifyFormat)
        XCTAssertTrue(backToAuto.contains("format: auto"),
                      "auto is written explicitly so the key stays visible and hand-editable")
    }
}
