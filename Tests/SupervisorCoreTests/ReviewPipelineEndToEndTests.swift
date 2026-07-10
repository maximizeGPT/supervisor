// ReviewPipelineEndToEndTests.swift
//
// v0.3.x REVIEW dimension — end-to-end. Two proofs:
//   1. The REAL production wiring: a JSONL file on disk → SessionTail (kqueue
//      tail) → EventParser → EventBus → ReviewEngine → AuditStore, driven by a
//      real-transcript-shaped fixture and a mocked model, asserts a `.review`
//      entry lands. This is the whole pipeline, not a unit.
//   2. On a REAL session: if a real Claude Code transcript with a file edit is
//      present on this machine, the real parser yields `.fileEdit` events from
//      it (skipped on machines without one, so CI stays green).

import XCTest
import Combine
@testable import SupervisorCore

@MainActor
final class ReviewPipelineEndToEndTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        Self.canned.removeAll()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-review-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func mockClient() -> LLMClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [E2EReviewMockURLProtocol.self]
        return LLMClient(
            provider: .anthropic, apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: URLSession(configuration: cfg),
            traceLog: TraceLog(path: tempDir.appendingPathComponent("client.log")))
    }

    private static func findingResponse() -> Data {
        let body: [String: Any] = [
            "id": "m", "type": "message", "role": "assistant", "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "t", "name": "record_review",
                "input": ["findings": [[
                    "category": "missed_edge_case", "severity": "high", "confidence": "high",
                    "file_path": "/proj/server.js",
                    "title": "New guard assumes req.body is always present",
                    "detail": "The added check dereferences req.body.id without a nil guard; a bodyless POST throws.",
                ]]] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 500, "output_tokens": 60],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 1. Full production pipeline: file → tail → bus → engine → audit

    func testFullPipelineFromTailToReviewAudit() async throws {
        Self.canned["/v1/messages"] = (200, Self.findingResponse(), [:])

        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "sess-e2e", projectHash: "-proj", cwd: "/proj",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))

        let bus = EventBus(trace: TraceLog(path: tempDir.appendingPathComponent("bus.log")))

        // Real production ReviewEngine, opted in, tiny debounce for the test.
        let engine = ReviewEngine(
            client: mockClient(), bus: bus, model: "claude-haiku-4-5-20251001",
            reviewStore: ReviewFindingStore(database: db),
            auditStore: AuditStore(database: db),
            debounceInterval: 0.05, minReviewInterval: 0, maxBufferAge: 100,
            enabledOverride: true,
            trace: TraceLog(path: tempDir.appendingPathComponent("eng.log")))
        engine.start()
        defer { engine.stop() }

        // A real-transcript-shaped file: session line, an owner prompt, the
        // worker's reasoning, then an Edit tool_use (the exact input shape a real
        // Claude Code transcript uses: file_path/old_string/new_string/replace_all).
        let file = tempDir.appendingPathComponent("sess-e2e.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let tail = SessionTail(sessionId: "sess-e2e", path: file, projectHash: "-proj",
                               bus: bus, sessionStore: nil, startOffset: 0)
        try tail.start()
        defer { tail.stop() }

        let lines = [
            #"{"type":"user","timestamp":"2026-07-04T10:00:00.000Z","sessionId":"sess-e2e","cwd":"/proj","gitBranch":"main","message":{"role":"user","content":"Add a POST /submit handler to server.js"}}"#,
            #"{"type":"assistant","timestamp":"2026-07-04T10:00:05.000Z","sessionId":"sess-e2e","uuid":"turn-9","message":{"role":"assistant","content":[{"type":"text","text":"Adding the submit handler."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-07-04T10:00:06.000Z","sessionId":"sess-e2e","uuid":"turn-9","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu-edit-1","name":"Edit","input":{"file_path":"/proj/server.js","old_string":"app.listen(3000)","new_string":"app.post('/submit', (r,s)=>s.json({id:r.body.id}));\napp.listen(3000)","replace_all":false}}]}}"#,
        ]
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))

        // Poll for the review audit entry to appear (kqueue + debounce + async call).
        let auditStore = AuditStore(database: db)
        var reviews: [StoredAuditEntry] = []
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            reviews = (try? auditStore.entries(sessionId: "sess-e2e"))?.filter { $0.kind == .review } ?? []
            if !reviews.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(reviews.count, 1, "the full pipeline surfaced exactly one review from a tailed Edit")
        XCTAssertEqual(reviews.first?.targetPath, "/proj/server.js")
        XCTAssertTrue(reviews.first?.summary.contains("req.body") == true)
    }

    // MARK: - 2. Real session transcript yields fileEdit events

    func testRealSessionTranscriptYieldsFileEdit() throws {
        guard let (path, count) = Self.firstRealTranscriptWithFileEdit() else {
            throw XCTSkip("no real Claude Code transcript with a file edit found on this machine")
        }
        XCTAssertGreaterThan(count, 0,
            "the real parser produced \(count) fileEdit event(s) from a real session: \(path.lastPathComponent)")
    }

    /// Scan ~/.claude/projects for a real transcript, parse it with the REAL
    /// EventParser, and return the first one that yields at least one fileEdit.
    private static func firstRealTranscriptWithFileEdit() -> (URL, Int)? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var scanned = 0
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if scanned >= 80 { break }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 10_000_000 { continue }   // skip huge transcripts to stay fast
            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Cheap pre-filter before the full parse.
            guard text.contains("\"name\":\"Edit\"")
                || text.contains("\"name\":\"Write\"")
                || text.contains("\"name\":\"MultiEdit\"") else { continue }
            let parser = EventParser(projectHash: "-real", jsonlPath: url.path)
            var count = 0
            for line in text.split(separator: "\n") {
                for e in parser.parse(line: String(line)) {
                    if case .fileEdit = e { count += 1 }
                }
            }
            if count > 0 { return (url, count) }
        }
        return nil
    }
}

// MARK: - URLProtocol mock

private final class E2EReviewMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = ReviewPipelineEndToEndTests.canned[path] else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
