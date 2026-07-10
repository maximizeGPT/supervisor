// SessionReportExporterTests.swift - v0.2.0 observability (Reddit feedback C).
//
// The exporter is a pure read over the stores plus two file writes. The tests
// seed an in-memory DB with a session's audit entries, flags, and a plan with a
// verdict, then assert (a) the gathered model is faithful, (b) the JSON file is
// written and decodes back to the same model, and (c) the Markdown contains the
// session's real content. An empty session must still produce valid output.

import XCTest
@testable import SupervisorCore

final class SessionReportExporterTests: XCTestCase {

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-export-\(UUID().uuidString)")
        return d
    }

    private func seed(_ db: SupervisorDatabase, sessionId: String) throws {
        try SessionStore(database: db).upsert(StoredSession(
            id: sessionId, projectHash: "p", cwd: "/Users/main/repo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_001_000),
            jsonlPath: "/x"
        ))
    }

    private func makeExporter(_ db: SupervisorDatabase) -> SessionReportExporter {
        SessionReportExporter(
            auditStore: AuditStore(database: db),
            flagStore: FlagStore(database: db),
            planStore: PlanStore(database: db),
            sessionStore: SessionStore(database: db)
        )
    }

    func testGatherCollectsAuditFlagsAndPlanWithVerdict() throws {
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-export"
        try seed(db, sessionId: sid)

        try AuditStore(database: db).record(StoredAuditEntry(
            id: "au-1", sessionId: sid, kind: .autoAnswer,
            summary: "Answered: Yes, commit it", question: "Should I commit this?",
            authorizingRule: "§1c"))
        try FlagStore(database: db).insert(StoredFlag(
            id: "fl-1", sessionId: sid, category: "destructive_action_pending",
            severity: .high, action: .pause,
            reasoningPlain: "About to run git reset --hard",
            reasoningTechnical: "deterministic catch"))
        let plan = Plan(
            id: "pl-1", sessionId: sid, objective: "Ship audit log",
            steps: [PlanStep(id: "st-0", index: 0, title: "Storage",
                             objective: "Add the table", doneCriteria: "build green",
                             status: .passed,
                             lastVerdict: PlanStep.Verdict(passed: true, score: 0.95, feedback: "all green"))],
            status: .running)
        try PlanStore(database: db).create(plan)

        let report = try makeExporter(db).gather(sessionId: sid)
        XCTAssertEqual(report.sessionId, sid)
        XCTAssertEqual(report.cwd, "/Users/main/repo")
        XCTAssertEqual(report.auditEntries.count, 1)
        XCTAssertEqual(report.auditEntries.first?.question, "Should I commit this?")
        XCTAssertEqual(report.flags.count, 1)
        XCTAssertEqual(report.flags.first?.severity, "high")
        let p = try XCTUnwrap(report.plan)
        XCTAssertEqual(p.objective, "Ship audit log")
        XCTAssertEqual(p.steps.count, 1)
        let score = try XCTUnwrap(p.steps.first?.verdict?.score)
        XCTAssertEqual(score, 0.95, accuracy: 0.0001)
    }

    func testExportWritesJSONAndMarkdownThatRoundTrips() throws {
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-export-2"
        try seed(db, sessionId: sid)
        try AuditStore(database: db).record(StoredAuditEntry(
            id: "au-1", sessionId: sid, kind: .block,
            summary: "Paused before `git reset --hard`",
            command: "git reset --hard", riskReason: "discards uncommitted changes"))

        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try makeExporter(db).export(sessionId: sid, to: dir)

        // Both files exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.jsonPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.markdownPath.path))
        XCTAssertEqual(out.jsonPath.pathExtension, "json")
        XCTAssertEqual(out.markdownPath.pathExtension, "md")

        // JSON decodes back to the report model with the same content.
        let data = try Data(contentsOf: out.jsonPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionReportExporter.SessionReport.self, from: data)
        XCTAssertEqual(decoded.sessionId, sid)
        XCTAssertEqual(decoded.auditEntries.first?.command, "git reset --hard")

        // Markdown carries the real content + the section headers.
        let md = try String(contentsOf: out.markdownPath, encoding: .utf8)
        XCTAssertTrue(md.contains("# Supervisor session report"))
        XCTAssertTrue(md.contains("## Audit log"))
        XCTAssertTrue(md.contains("git reset --hard"))
    }

    func testExportEmptySessionStillProducesValidFiles() throws {
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-empty"
        try seed(db, sessionId: sid)
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try makeExporter(db).export(sessionId: sid, to: dir)
        let md = try String(contentsOf: out.markdownPath, encoding: .utf8)
        XCTAssertTrue(md.contains("No audit entries recorded"))
        XCTAssertTrue(md.contains("No flags recorded"))
        XCTAssertTrue(md.contains("No plan for this session"))

        // JSON still decodes (empty collections, nil plan).
        let data = try Data(contentsOf: out.jsonPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionReportExporter.SessionReport.self, from: data)
        XCTAssertTrue(decoded.auditEntries.isEmpty)
        XCTAssertNil(decoded.plan)
    }

    // MARK: - Redaction (the exported bundle must match the DB's guarantee)

    /// Deterministic spy: proves the exporter routes cwd + flag reasoning
    /// through the injected redactor (and that it does so exactly there).
    private struct MarkerRedactor: Redactor {
        func redact(_ input: String) -> String {
            input.replacingOccurrences(of: "SECRET", with: "<redacted:test>")
        }
    }

    func testCwdAndFlagReasoningAreRedacted() throws {
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-redact"
        // Seed a cwd + flag reasoning carrying a secret marker.
        try SessionStore(database: db).upsert(StoredSession(
            id: sid, projectHash: "p", cwd: "/Users/main/SECRET/repo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_001_000),
            jsonlPath: "/x"))
        try FlagStore(database: db).insert(StoredFlag(
            id: "fl-1", sessionId: sid, category: "destructive_action_pending",
            severity: .high, action: .pause,
            reasoningPlain: "plain contains SECRET here",
            reasoningTechnical: "technical SECRET too"))

        let exporter = SessionReportExporter(
            auditStore: AuditStore(database: db),
            flagStore: FlagStore(database: db),
            planStore: PlanStore(database: db),
            sessionStore: SessionStore(database: db),
            redactor: MarkerRedactor()
        )
        let report = try exporter.gather(sessionId: sid)

        XCTAssertEqual(report.cwd, "/Users/main/<redacted:test>/repo")
        let flag = try XCTUnwrap(report.flags.first)
        XCTAssertFalse(flag.reasoningPlain.contains("SECRET"))
        XCTAssertFalse(flag.reasoningTechnical.contains("SECRET"))
        XCTAssertTrue(flag.reasoningPlain.contains("<redacted:test>"))
        XCTAssertTrue(flag.reasoningTechnical.contains("<redacted:test>"))
    }

    func testDefaultRedactorScrubsSecretTokenFromExportedReasoning() throws {
        // The production default (DefaultRedactor) must catch a real secret
        // shape in the flag reasoning before it lands in ~/Downloads.
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-redact-default"
        try seed(db, sessionId: sid)
        let token = "ghp_" + String(repeating: "a", count: 36)
        try FlagStore(database: db).insert(StoredFlag(
            id: "fl-1", sessionId: sid, category: "secret_exposure",
            severity: .high, action: .notify,
            reasoningPlain: "leaked \(token) in output",
            reasoningTechnical: "n/a"))

        // makeExporter uses the DefaultRedactor (no injected override).
        let report = try makeExporter(db).gather(sessionId: sid)
        let flag = try XCTUnwrap(report.flags.first)
        XCTAssertFalse(flag.reasoningPlain.contains(token), "raw token must not survive export")
        XCTAssertTrue(flag.reasoningPlain.contains("<redacted:github-token>"))
    }

    func testRepeatedExportsDoNotClobber() throws {
        let db = try SupervisorDatabase.inMemory()
        let sid = "sess-twice"
        try seed(db, sessionId: sid)
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try makeExporter(db).export(sessionId: sid, to: dir, now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = try makeExporter(db).export(sessionId: sid, to: dir, now: Date(timeIntervalSince1970: 1_700_000_077))
        XCTAssertNotEqual(a.jsonPath, b.jsonPath, "distinct timestamps -> distinct filenames")
    }
}
