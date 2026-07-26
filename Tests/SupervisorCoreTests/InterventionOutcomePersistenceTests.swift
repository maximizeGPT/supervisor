// InterventionOutcomePersistenceTests.swift
//
// issue #60 follow-up: the REAL intervention outcome must land on the flag
// row. Exercises the production write path — the Notifier result hook calls
// HoverViewModel.recordInterventionOutcome(decision, outcome), which writes
// flags.intervention_outcome via FlagStore.markInterventionOutcome using the
// flag id the app stamped onto the decision after the FlagStore insert.
// Deterministic: in-memory DB, no live API, no notification center.

import XCTest
@testable import SupervisorCore

final class InterventionOutcomePersistenceTests: XCTestCase {

    private func makeDecision(flagId: String?) -> TriageDecision {
        TriageDecision(
            sessionId: "s",
            candidate: TriageCandidate(
                category: "user_question_pending",
                severity: .medium,
                matchedCommand: "(question)",
                action: .inject,
                reasoningPlain: "Claude Code asked a question.",
                reasoningTechnical: "test"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "s",
                command: "(question)",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                  cache_creation_input_tokens: nil,
                                  cache_read_input_tokens: nil),
            model: "claude-haiku-4-5-20251001",
            prePost: .preExecution,
            flagId: flagId
        )
    }

    @MainActor
    private func makeVM(flagStore: FlagStore) -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-persist-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        return HoverViewModel(bus: bus, trace: trace, flagStore: flagStore)
    }

    private func seededFlag(in db: SupervisorDatabase) throws -> (FlagStore, StoredFlag) {
        try SessionStore(database: db).upsert(StoredSession(
            id: "s", projectHash: "p", cwd: "/c",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "s", category: "user_question_pending", severity: .medium,
            action: .inject, reasoningPlain: "p", reasoningTechnical: "t"
        )
        try store.insert(flag)
        return (store, flag)
    }

    /// The hook path: a decision carrying the persisted flag's id writes the
    /// executor's REAL outcome onto that exact row.
    @MainActor
    func testRecordInterventionOutcomePersistsOntoFlagRow() throws {
        let db = try SupervisorDatabase.inMemory()
        let (store, flag) = try seededFlag(in: db)
        let vm = makeVM(flagStore: store)

        vm.recordInterventionOutcome(
            makeDecision(flagId: flag.id),
            .injectDegraded(intendedText: "answer", reason: "locator_nil", copiedToClipboard: true)
        )

        XCTAssertEqual(try store.recent(sessionId: "s")[0].interventionOutcome, .injectDegraded,
                       "the REAL (degraded) outcome lands on the row — never the intent")
    }

    /// notifyOnly records no in-memory action (actionForOutcome returns nil),
    /// but it is still a real outcome the scorecard counts — the persistence
    /// must happen BEFORE the action-log gate.
    @MainActor
    func testNotifyOnlyOutcomePersistsDespiteRecordingNoAction() throws {
        let db = try SupervisorDatabase.inMemory()
        let (store, flag) = try seededFlag(in: db)
        let vm = makeVM(flagStore: store)

        vm.recordInterventionOutcome(makeDecision(flagId: flag.id), .notifyOnly)

        XCTAssertEqual(try store.recent(sessionId: "s")[0].interventionOutcome, .notifyOnly)
        XCTAssertTrue(vm.recentActions.isEmpty,
                      "notifyOnly still records no in-memory action (unchanged behavior)")
    }

    /// A decision that was never persisted (flagId == nil — tests, older
    /// callers) skips the write and leaves every row untouched.
    @MainActor
    func testNilFlagIdSkipsPersistence() throws {
        let db = try SupervisorDatabase.inMemory()
        let (store, _) = try seededFlag(in: db)
        let vm = makeVM(flagStore: store)

        vm.recordInterventionOutcome(
            makeDecision(flagId: nil),
            .injectSucceeded(pid: 1, bytes: 42)
        )

        XCTAssertNil(try store.recent(sessionId: "s")[0].interventionOutcome,
                     "no flag id -> no write; the seeded row stays outcome-less")
    }
}
