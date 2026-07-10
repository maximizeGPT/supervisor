// ReviewEngineTests.swift
//
// v0.3.x REVIEW dimension — the engine. Mirrors EvaluatorTests' URLProtocol
// mock so the review LLM call is observable, and an in-memory SupervisorDatabase
// so the dedup ledger + audit surface are assertable. Covers the behavior that
// makes REVIEW safe and quiet:
//   - it fires over a turn's edits and records a surfaced finding (audit + ledger),
//   - it is INERT when the opt-in is off (no call, no findings),
//   - it DEDUPS a repeated finding across turns (surfaces once),
//   - the Decision Sensitivity dial is the confidence gate (Cautious hides
//     medium-confidence findings; low confidence never surfaces),
//   - a per-review cap bounds how many findings one review surfaces,
//   - the prompt keeps its high-bar, empty-is-correct framing (a guard so the
//     noise-control language can't be silently removed).

import XCTest
import GRDB
@testable import SupervisorCore

@MainActor
final class ReviewEngineTests: XCTestCase {

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        Self.canned.removeAll()
    }

    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        try await super.tearDown()
    }

    // MARK: - Harness

    private final class Sink: @unchecked Sendable { var items: [SurfacedReview] = [] }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ReviewMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeClient() -> LLMClient {
        LLMClient(
            provider: .anthropic,
            apiKey: "sk-ant-test",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: mockSession(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("review-client-\(UUID().uuidString).log")))
    }

    private func seededDB() throws -> SupervisorDatabase {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/proj",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        return db
    }

    private func makeEngine(
        db: SupervisorDatabase,
        enabled: Bool = true,
        sensitivity: @escaping @Sendable () -> DecisionSensitivity = { .balanced },
        maxSurfaced: Int = 3,
        sink: Sink? = nil
    ) -> ReviewEngine {
        ReviewEngine(
            client: makeClient(),
            bus: EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("review-bus-\(UUID().uuidString).log"))),
            model: "claude-haiku-4-5-20251001",
            reviewStore: ReviewFindingStore(database: db),
            auditStore: AuditStore(database: db),
            redactor: DefaultRedactor(),
            debounceInterval: 0.05,
            minReviewInterval: 0,
            maxBufferAge: 100,
            maxSurfacedPerReview: maxSurfaced,
            enabledOverride: enabled,
            sensitivity: sensitivity,
            onFinding: { s in sink?.items.append(s) },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("review-eng-\(UUID().uuidString).log")))
    }

    private static func reviewResponse(_ findings: [[String: Any]]) -> Data {
        let body: [String: Any] = [
            "id": "msg_review", "type": "message", "role": "assistant",
            "model": "claude-haiku-4-5-20251001",
            "content": [[
                "type": "tool_use", "id": "toolu_review", "name": "record_review",
                "input": ["findings": findings] as [String: Any],
            ]],
            "stop_reason": "tool_use", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 800, "output_tokens": 90],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func finding(
        category: String = "missed_edge_case",
        severity: String = "medium",
        confidence: String = "high",
        filePath: String = "/proj/A.swift",
        title: String = "Nil deref when the list is empty",
        detail: String = "first() is force-unwrapped; an empty list crashes."
    ) -> [String: Any] {
        ["category": category, "severity": severity, "confidence": confidence,
         "file_path": filePath, "title": title, "detail": detail]
    }

    private func edit(uuid: String = "turn-1", file: String = "/proj/A.swift") -> FileEditInfo {
        FileEditInfo(sessionId: "s", toolName: "Edit", filePath: file,
                     hunks: [.init(oldString: "let a = xs.first", newString: "let a = xs.first!")],
                     toolUseId: "tu-\(uuid)", turnUUID: uuid, ts: Date())
    }

    /// Feed a turn's worth of context + one edit, then review deterministically
    /// (call runReview directly rather than waiting on the debounce timer).
    private func feedTurnAndReview(_ engine: ReviewEngine, edit: FileEditInfo, objective: String = "Fix the crash in A.swift") async {
        engine.consume(event: .sessionStart(.init(sessionId: "s", cwd: "/proj", gitBranch: "main", projectHash: "p", jsonlPath: "/x", ts: Date())))
        engine.consume(event: .userPrompt(.init(sessionId: "s", text: objective, ts: Date())))
        engine.consume(event: .assistantText(.init(sessionId: "s", text: "Guarding the empty case.", turnUUID: edit.turnUUID, ts: Date())))
        engine.consume(event: .fileEdit(edit))
        await engine.runReview(sessionId: "s")
    }

    // MARK: - Fires + records

    func testReviewSurfacesFindingToAuditAndLedger() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding()]), [:])
        let sink = Sink()
        let engine = makeEngine(db: db, sink: sink)

        await feedTurnAndReview(engine, edit: edit())

        let audit = try AuditStore(database: db).entries(sessionId: "s")
        XCTAssertEqual(audit.count, 1, "one review audit entry")
        XCTAssertEqual(audit.first?.kind, .review)
        XCTAssertEqual(audit.first?.targetPath, "/proj/A.swift")
        XCTAssertEqual(audit.first?.summary, "Nil deref when the list is empty")
        XCTAssertTrue(audit.first?.classification?.contains("high confidence") == true)

        let surfaced = try ReviewFindingStore(database: db).recent(sessionId: "s")
        XCTAssertEqual(surfaced.count, 1)
        XCTAssertEqual(surfaced.first?.surfaced, true)
        XCTAssertEqual(sink.items.count, 1, "the hover callback fired once")
        XCTAssertEqual(sink.items.first?.title, "Nil deref when the list is empty")
    }

    func testAllClearRecordsNothing() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([]), [:])  // empty findings
        let engine = makeEngine(db: db)

        await feedTurnAndReview(engine, edit: edit())

        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 0, "an all-clear review surfaces nothing")
        XCTAssertEqual(try ReviewFindingStore(database: db).count(sessionId: "s"), 0)
    }

    // MARK: - Opt-in gate

    func testDisabledEngineDoesNotReview() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding()]), [:])
        let engine = makeEngine(db: db, enabled: false)

        await feedTurnAndReview(engine, edit: edit())

        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 0, "opt-in OFF: no review, no findings")
        XCTAssertEqual(try ReviewFindingStore(database: db).count(sessionId: "s"), 0)
    }

    // MARK: - Dedup

    func testRepeatedFindingSurfacesOnce() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding()]), [:])
        let engine = makeEngine(db: db)

        await feedTurnAndReview(engine, edit: edit(uuid: "turn-1"))
        // Same finding again on a later turn touching the same file.
        await feedTurnAndReview(engine, edit: edit(uuid: "turn-2"))

        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 1,
                       "the same finding on the same file surfaces exactly once across turns")
    }

    // MARK: - Confidence gate (Decision Sensitivity)

    func testCautiousHidesMediumConfidence() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding(confidence: "medium")]), [:])
        let engine = makeEngine(db: db, sensitivity: { .cautious })

        await feedTurnAndReview(engine, edit: edit())

        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 0,
                       "Cautious surfaces only high confidence — a medium finding is withheld")
        // It is still recorded (surfaced=false) so the gate is tunable without data loss.
        XCTAssertEqual(try ReviewFindingStore(database: db).count(sessionId: "s", surfacedOnly: false), 1)
        XCTAssertEqual(try ReviewFindingStore(database: db).count(sessionId: "s", surfacedOnly: true), 0)
    }

    func testLowConfidenceNeverSurfacesEvenBalanced() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding(confidence: "low")]), [:])
        let engine = makeEngine(db: db, sensitivity: { .balanced })

        await feedTurnAndReview(engine, edit: edit())
        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 0, "low confidence stays quiet")
    }

    func testBalancedSurfacesMediumConfidence() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding(confidence: "medium")]), [:])
        let engine = makeEngine(db: db, sensitivity: { .balanced })

        await feedTurnAndReview(engine, edit: edit())
        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 1, "Balanced surfaces medium+")
    }

    // MARK: - Per-review cap

    func testPerReviewSurfacingCap() async throws {
        let db = try seededDB()
        let many = (0..<6).map { Self.finding(title: "Issue number \($0)") }
        Self.canned["/v1/messages"] = (200, Self.reviewResponse(many), [:])
        let engine = makeEngine(db: db, maxSurfaced: 2)

        await feedTurnAndReview(engine, edit: edit())
        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 2,
                       "one review surfaces at most the cap; the rest are stored but not shown")
        XCTAssertEqual(try ReviewFindingStore(database: db).count(sessionId: "s", surfacedOnly: false), 6,
                       "all findings are still recorded")
    }

    // MARK: - Debounce wiring (timer path)

    func testDebounceTimerFiresReview() async throws {
        let db = try seededDB()
        Self.canned["/v1/messages"] = (200, Self.reviewResponse([Self.finding()]), [:])
        let engine = makeEngine(db: db)

        engine.consume(event: .sessionStart(.init(sessionId: "s", cwd: "/proj", gitBranch: "main", projectHash: "p", jsonlPath: "/x", ts: Date())))
        engine.consume(event: .fileEdit(edit()))
        // Do NOT call runReview — let the debounce timer fire it.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(try AuditStore(database: db).count(sessionId: "s"), 1,
                       "the debounce timer reviews the buffered edit on its own")
    }

    // MARK: - Parsing + prompt guards

    func testParseFindingsDropsMalformedButKeepsValid() throws {
        let db = try seededDB()
        let engine = makeEngine(db: db)
        let resp = try JSONDecoder().decode(AnthropicMessageResponse.self, from: Self.reviewResponse([
            Self.finding(title: "Valid one"),
            ["category": "not_a_category", "severity": "high", "confidence": "high",
             "file_path": "/x", "title": "bad category", "detail": "d"],   // dropped
            ["severity": "high"],                                          // missing fields, dropped
        ]))
        let parsed = engine.parseFindings(from: resp)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.title, "Valid one")
    }

    /// Guard: the reviewer prompt must keep its high-bar, empty-is-correct
    /// framing, and the edits must render as a diff — the core noise-control
    /// contract, protected from a silent edit.
    func testPromptKeepsHighBarFraming() {
        let sys = ReviewPrompt.systemPrompt
        XCTAssertTrue(sys.contains("empty `findings` array is the correct"), "empty is explicitly correct")
        XCTAssertTrue(sys.contains("Silence is better than a low-value nitpick"))
        XCTAssertTrue(sys.contains("Do NOT report"), "the not-a-finding list is present")
        XCTAssertTrue(sys.contains("Documentation typos"), "the cosmetic/doc exclusion clause is present so it can't be silently removed")
        // QA-hardening (live DeepSeek eval): the grounding + calibration rules that
        // closed the "confident hallucination" failure mode must not be edited out.
        XCTAssertTrue(sys.contains("Grounding"), "the grounding-to-diff rule is present")
        XCTAssertTrue(sys.contains("Safe as written = silence"), "the calibration/abstention rule is present")
        XCTAssertTrue(sys.contains("enumerate every control-flow branch"), "the new-branch check is present")

        let msg = ReviewPrompt.userMessage(ReviewInput(
            cwd: "/proj", gitBranch: "main",
            objective: "Fix the crash", objectiveFromOwner: true,
            assistantReasoning: "Guard the empty case.",
            edits: [FileEditInfo(sessionId: "s", toolName: "Edit", filePath: "/proj/A.swift",
                                 hunks: [.init(oldString: "old line", newString: "new line")],
                                 toolUseId: "t", turnUUID: "u", ts: Date())],
            priorContext: []))
        XCTAssertTrue(msg.contains("REMOVED:"), "an edit renders its removed text")
        XCTAssertTrue(msg.contains("ADDED:"), "an edit renders its added text")
        XCTAssertTrue(msg.contains("/proj/A.swift"))
    }
}

// MARK: - URLProtocol mock

private final class ReviewMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = ReviewEngineTests.canned[path] else {
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
