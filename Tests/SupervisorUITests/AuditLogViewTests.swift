// AuditLogViewTests.swift - v0.2.0 observability (Reddit feedback D + E).
//
// Coverage for the Audit / Activity UI and the decision-sensitivity control:
//   - the HoverViewModel audit accessors (recentAuditEntries / auditEntryCount)
//     read the watched session's entries from AuditStore, mirroring currentPlan:
//     nil-safe without a store, empty before a session is seen, and faithful for
//     the watched session.
//   - the export action routes through exportReportHandler and records an honest
//     success / failure into lastExport (no fake success when no handler / no
//     session).
//   - the sensitivity setter persists + publishes.
//   - the views render (host -> a layout pass that does not trap) across the
//     empty state, a populated log of every audit kind, and each sensitivity stop.

import XCTest
import SwiftUI
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class AuditLogViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(
        auditStore: AuditStore? = nil,
        flagStore: FlagStore? = nil
    ) -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace, flagStore: flagStore, auditStore: auditStore)
        return (vm, bus)
    }

    private func seedSession(_ vm: HoverViewModel, _ bus: EventBus, id: String) {
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: id, cwd: "/Users/main/project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @discardableResult
    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        h.layoutSubtreeIfNeeded()
        return h
    }

    /// audit_entries.session_id has a FOREIGN KEY -> sessions(id), so the session
    /// row must exist before any entry is recorded (matches the exporter tests).
    private func seedSessionRow(_ db: SupervisorDatabase, id: String) throws {
        try SessionStore(database: db).upsert(StoredSession(
            id: id, projectHash: "h", cwd: "/Users/main/project",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
    }

    /// One audit entry of each kind, with the justification fields its row reads.
    private func seedAllKinds(_ store: AuditStore, sessionId sid: String) throws {
        try store.record(StoredAuditEntry(
            id: "au-answer", sessionId: sid, kind: .autoAnswer,
            summary: "Answered: yes, commit it",
            question: "Should I commit this?", authorizingRule: "§1c"))
        try store.record(StoredAuditEntry(
            id: "au-block", sessionId: sid, kind: .block,
            summary: "Blocked a destructive command",
            command: "git reset --hard", targetPath: "/Users/main/project",
            riskReason: "discards uncommitted work"))
        try store.record(StoredAuditEntry(
            id: "au-nudge", sessionId: sid, kind: .nudge,
            summary: "Nudged a stalled session",
            classification: StallClassification.bgTaskSilent.rawValue))
        try store.record(StoredAuditEntry(
            id: "au-verdict", sessionId: sid, kind: .verdict,
            summary: "Step graded: passed (0.92)", detail: "build green, tests pass"))
    }

    // MARK: - VM accessors: recentAuditEntries

    func testRecentAuditEntriesEmptyWithoutStore() {
        let (vm, _) = makeVM(auditStore: nil)
        XCTAssertTrue(vm.recentAuditEntries().isEmpty)
        XCTAssertEqual(vm.auditEntryCount(), 0)
    }

    func testRecentAuditEntriesEmptyWhenNoSessionSeen() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        let store = AuditStore(database: db)
        try store.record(StoredAuditEntry(
            id: "x", sessionId: "sess-1", kind: .autoAnswer, summary: "hi"))
        let (vm, _) = makeVM(auditStore: store)
        // currentSessionId empty -> no entries, even though the DB has one.
        XCTAssertTrue(vm.recentAuditEntries().isEmpty)
    }

    func testRecentAuditEntriesReadsWatchedSession() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        try seedSessionRow(db, id: "sess-2")
        let store = AuditStore(database: db)
        try seedAllKinds(store, sessionId: "sess-1")
        // An entry for a DIFFERENT session must not leak in.
        try store.record(StoredAuditEntry(
            id: "other", sessionId: "sess-2", kind: .nudge, summary: "other session"))

        let (vm, bus) = makeVM(auditStore: store)
        seedSession(vm, bus, id: "sess-1")

        let entries = vm.recentAuditEntries()
        XCTAssertEqual(entries.count, 4, "only the watched session's entries")
        XCTAssertEqual(vm.auditEntryCount(), 4)
        XCTAssertFalse(entries.contains { $0.sessionId == "sess-2" })
        // Newest-first ordering (AuditStore orders by created_at desc); all kinds present.
        XCTAssertEqual(Set(entries.map { $0.kind }),
                       Set([.autoAnswer, .block, .nudge, .verdict]))
    }

    func testRecentAuditEntriesEmptyForSessionWithoutEntries() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = AuditStore(database: db)
        let (vm, bus) = makeVM(auditStore: store)
        seedSession(vm, bus, id: "sess-empty")
        XCTAssertTrue(vm.recentAuditEntries().isEmpty)
    }

    // MARK: - VM export action routing

    func testExportRoutesThroughHandlerAndRecordsSuccess() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = AuditStore(database: db)
        let (vm, bus) = makeVM(auditStore: store)
        seedSession(vm, bus, id: "sess-1")

        let jsonURL = URL(fileURLWithPath: "/tmp/report.json")
        let mdURL = URL(fileURLWithPath: "/tmp/report.md")
        var requestedSession: String?
        let exp = expectation(description: "handler invoked")
        vm.exportReportHandler = { sid in
            requestedSession = sid
            exp.fulfill()
            return SessionReportExporter.Output(jsonPath: jsonURL, markdownPath: mdURL)
        }

        vm.exportSessionReport()
        wait(for: [exp], timeout: 1.0)
        // Let the @MainActor continuation that stores lastExport run.
        let settle = expectation(description: "result stored")
        Task { @MainActor in try? await Task.sleep(nanoseconds: 50_000_000); settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertEqual(requestedSession, "sess-1")
        XCTAssertEqual(vm.lastExport, .success(jsonPath: jsonURL, markdownPath: mdURL))
        XCTAssertFalse(vm.isExporting)
    }

    func testExportRecordsFailureWithoutHandler() {
        let (vm, bus) = makeVM()
        seedSession(vm, bus, id: "sess-1")
        vm.exportSessionReport()   // no handler wired
        guard case .failure = vm.lastExport else {
            return XCTFail("export with no handler must record a failure, not a fake success")
        }
        XCTAssertFalse(vm.isExporting)
    }

    func testExportRecordsFailureWithoutSession() {
        let (vm, _) = makeVM()
        // No session seen -> currentSessionId empty.
        vm.exportSessionReport()
        guard case .failure = vm.lastExport else {
            return XCTFail("export with no session must record a failure")
        }
    }

    // MARK: - Sensitivity setter

    func testSetDecisionSensitivityPublishes() {
        let (vm, _) = makeVM()
        // Default seeded from the persisted store; set away from it and assert the
        // published value tracks. (The persistence round-trip itself is covered
        // hermetically in DecisionSensitivityTests against an isolated suite.)
        vm.setDecisionSensitivity(.cautious)
        XCTAssertEqual(vm.decisionSensitivity, .cautious)
        vm.setDecisionSensitivity(.decisive)
        XCTAssertEqual(vm.decisionSensitivity, .decisive)
        // Restore the real default so the test leaves no machine-visible change.
        vm.setDecisionSensitivity(.balanced)
        XCTAssertEqual(vm.decisionSensitivity, .balanced)
    }

    // MARK: - Render smoke (a layout pass that does not trap)

    func testAuditLogViewRendersEmptyState() {
        let (vm, _) = makeVM()
        host(AuditLogView(vm: vm))
    }

    func testAuditLogViewRendersPopulatedAllKinds() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        let store = AuditStore(database: db)
        try seedAllKinds(store, sessionId: "sess-1")
        let (vm, bus) = makeVM(auditStore: store)
        seedSession(vm, bus, id: "sess-1")
        host(AuditLogView(vm: vm))
    }

    func testAuditEntryRowRendersForEveryKind() {
        for kind in AuditEntryKind.allCases {
            let entry = StoredAuditEntry(
                sessionId: "s", kind: kind,
                summary: "A \(kind.rawValue) happened",
                question: "Q?", authorizingRule: "§1c",
                command: "git reset --hard", targetPath: "/p", riskReason: "risky",
                classification: StallClassification.crashed.rawValue,
                detail: "extra")
            host(AuditEntryRow(entry))
            host(AuditKindBadge(kind))
        }
    }

    func testSensitivityControlRendersForEachStop() {
        for stop in DecisionSensitivity.allCases {
            let (vm, _) = makeVM()
            vm.setDecisionSensitivity(stop)
            host(SensitivityControl(vm: vm))
            vm.setDecisionSensitivity(.balanced)   // leave no machine-visible change
        }
    }

    // MARK: - Audit kind badge / classification mappings (pure)

    func testAuditKindBadgeBlockUsesAttentionTone() {
        XCTAssertEqual(AuditKindBadge.tone(for: .block), BrandColor.attention.color)
        // Non-block kinds stay quiet mute (no green; that's the one primary action).
        XCTAssertEqual(AuditKindBadge.tone(for: .autoAnswer), BrandColor.mute.color)
        XCTAssertEqual(AuditKindBadge.tone(for: .nudge), BrandColor.mute.color)
    }

    func testClassificationLabelMapsToHumanReason() {
        XCTAssertEqual(
            AuditEntryRow.classificationLabel(StallClassification.crashed.rawValue),
            StallClassification.crashed.humanReason)
        // Unknown raw value degrades to the raw string, not a crash.
        XCTAssertEqual(AuditEntryRow.classificationLabel("mystery"), "mystery")
    }

    // MARK: - Merged activity timeline

    func testRecentActivityMergesFlagsWithAuditEntries() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        let auditStore = AuditStore(database: db)
        let flagStore = FlagStore(database: db)
        try auditStore.record(StoredAuditEntry(
            id: "au-1", sessionId: "sess-1", kind: .autoAnswer,
            summary: "Answered a question"))
        // Low severity flag: should be filtered out.
        try flagStore.insert(StoredFlag(
            id: "f-low", sessionId: "sess-1", category: "style",
            severity: .low, action: .notify,
            reasoningPlain: "Mild suggestion", reasoningTechnical: "tech"))
        // Medium severity flag: should appear.
        try flagStore.insert(StoredFlag(
            id: "f-med", sessionId: "sess-1", category: "safety",
            severity: .medium, action: .notify,
            reasoningPlain: "Risky pattern", reasoningTechnical: "tech"))
        // High severity flag: should appear.
        try flagStore.insert(StoredFlag(
            id: "f-high", sessionId: "sess-1", category: "destructive",
            severity: .high, action: .pause,
            reasoningPlain: "Destructive command", reasoningTechnical: "tech"))

        let (vm, bus) = makeVM(auditStore: auditStore, flagStore: flagStore)
        seedSession(vm, bus, id: "sess-1")

        let items = vm.recentActivity()
        XCTAssertEqual(items.count, 3, "1 audit + 2 significant flags (low filtered)")
        let ids = Set(items.map(\.id))
        XCTAssertTrue(ids.contains("a-au-1"))
        XCTAssertTrue(ids.contains("f-f-med"))
        XCTAssertTrue(ids.contains("f-f-high"))
        XCTAssertFalse(ids.contains("f-f-low"), "low severity must be filtered out")
    }

    func testActivityCountIncludesSignificantFlags() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        let auditStore = AuditStore(database: db)
        let flagStore = FlagStore(database: db)
        try auditStore.record(StoredAuditEntry(
            id: "au-1", sessionId: "sess-1", kind: .block, summary: "blocked"))
        try flagStore.insert(StoredFlag(
            id: "f-1", sessionId: "sess-1", category: "safety",
            severity: .high, action: .notify,
            reasoningPlain: "high", reasoningTechnical: "tech"))
        try flagStore.insert(StoredFlag(
            id: "f-2", sessionId: "sess-1", category: "style",
            severity: .low, action: .notify,
            reasoningPlain: "low", reasoningTechnical: "tech"))

        let (vm, bus) = makeVM(auditStore: auditStore, flagStore: flagStore)
        seedSession(vm, bus, id: "sess-1")

        XCTAssertEqual(vm.activityCount(), 2, "1 audit + 1 high flag; low excluded")
    }

    func testRecentActivityEmptyWithoutStores() {
        let (vm, _) = makeVM()
        XCTAssertTrue(vm.recentActivity().isEmpty)
        XCTAssertEqual(vm.activityCount(), 0)
    }

    func testFlagTimelineRowRenders() {
        let flag = StoredFlag(
            sessionId: "s", category: "safety", severity: .high, action: .pause,
            reasoningPlain: "Destructive command detected", reasoningTechnical: "tech")
        host(FlagTimelineRow(flag))
    }

    func testAuditLogViewRendersMergedTimeline() throws {
        let db = try SupervisorDatabase.inMemory()
        try seedSessionRow(db, id: "sess-1")
        let auditStore = AuditStore(database: db)
        let flagStore = FlagStore(database: db)
        try seedAllKinds(auditStore, sessionId: "sess-1")
        try flagStore.insert(StoredFlag(
            id: "f-1", sessionId: "sess-1", category: "safety",
            severity: .high, action: .notify,
            reasoningPlain: "high sev flag", reasoningTechnical: "tech"))
        let (vm, bus) = makeVM(auditStore: auditStore, flagStore: flagStore)
        seedSession(vm, bus, id: "sess-1")
        host(AuditLogView(vm: vm))
    }
}
