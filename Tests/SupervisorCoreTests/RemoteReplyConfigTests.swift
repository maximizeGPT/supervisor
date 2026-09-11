// RemoteReplyConfigTests.swift
//
// The switch, the page it prints, and the minter that decides whether the
// page mentions replying at all. The safety property under all of it is one
// sentence: agreeing to send is not agreeing to receive.

import XCTest
@testable import SupervisorCore

final class RemoteReplyConfigTests: XCTestCase {

    // MARK: - config.yaml

    func testReplyIsOffWhenTheFileSaysNothing() {
        XCTAssertFalse(UserConfig.parse(nil).remoteReplyEnabled)
        XCTAssertFalse(UserConfig.parse("").remoteReplyEnabled)
        XCTAssertFalse(UserConfig().remoteReplyEnabled,
                       "an install that never touches config.yaml never reads a byte off a topic")
    }

    func testTurningOutboundOnDoesNotTurnInboundOn() {
        let config = UserConfig.parse("""
        remote_notify:
          enabled: true
          detail: full
        """)
        XCTAssertTrue(config.remoteNotifyEnabled)
        XCTAssertFalse(config.remoteReplyEnabled,
                       "the inbound half needs its own yes; agreeing to send is not agreeing to receive")
    }

    func testReplyEnabledParsesInsideTheBlock() {
        let config = UserConfig.parse("""
        remote_notify:
          enabled: true
          reply_enabled: true
        """)
        XCTAssertTrue(config.remoteReplyEnabled)
        XCTAssertTrue(config.remoteNotifyEnabled)
    }

    func testInboundCanBeOnWhileOutboundIsOff() {
        // The parser records what the file says; `armRemoteReply` is what
        // refuses to arm without outbound. Keeping the two separate means
        // the file round-trips honestly.
        let config = UserConfig.parse("""
        remote_notify:
          reply_enabled: yes
        """)
        XCTAssertTrue(config.remoteReplyEnabled)
        XCTAssertFalse(config.remoteNotifyEnabled)
    }

    func testATopLevelReplyEnabledStaysOutsideTheBlock() {
        // The same safety property the outbound switch has: a stray
        // top-level key must not be able to arm a network channel.
        let config = UserConfig.parse("""
        remote_notify:
          enabled: true
        reply_enabled: true
        """)
        XCTAssertFalse(config.remoteReplyEnabled,
                       "a key at the top level is not inside remote_notify and must not arm inbound")
    }

    func testReplyEnabledAcceptsQuotedAndCommentedValues() {
        let config = UserConfig.parse("""
        remote_notify:
          reply_enabled: "true"   # answered from the phone
        """)
        XCTAssertTrue(config.remoteReplyEnabled)
    }

    func testAnUnrecognizedReplyValueMeansOff() {
        let config = UserConfig.parse("""
        remote_notify:
          reply_enabled: maybe
        """)
        XCTAssertFalse(config.remoteReplyEnabled,
                       "a typo must not open an inbound channel")
    }

    func testTheStarterTemplateStillParsesToTheSameConfigAsNoFile() {
        // The template documents the key, and every line of it stays
        // commented out, so seeding a config changes nothing.
        XCTAssertEqual(UserConfig.parse(StarterConfig.template), UserConfig.parse(nil))
        XCTAssertTrue(StarterConfig.template.contains("reply_enabled"),
                      "the switch has to be discoverable in the file the installer writes")
    }

    // MARK: - The page

