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
        let client = AnthropicClient(
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
    private static func haikuFlagResponse(severity: String = "high") -> Data {
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
                    "candidates": [[
                        "category": "destructive_action_pending",
                        "severity": severity,
                        "reasoning": "rm -rf targets a non-temp path",
                        "matched_command": "rm -rf /Users/main/important"
                    ]]
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
        XCTAssertEqual(captured.snapshot.first?.candidate.severity, .high)
        XCTAssertEqual(captured.snapshot.first?.candidate.category, "destructive_action_pending")
        XCTAssertTrue(captured.snapshot.first?.candidate.matchedCommand.contains("rm -rf") ?? false)
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
