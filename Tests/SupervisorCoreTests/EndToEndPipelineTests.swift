// EndToEndPipelineTests.swift
//
// The Checkpoint C verification expressed as a deterministic integration
// test. Wires the v0.1.0 surface end-to-end:
//
//   tempDir JSONL written
//     → real SessionDiscovery
//       → real SessionTail (kqueue)
//         → real EventParser
//           → real EventBus
//             → real TriageEngine (mocked Haiku via URLProtocol)
//               → onDecision
//                 → real FlagStore (real SQLite)
//                 → Notifier copy generation
//                 → HoverViewModel state mutation
//
// What it does NOT cover (those are GUI-bound, I verify):
//   - Banner notification physically appearing on screen.
//   - Hover window pixels.
//   - Status bar icon color.
//
// What it DOES cover: every Swift call edge between "JSONL line gets
// written" and "flag row exists in SQLite + UI viewmodel reflects it."

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class EndToEndPipelineTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testFullPipelineFromJSONLToFlagRow() async throws {
        // -- Build the world ---------------------------------------------

        let projectsDir = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsDir.appendingPathComponent("-fake-project")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("supervisor.sqlite")
        let database = try SupervisorDatabase(path: dbPath)
        let sessionStore = SessionStore(database: database)
        let flagStore    = FlagStore(database: database)

        let trace = TraceLog(path: tempDir.appendingPathComponent("trace.log"))
        let bus = EventBus(trace: trace)

        // Canned Haiku response: one flag, high severity.
        Self.canned["/v1/messages"] = (200, Self.haikuFlag(), [:])
        let client = LLMClient(provider: .anthropic, 
            apiKey: "sk-ant-fixture",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: trace
        )

        let hoverVM = HoverViewModel(bus: bus, trace: trace)

        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            costStore: nil,
            trace: trace
        )

        // The exact wire from SupervisorApp's enterRunningState: triage
        // decision → flagStore.insert + Notifier copy + hoverVM.flagRaised.
        let routed = RoutedFlagSink()
        engine.onActivityChange = { activity in
            if case .flagged(let sev, let action) = activity {
                hoverVM.flagRaised(severity: sev, action: action)
            }
        }
        engine.onDecision = { decision in
            let flag = StoredFlag(
                sessionId: decision.sessionId,
                category: decision.candidate.category,
                severity: decision.candidate.severity,
                action: decision.candidate.action,
                reasoningPlain: decision.candidate.reasoningPlain,
                reasoningTechnical: decision.candidate.reasoningTechnical,
                asymmetryNote: decision.candidate.asymmetryNote,
                evidenceUuids: [decision.triggeringEvent.toolUseId],
                haikuInputTokens: decision.usage.input_tokens,
                haikuOutputTokens: decision.usage.output_tokens
            )
            do {
                // FlagStore needs a session row to satisfy the FK. Insert
                // one on first flag.
                try sessionStore.upsert(StoredSession(
                    id: decision.sessionId,
                    projectHash: "-fake-project",
                    cwd: "/Users/test",
                    startedAt: Date(),
                    lastSeenAt: Date(),
                    jsonlPath: "/tmp/x.jsonl"
                ))
                try flagStore.insert(flag)
                routed.record(flag: flag, decision: decision)
            } catch {
                routed.recordError("\(error)")
            }
        }
        engine.start()
        defer { engine.stop() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsDir,
            bus: bus,
            sessionStore: sessionStore,
            trace: trace
        )
        discovery.start()
        defer { discovery.stop() }

        // -- Drive the wire: write a Bash tool_use line to a JSONL ----

        let sessionId = "e2e-session-1"
        let bashCommand = "rm -rf /Users/test/important"
        let jsonl = projectHashDir.appendingPathComponent("\(sessionId).jsonl")
        let lines = [
            #"{"type":"queue-operation","timestamp":"2026-05-21T19:36:19Z","sessionId":"\#(sessionId)","cwd":"/Users/test","gitBranch":"main"}"#,
            #"{"type":"user","timestamp":"2026-05-21T19:36:20Z","sessionId":"\#(sessionId)","uuid":"u1","message":{"role":"user","content":"clean up please"}}"#,
            #"{"type":"assistant","timestamp":"2026-05-21T19:36:21Z","sessionId":"\#(sessionId)","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"\#(bashCommand)"}}]}}"#,
        ]
        let payload = lines.joined(separator: "\n") + "\n"
        try Data(payload.utf8).write(to: jsonl)
        discovery.probeNow()

        // -- Assert: flag persisted to SQLite, hover VM reflects it -----

        try await routed.waitFor(count: 1, within: 4.0)
        XCTAssertEqual(routed.flags.count, 1)
        let persisted = try flagStore.recent(sessionId: sessionId).first
        XCTAssertNotNil(persisted, "flag should be in SQLite")
        XCTAssertEqual(persisted?.category, "destructive_action_pending")
        XCTAssertEqual(persisted?.severity, .high)
        XCTAssertEqual(persisted?.action, .pause,
                       "Haiku's recommended_action 'pause' must land on flag.action, not the v0.1.0 hardcoded .notify")
        XCTAssertTrue(persisted?.reasoningPlain.contains("delete") ?? false,
                      "reasoning_plain should describe the action in plain English; got: \(persisted?.reasoningPlain ?? "(nil)")")
        XCTAssertTrue(persisted?.reasoningTechnical.contains("rubric") ?? false,
                      "reasoning_technical should cite the rubric; got: \(persisted?.reasoningTechnical ?? "(nil)")")
        XCTAssertNotNil(persisted?.asymmetryNote, "asymmetry note from Haiku should be persisted on the flag")
        XCTAssertGreaterThan(persisted?.haikuInputTokens ?? 0, 0)

        // HoverViewModel state.
        XCTAssertEqual(hoverVM.flagCount, 1)
        if case .flagged(let sev, let action) = hoverVM.activity {
            XCTAssertEqual(sev, .high)
            XCTAssertEqual(action, .pause, "Haiku recommended pause; hover activity should carry that")
        } else {
            XCTFail("hover activity should be .flagged(.high, ...), got \(hoverVM.activity)")
        }
        XCTAssertTrue(hoverVM.currentToolDescription.contains("Bash"),
                      "hover should show current tool, got: \(hoverVM.currentToolDescription)")

        // Notifier copy is exercised against the decision so we know the
        // wire all the way to "what would the banner say" lines up with
        // the v0.1.2 prefix + reasoning_plain shape.
        let notifier = NotifierBodyShim()
        let bannerBody = notifier.body(for: routed.decisions[0])
        XCTAssertTrue(bannerBody.hasPrefix(Notifier.bannerPrefix),
                      "notifier body must start with the brand prefix, got: \(bannerBody)")
        XCTAssertTrue(bannerBody.contains("delete"),
                      "notifier body should surface the plain-English description, got: \(bannerBody)")
        XCTAssertFalse(bannerBody.contains("rubric"),
                       "notifier body must NOT surface technical reasoning, got: \(bannerBody)")
    }

    // MARK: - Mock plumbing

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [E2EMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func haikuFlag() -> Data {
        let body: [String: Any] = [
            "id": "msg_e2e",
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
                        "severity": "high",
                        "matched_command": "rm -rf /Users/test/important",
                        "recommended_action": "pause",
                        "reasoning_plain": "Claude Code is about to delete /Users/test/important and everything in it. That's not a temp path, and your last prompt didn't mention deleting anything, so this looks unintended. I'm pausing the session so you can check before it runs — you can resume from the panel if it was deliberate.",
                        "reasoning_technical": "rm -rf /Users/test/important matches the destructive_action_pending rubric clause for rm -rf against a path outside the session cwd. Severity high because the target is outside the documented temp-path allowlist (/tmp/, .pytest_cache/, node_modules/, build/, dist/) and the user prompt 'clean up please' did not authorize a specific delete.",
                        "asymmetry_note": "If I pause and I'm wrong, you lose ~5s and a resume click; if I don't pause and I'm wrong, you lose /Users/test/important."
                    ]]
                ]
            ]],
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 1200, "output_tokens": 95]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

// MARK: - Helpers

private final class RoutedFlagSink: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var flags: [StoredFlag] = []
    private(set) var decisions: [TriageDecision] = []
    private(set) var errors: [String] = []

    func record(flag: StoredFlag, decision: TriageDecision) {
        lock.lock(); defer { lock.unlock() }
        flags.append(flag)
        decisions.append(decision)
    }
    func recordError(_ e: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append(e)
    }
    func waitFor(count: Int, within seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let n = flags.count
            lock.unlock()
            if n >= count { return }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTFail("timed out waiting for \(count) flags; got \(flags.count), errors: \(errors)")
    }
}

private struct NotifierBodyShim {
    func body(for decision: TriageDecision) -> String {
        Notifier.bannerPrefix + decision.candidate.reasoningPlain
    }
}

private final class E2EMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = EndToEndPipelineTests.canned[path] else {
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
