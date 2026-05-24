// TriageEngineTests.swift
//
// End-to-end test of the triage layer with a mocked Anthropic. Drives
// EventBus, asserts the engine called the API, decoded the record_triage
// response, and emitted the right TriageDecision (or no decision on
// all-clear).

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class TriageEngineTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    override func setUp() {
        super.setUp()
        Self.canned.removeAll()
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TriageMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeEngine() -> (TriageEngine, EventBus, CapturedDecisions) {
        let bus = EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-tests-\(UUID().uuidString).log")))
        let client = LLMClient(provider: .anthropic, 
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("triage-client-\(UUID().uuidString).log"))
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil
        )
        let captured = CapturedDecisions()
        engine.onDecision = { d in captured.append(d) }
        engine.start()
        return (engine, bus, captured)
    }

    private func publishBashCall(
        _ bus: EventBus,
        command: String,
        sessionId: String = "s1",
        toolUseId: String = "t1"
    ) {
        bus.publish(.sessionStart(.init(
            sessionId: sessionId, cwd: "/Users/test", gitBranch: "main",
            projectHash: "-tmp", jsonlPath: "/tmp/x.jsonl", ts: Date()
        )))
        bus.publish(.userPrompt(.init(
            sessionId: sessionId, text: "clean up", ts: Date()
        )))
        bus.publish(.bashToolCall(.init(
            sessionId: sessionId, command: command, description: nil,
            toolUseId: toolUseId, turnUUID: "u1", ts: Date()
        )))
    }

    // Helper: a record_triage response that returns one flag.
    private static func haikuFlagResponse(
        severity: String = "high",
        action: String = "pause",
        reasoningPlain: String = "Claude Code is about to delete /Users/main/important and everything in it. That's not a temp path, so I'm pausing the session — you can resume from the panel if it was deliberate.",
        reasoningTechnical: String = "rm -rf /Users/main/important matches destructive_action_pending rubric clause for 'rm -rf against a path outside the session cwd /Users/test'. Severity high because the path is outside the documented temp-path allowlist; user prompt did not authorize a specific delete.",
        asymmetryNote: String? = "If I pause and I'm wrong, you lose ~5s; if I don't pause and I'm wrong, you lose /Users/main/important.",
        includeAllFields: Bool = true
    ) -> Data {
        var candidate: [String: Any] = [
            "category": "destructive_action_pending",
            "severity": severity,
            "matched_command": "rm -rf /Users/main/important"
        ]
        if includeAllFields {
            candidate["recommended_action"] = action
            candidate["reasoning_plain"] = reasoningPlain
            candidate["reasoning_technical"] = reasoningTechnical
            if let n = asymmetryNote { candidate["asymmetry_note"] = n }
        }
        let body: [String: Any] = [
            "id": "msg_01",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_resp",
                "name": "record_triage",
                "input": [
                    "candidates": [candidate]
                ]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 500, "output_tokens": 80]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // Helper: empty candidates (Haiku says all-clear).
    private static func haikuAllClearResponse() -> Data {
        let body: [String: Any] = [
            "id": "msg_02",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use",
                "id": "toolu_resp",
                "name": "record_triage",
                "input": ["candidates": [] as [Any]]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 480, "output_tokens": 10]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Tests

    func testBashCallProducesFlagWhenHaikuFires() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /Users/main/important")

        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.count, 1)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertEqual(candidate.severity, .high)
        XCTAssertEqual(candidate.category, "destructive_action_pending")
        XCTAssertTrue(candidate.matchedCommand.contains("rm -rf"))
        XCTAssertEqual(candidate.action, .pause)
        XCTAssertTrue(candidate.reasoningPlain.contains("delete"),
                      "reasoningPlain should describe the action in plain English; got: \(candidate.reasoningPlain)")
        XCTAssertTrue(candidate.reasoningTechnical.contains("rubric"),
                      "reasoningTechnical should cite the rubric; got: \(candidate.reasoningTechnical)")
        XCTAssertNotNil(candidate.asymmetryNote, "asymmetry note should be passed through when present")
    }

    func testMalformedVerdictFallsBackToFixedBannerString() async throws {
        // Haiku response missing reasoning_plain and reasoning_technical
        // and recommended_action — i.e., a degraded verdict shape that
        // still has category + severity + matched_command. The engine
        // must still fire the flag, with a fixed fallback banner string
        // and recommendedAction = .notify.
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(includeAllFields: false), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /Users/main/x")

        try await captured.waitFor(count: 1, within: 3.0)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertEqual(candidate.action, .notify,
                       "missing recommended_action should fall back to notify, not pause/kill")
        XCTAssertEqual(candidate.reasoningPlain, TriagePrompt.malformedVerdictBannerText,
                       "missing reasoning_plain should fall back to the fixed banner text, NOT to reasoning_technical")
        XCTAssertEqual(candidate.reasoningTechnical, "",
                       "missing reasoning_technical should leave an empty string, not a synthesized value")
        XCTAssertNil(candidate.asymmetryNote)
    }

    func testReasoningRunsThroughRedactor() async throws {
        // If Haiku ever invents a secret-shaped string in its reasoning,
        // the redactor pass on the inbound text catches it before it
        // lands on the banner or the database. This mirrors the
        // outbound redaction the AnthropicClient already enforces — same
        // protection, opposite direction.
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(
            reasoningPlain: "Claude Code is about to commit sk-ant-api03-LEAKED_KEY_LOOKING_VALUE to the repo, which would expose your Anthropic key.",
            reasoningTechnical: "Bash command head matches 'git commit'; tool_use input shows .env in scope. The literal key sk-ant-api03-LEAKED_KEY_LOOKING_VALUE was in the staged diff."
        ), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "git commit -am 'add .env'")

        try await captured.waitFor(count: 1, within: 3.0)
        let candidate = try XCTUnwrap(captured.snapshot.first?.candidate)
        XCTAssertFalse(candidate.reasoningPlain.contains("sk-ant-api03-LEAKED_KEY_LOOKING_VALUE"),
                       "reasoning_plain leaked a secret-shaped string through the redactor: \(candidate.reasoningPlain)")
        XCTAssertFalse(candidate.reasoningTechnical.contains("sk-ant-api03-LEAKED_KEY_LOOKING_VALUE"),
                       "reasoning_technical leaked a secret-shaped string through the redactor: \(candidate.reasoningTechnical)")
    }

    func testAllClearProducesNoFlag() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /tmp/foo")  // tmp is fine — Haiku says no

        // Wait a bit to make sure the call completes.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0, "tmp paths should not flag — got: \(captured.snapshot)")
    }

    func testHaikuNetworkFailureDoesNotCrash() async throws {
        // No canned response → URLProtocol returns a network error.
        Self.canned.removeAll()
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "rm -rf /Users/main/x")

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(captured.snapshot.count, 0)
        // No assertions on engine state — main contract: no crash.
    }

    func testTriageDecisionIncludesPrePostState() async throws {
        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        // Bash call WITHOUT a matching result → preExecution mode.
        publishBashCall(bus, command: "rm -rf /Users/main/x")
        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.first?.prePost, .preExecution)
    }

    func testWindowsRetainContextForFollowupQueries() async throws {
        // First call: all-clear. Second call: flag. The window should still
        // include the first call's events when evaluating the second, so
        // the prompt has continuity.
        Self.canned["/v1/messages"] = (200, Self.haikuAllClearResponse(), [:])
        let (engine, bus, captured) = makeEngine()
        defer { engine.stop() }

        publishBashCall(bus, command: "ls /tmp", toolUseId: "t-ls")
        try await Task.sleep(nanoseconds: 500_000_000)

        Self.canned["/v1/messages"] = (200, Self.haikuFlagResponse(), [:])
        publishBashCall(bus, command: "rm -rf /Users/main/important", toolUseId: "t-rm")
        try await captured.waitFor(count: 1, within: 3.0)
        XCTAssertEqual(captured.snapshot.count, 1)
        XCTAssertEqual(captured.snapshot.first?.triggeringEvent.toolUseId, "t-rm")
    }

    // MARK: - Capture helper

    final class CapturedDecisions: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: [TriageDecision] = []
        func append(_ d: TriageDecision) {
            lock.lock(); defer { lock.unlock() }
            inner.append(d)
        }
        var snapshot: [TriageDecision] {
            lock.lock(); defer { lock.unlock() }
            return inner
        }
        func waitFor(count target: Int, within seconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if snapshot.count >= target { return }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            XCTFail("timed out waiting for \(target) decisions; got \(snapshot.count)")
        }
    }
}

// MARK: - URLProtocol mock

private final class TriageMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = TriageEngineTests.canned[path] else {
            let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