    private func decision(sessionId: String = "s1", cwd: String? = "/tmp/proj") -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            branch: "main",
            candidate: TriageCandidate(
                category: "user_question_pending",
                severity: .high,
                matchedCommand: "",
                action: .notify,
                reasoningPlain: "the session is waiting on you",
                reasoningTechnical: "blocked"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId, command: "", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                  cache_creation_input_tokens: nil,
                                  cache_read_input_tokens: nil),
            model: "haiku",
            prePost: .preExecution,
            flagId: "flag-1"
        )
    }

    func testAPageWithNoReplyChannelSaysNothingAboutReplying() {
        let payload = RemoteNotifyPayload.compose(
            decision: decision(),
            outcome: .notifyOnly,
            reason: "high_severity_flag",
            detail: .minimal,
            redactor: DefaultRedactor(),
            replyCode: nil
        )
        XCTAssertFalse(payload.text.lowercased().contains("reply"),
                       "a page must not advertise a channel nobody is listening on")
    }

    func testAPageWithAReplyChannelPrintsTheCodeLast() {
        let payload = RemoteNotifyPayload.compose(
            decision: decision(),
            outcome: .notifyOnly,
            reason: "high_severity_flag",
            detail: .minimal,
            redactor: DefaultRedactor(),
            replyCode: "a7k2mq"
        )
        let lastLine = payload.text.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(lastLine.contains("a7k2mq"),
                      "the one line the owner acts on sits where a phone notification shows it")
    }

    func testTheReplyLineSurvivesAVeryLongPage() {
        // `full` detail quotes the session. The clip has to take the body,
        // never the line the owner needs to type back.
        var long = decision()
        long = TriageDecision(
            sessionId: long.sessionId,
            cwd: long.cwd,
            branch: long.branch,
            candidate: TriageCandidate(
                category: "user_question_pending",
                severity: .high,
                matchedCommand: String(repeating: "x", count: 4000),
                action: .notify,
                reasoningPlain: String(repeating: "y", count: 4000),
                reasoningTechnical: "blocked"
            ),
            triggeringEvent: long.triggeringEvent,
            usage: long.usage,
            model: long.model,
            prePost: long.prePost,
            flagId: long.flagId
        )
        let payload = RemoteNotifyPayload.compose(
            decision: long,
            outcome: .notifyOnly,
            reason: "high_severity_flag",
            detail: .full,
            redactor: DefaultRedactor(),
            replyCode: "a7k2mq"
        )
        XCTAssertTrue(payload.text.contains("a7k2mq"),
                      "a long page must not truncate away the reply code")
        XCTAssertLessThanOrEqual(payload.text.count, RemoteNotifyPayload.maxTextLength)
    }

    // MARK: - Supervisor must not answer its own page

    func testAPageEchoedBackOntoTheTopicIsNotAReply() async {
        // ntfy echoes every publish to every subscriber, so Supervisor's
        // own page arrives at its own gate carrying a live code. This is
        // the cross-file guard: change the page wording and this test is
        // what says so, instead of the feature quietly starting to answer
        // itself.
        let table = ReplyCorrelationTable()
        let code = try? XCTUnwrap(table.mint(sessionId: "s1", cwd: "/tmp", branch: nil,
                                             outcomeKind: "notify", flagId: "flag-1"))
        let payload = RemoteNotifyPayload.compose(
            decision: decision(),
            outcome: .notifyOnly,
            reason: "high_severity_flag",
            detail: .minimal,
            redactor: DefaultRedactor(),
            replyCode: code ?? "a7k2mq"
        )

        let injector = RemoteReplyGateTests.RecordingInjector()
        let gate = RemoteReplyGate(
            correlations: table,
            injecting: injector,
            configuration: .init(enabled: true),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-\(UUID().uuidString).log"))
        )

        // The whole page body, and the reply line on its own, both of which
        // ntfy could hand back.
        let whole = await gate.accept(RemoteInboxMessage(id: "e1", event: "message", message: payload.text))
        XCTAssertEqual(whole, .noCode, "the page body must not parse as a reply")

        let lastLine = payload.text.split(separator: "\n").last.map(String.init) ?? ""
        let line = await gate.accept(RemoteInboxMessage(id: "e2", event: "message", message: lastLine))
        XCTAssertEqual(line, .noCode, "nor must the reply line by itself")

        XCTAssertTrue(injector.requests.isEmpty,
                      "Supervisor must never type its own page into a session")
    }

    // MARK: - The minter

    func testADisarmedMinterIssuesNoCodes() {
        let table = ReplyCorrelationTable()
        let minter = ArmedReplyCodeMinter(table: table, armed: false)
        XCTAssertNil(minter.mintReplyCode(sessionId: "s1", cwd: "/tmp", branch: nil,
                                          outcomeKind: "notify", flagId: "f1"))
        XCTAssertEqual(table.liveCount(), 0,
                       "a disarmed minter does not quietly fill the table either")
    }

    func testAnArmedMinterIssuesASingleUseCode() {
        let table = ReplyCorrelationTable()
        let minter = ArmedReplyCodeMinter(table: table, armed: true)
        let code = minter.mintReplyCode(sessionId: "s1", cwd: "/tmp", branch: nil,
                                        outcomeKind: "notify", flagId: "f1")
        let unwrapped = try? XCTUnwrap(code)
        XCTAssertEqual(unwrapped?.count, 6, "six characters, per the guessing budget")
        XCTAssertNotNil(table.claim(code: unwrapped ?? ""))
        XCTAssertNil(table.claim(code: unwrapped ?? ""), "claiming is what spends it")
    }

    func testMintedCodesAreDistinct() {
        // Production draws from the CSPRNG. A table that reissued the same
        // code would make every page answerable by the previous page's code.
        let table = ReplyCorrelationTable()
        var codes = Set<String>()
        for i in 0..<200 {
            if let code = table.mint(sessionId: "s\(i)", cwd: nil, branch: nil,
                                     outcomeKind: "notify", flagId: nil) {
                codes.insert(code)
            }
        }
        XCTAssertEqual(codes.count, 200, "every page gets its own code")
    }

    func testTheTableStaysBounded() {
        let table = ReplyCorrelationTable(capacity: 8)
        for i in 0..<100 {
            table.mint(sessionId: "s\(i)", cwd: nil, branch: nil, outcomeKind: "notify", flagId: nil)
        }
        XCTAssertEqual(table.liveCount(), 8,
                       "memory here must not be a function of how long the app has been running")
    }

    func testCodeShapeMatchesWhatTheParserWillAccept() {
        let table = ReplyCorrelationTable()
        for i in 0..<50 {
            let code = table.mint(sessionId: "s\(i)", cwd: nil, branch: nil,
                                  outcomeKind: "notify", flagId: nil) ?? ""
            XCTAssertTrue(ReplyCorrelationTable.looksLikeCode(code),
                          "a minted code the parser would reject is a page nobody can answer: \(code)")
        }
    }
}
