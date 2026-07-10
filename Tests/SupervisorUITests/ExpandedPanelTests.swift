// ExpandedPanelTests.swift — v0.1.7.
//
// Coverage for the expanded panel feature: session metrics tracking
// (turn count, tool call count), toggle state, cost formatting,
// relative time display, and flag list population.

import XCTest
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class ExpandedPanelTests: XCTestCase {

    private func makeVM(
        initialFlagCount: Int = 0,
        modelName: String = "claude-haiku-4-5-20251001"
    ) -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(
            bus: bus,
            trace: trace,
            initialFlagCount: initialFlagCount,
            modelName: modelName
        )
        return (vm, bus)
    }

    // MARK: - Session metrics

    func testTurnCountIncreasesOnUserPrompt() {
        let (vm, bus) = makeVM()
        XCTAssertEqual(vm.turnCount, 0)

        bus.publish(.userPrompt(UserPromptInfo(
            sessionId: "s1", text: "fix the bug", ts: Date()
        )))
        // EventBus dispatches via Task; give it a tick.
        let exp = expectation(description: "turn count updated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 1)
    }

    func testToolCallCountIncreasesOnBashToolCall() {
        let (vm, bus) = makeVM()
        XCTAssertEqual(vm.toolCallCount, 0)

        bus.publish(.bashToolCall(BashToolCallInfo(
            sessionId: "s1", command: "git status", description: nil,
            toolUseId: "t1", turnUUID: "u1", ts: Date()
        )))
        let exp = expectation(description: "tool count updated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(vm.toolCallCount, 1)
    }

    func testSessionStartResetsMetrics() {
        let (vm, bus) = makeVM()

        // Accumulate some counts.
        bus.publish(.userPrompt(UserPromptInfo(
            sessionId: "s1", text: "hello", ts: Date()
        )))
        bus.publish(.bashToolCall(BashToolCallInfo(
            sessionId: "s1", command: "ls", description: nil,
            toolUseId: "t1", turnUUID: "u1", ts: Date()
        )))
        let exp1 = expectation(description: "counts accumulated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 1)
        XCTAssertEqual(vm.toolCallCount, 1)

        // New session resets.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s2", cwd: "/Users/main/new-project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp2 = expectation(description: "metrics reset")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 0)
        XCTAssertEqual(vm.toolCallCount, 0)
        XCTAssertEqual(vm.sessionCwd, "/Users/main/new-project")
    }

    // MARK: - Toggle

    func testToggleExpandedFlipsState() {
        let (vm, _) = makeVM()
        XCTAssertFalse(vm.isExpanded)
        vm.toggleExpanded()
        XCTAssertTrue(vm.isExpanded)
        vm.toggleExpanded()
        XCTAssertFalse(vm.isExpanded)
    }

    // MARK: - Multi-session band (one band, aggregated label)

    /// The fix for the stacked "Watching... All clear" bands: when Supervisor
    /// watches several sessions, the ONE band aggregates the count rather than
    /// flipping between project names. 2+ sessions reads "Watching N sessions".
    func testMultipleSessionsAggregateIdleLabel() {
        let (vm, _) = makeVM()
        vm.setWatchedSessionCount(3)
        XCTAssertEqual(vm.watchedSessionCount, 3)
        XCTAssertEqual(vm.plainLabel, "Watching 3 sessions. All clear")
    }

    /// One session keeps the exact prior wording (no project name yet -> the
    /// bare "Watching. All clear"); the single-session behavior is unchanged.
    func testSingleSessionKeepsPriorIdleLabel() {
        let (vm, _) = makeVM()
        vm.setWatchedSessionCount(1)
        XCTAssertEqual(vm.plainLabel, "Watching. All clear")
    }

    /// Zero sessions also keeps the bare "Watching. All clear" (the resting
    /// label before any session is seen).
    func testZeroSessionsKeepsBareIdleLabel() {
        let (vm, _) = makeVM()
        vm.setWatchedSessionCount(0)
        XCTAssertEqual(vm.plainLabel, "Watching. All clear")
    }

    /// With a known project AND multiple sessions, the count wins over the
    /// single project name: the band tells the user how many it's watching.
    func testMultiSessionLabelOverridesProjectName() {
        let (vm, bus) = makeVM()
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s1", cwd: "/Users/main/alpha",
            gitBranch: "main", projectHash: "h", jsonlPath: "/tmp/a.jsonl", ts: Date()
        )))
        let exp = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(vm.plainLabel, "Watching alpha. All clear")

        vm.setWatchedSessionCount(2)
        XCTAssertEqual(vm.plainLabel, "Watching 2 sessions. All clear")
    }

    /// The count never stomps a flag headline: a pause label survives a
    /// session-count update (the count only colors the calm idle state).
    func testSessionCountDoesNotStompFlagLabel() {
        let (vm, _) = makeVM()
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: nil)
        let flagged = vm.plainLabel
        vm.setWatchedSessionCount(4)
        XCTAssertEqual(vm.plainLabel, flagged,
                       "a session-count update must not overwrite an active flag label")
    }

    /// Setting the same count is a no-op and does not disturb the label.
    func testSettingUnchangedCountIsNoOp() {
        let (vm, _) = makeVM()
        vm.setWatchedSessionCount(2)
        vm.flagRaised(severity: .medium, action: .notify, reasoningPlain: nil)
        let labelBefore = vm.plainLabel
        vm.setWatchedSessionCount(2)   // unchanged -> no-op
        XCTAssertEqual(vm.plainLabel, labelBefore)
    }

    // MARK: - Model name

    func testModelNameSetAtInit() {
        let (vm, _) = makeVM(modelName: "deepseek-chat")
        XCTAssertEqual(vm.modelName, "deepseek-chat")
    }

    // MARK: - Cost formatting

    func testFormatCostZero() {
        XCTAssertEqual(ExpandedPanelView.formatCost(0), "$0.00")
    }

    func testFormatCostSubPenny() {
        XCTAssertEqual(ExpandedPanelView.formatCost(0.005), "$0.00")
    }

    func testFormatCostNormal() {
        XCTAssertEqual(ExpandedPanelView.formatCost(1.234), "$1.23")
    }

    func testFormatCostLarge() {
        XCTAssertEqual(ExpandedPanelView.formatCost(42.50), "$42.50")
    }

    // MARK: - Relative time

    func testRelativeTimeJustNow() {
        let recent = Date().addingTimeInterval(-30)
        XCTAssertEqual(ExpandedPanelView.relativeTime(recent), "just now")
    }

    func testRelativeTimeMinutes() {
        let fiveMinAgo = Date().addingTimeInterval(-300)
        XCTAssertEqual(ExpandedPanelView.relativeTime(fiveMinAgo), "5m")
    }

    func testRelativeTimeHours() {
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        XCTAssertEqual(ExpandedPanelView.relativeTime(twoHoursAgo), "2h")
    }

    func testRelativeTimeDays() {
        let twoDaysAgo = Date().addingTimeInterval(-172800)
        XCTAssertEqual(ExpandedPanelView.relativeTime(twoDaysAgo), "2d")
    }

    // MARK: - No stores returns sensible defaults

    func testTodayCostWithoutStoreReturnsZero() {
        let (vm, _) = makeVM()
        XCTAssertEqual(vm.todayCostUSD(), 0)
    }

    func testRecentFlagsWithoutStoreReturnsEmpty() {
        let (vm, _) = makeVM()
        XCTAssertTrue(vm.recentFlags().isEmpty)
    }

    // MARK: - Resume (SIGCONT)

    func testIsPausedReturnsTrueWhenFlaggedWithPause() {
        let (vm, _) = makeVM()
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "danger")
        XCTAssertTrue(vm.isPaused)
    }

    func testIsPausedReturnsFalseWhenNotPaused() {
        let (vm, _) = makeVM()
        XCTAssertFalse(vm.isPaused)
        vm.flagRaised(severity: .medium, action: .notify, reasoningPlain: "info")
        XCTAssertFalse(vm.isPaused)
    }

    func testResumeCallsHandlerAndAcknowledgesOnSuccess() {
        let (vm, bus) = makeVM()
        // Set up session cwd via sessionStart event.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s1", cwd: "/Users/main/project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp1 = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        // Simulate pause flag.
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "danger")
        XCTAssertTrue(vm.isPaused)

        // Wire resume handler that succeeds.
        var handlerCwd: String?
        vm.resumeHandler = { cwd in
            handlerCwd = cwd
            return true
        }

        vm.resumePausedSession()

        let exp2 = expectation(description: "resume completes")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertEqual(handlerCwd, "/Users/main/project")
        // After successful resume, flag should be acknowledged (idle).
        XCTAssertFalse(vm.isPaused)
        XCTAssertEqual(vm.activity, .idle)
    }

    func testResumeDoesNotAcknowledgeOnFailure() {
        let (vm, bus) = makeVM()
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s1", cwd: "/Users/main/project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp1 = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "danger")

        // Wire resume handler that fails.
        vm.resumeHandler = { _ in return false }

        vm.resumePausedSession()

        let exp2 = expectation(description: "resume completes")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)

        // Should still be paused after failed resume.
        XCTAssertTrue(vm.isPaused)
    }

    func testResumeNoOpWithoutHandler() {
        let (vm, _) = makeVM()
        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "danger")
        // No handler wired — should be a no-op, not crash.
        vm.resumePausedSession()
        XCTAssertTrue(vm.isPaused)
    }

    func testResumeNoOpWhenNotPaused() {
        let (vm, _) = makeVM()
        var handlerCalled = false
        vm.resumeHandler = { _ in
            handlerCalled = true
            return true
        }
        // Not paused — resume should be a no-op.
        vm.resumePausedSession()
        XCTAssertFalse(handlerCalled)
    }

    // MARK: - Flag response (Dismiss / False positive)

    func testRespondToFlagPersistsResponse() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "s1", projectHash: "h", cwd: "/x",
            startedAt: Date(), lastSeenAt: Date(),
            jsonlPath: "/x"
        ))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            id: "flag1", sessionId: "s1",
            category: "destructive_action_pending",
            severity: .high, action: .notify,
            reasoningPlain: "rm -rf detected",
            reasoningTechnical: "technical details"
        )
        try store.insert(flag)

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(
            bus: bus, trace: trace, flagStore: store
        )

        vm.respondToFlag(flagId: "flag1", response: .dismissed)

        // Verify persistence.
        let flags = try store.recent(limit: 10)
        XCTAssertEqual(flags.first?.userResponse, .dismissed)
    }

    func testRespondToFlagFalsePositivePersists() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "s1", projectHash: "h", cwd: "/x",
            startedAt: Date(), lastSeenAt: Date(),
            jsonlPath: "/x"
        ))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            id: "flag2", sessionId: "s1",
            category: "injection_detected",
            severity: .medium, action: .notify,
            reasoningPlain: "injection pattern",
            reasoningTechnical: "technical details"
        )
        try store.insert(flag)

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(
            bus: bus, trace: trace, flagStore: store
        )

        vm.respondToFlag(flagId: "flag2", response: .falsePositive)

        let flags = try store.recent(limit: 10)
        XCTAssertEqual(flags.first?.userResponse, .falsePositive)
    }

    func testRespondToFlagNoOpWithoutStore() {
        let (vm, _) = makeVM()
        // Should not crash when flagStore is nil.
        vm.respondToFlag(flagId: "nonexistent", response: .dismissed)
    }

    func testRejectFlagPersistsRejectedResponse() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "s1", projectHash: "h", cwd: "/x",
            startedAt: Date(), lastSeenAt: Date(),
            jsonlPath: "/x"
        ))
        let store = FlagStore(database: db)
        let flag = StoredFlag(
            id: "flag3", sessionId: "s1",
            category: "destructive_action_pending",
            severity: .high, action: .notify,
            reasoningPlain: "rm -rf detected",
            reasoningTechnical: "technical details"
        )
        try store.insert(flag)

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(
            bus: bus, trace: trace, flagStore: store
        )

        vm.rejectFlag(flagId: "flag3", action: .notify)

        let flags = try store.recent(limit: 10)
        XCTAssertEqual(flags.first?.userResponse, .rejected)
    }

    // MARK: - Session-scoped flags (RC fix #4)

    /// `recentFlags` must return ONLY the watched session's flags. Before the
    /// fix it called the store with no sessionId, so a concurrent session's
    /// flags bled into the Status tab's list.
    func testRecentFlagsIsSessionScoped() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "s1", projectHash: "h", cwd: "/x",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        try sessionStore.upsert(StoredSession(
            id: "s2", projectHash: "h", cwd: "/y",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/y"))
        let store = FlagStore(database: db)
        try store.insert(StoredFlag(
            id: "f1", sessionId: "s1", category: "c",
            severity: .high, action: .notify,
            reasoningPlain: "one", reasoningTechnical: "t"))
        try store.insert(StoredFlag(
            id: "f2", sessionId: "s2", category: "c",
            severity: .high, action: .notify,
            reasoningPlain: "two", reasoningTechnical: "t"))

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace, flagStore: store)

        // Watch session s1.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s1", cwd: "/x", gitBranch: nil,
            projectHash: "h", jsonlPath: "/x", ts: Date())))
        let exp = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        let flags = vm.recentFlags()
        XCTAssertEqual(flags.map(\.id), ["f1"],
            "recentFlags must return only the watched session's flags")
    }

    // MARK: - Store-write re-render (RC fix #1)

    /// A store-write action must bump `storeRevision` so the panel's SwiftUI
    /// body re-invokes and re-reads the store (otherwise the Approve / flag
    /// actions show stale state).
    func testRespondToFlagBumpsStoreRevision() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "s1", projectHash: "h", cwd: "/x",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let store = FlagStore(database: db)
        try store.insert(StoredFlag(
            id: "flag1", sessionId: "s1", category: "c",
            severity: .high, action: .notify,
            reasoningPlain: "r", reasoningTechnical: "t"))

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace, flagStore: store)

        let before = vm.storeRevision
        vm.respondToFlag(flagId: "flag1", response: .dismissed)
        XCTAssertEqual(vm.storeRevision, before + 1,
            "a store write must bump storeRevision to force a re-render")
    }

    /// Approving a plan from the panel bumps the revision AND records the plan
    /// as optimistically approved (so the Approve button disables immediately,
    /// before the async handler round-trips through the store).
    func testApprovePlanBumpsRevisionAndMarksOptimistic() {
        let (vm, _) = makeVM()
        var handlerPlanId: String?
        vm.approvePlanHandler = { planId in handlerPlanId = planId }

        let before = vm.storeRevision
        vm.approvePlan(planId: "plan-1")

        XCTAssertEqual(vm.storeRevision, before + 1)
        XCTAssertTrue(vm.approvedPlanIds.contains("plan-1"),
            "the plan must be marked optimistically approved so Approve disables now")
        _ = handlerPlanId  // handler dispatch is async; the optimistic state is synchronous
    }

    /// With no handler wired, approvePlan is a no-op: it must NOT mark the plan
    /// optimistically approved or bump the revision (nothing was written).
    func testApprovePlanWithoutHandlerIsNoOp() {
        let (vm, _) = makeVM()
        let before = vm.storeRevision
        vm.approvePlan(planId: "plan-1")
        XCTAssertEqual(vm.storeRevision, before)
        XCTAssertFalse(vm.approvedPlanIds.contains("plan-1"))
    }

    // MARK: - Back-to-plan control (fix-item #4b cross-over)
    //
    // The status surface shows a "Back to plan" control ONLY when a plan exists
    // (so the cross-over to the plan surface is meaningful). With no plan the
    // status surface is unchanged. showsBackToPlanControl is the testable seam
    // for that rule, so we assert it without rendering layout.

    func testShowsBackToPlanControlFalseWithoutPlan() {
        let (vm, _) = makeVM()
        let panel = ExpandedPanelView(vm: vm)
        XCTAssertFalse(panel.showsBackToPlanControl)
    }

    func testShowsBackToPlanControlTrueWhenPlanExists() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "sess-1", projectHash: "h", cwd: "/Users/main/project",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
        let planStore = PlanStore(database: db)
        try planStore.create(Plan(
            id: "plan-1", sessionId: "sess-1", objective: "Ship auth.",
            steps: [PlanStep(
                id: "step-0", index: 0, title: "Step 0",
                objective: "Do step 0.", doneCriteria: "Done.",
                status: .active
            )],
            status: .running, currentStepIndex: 0
        ))

        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace, planStore: planStore)
        // Seed the watched session so currentPlan() resolves to plan-1.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "sess-1", cwd: "/Users/main/project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp = expectation(description: "session start processed")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        let panel = ExpandedPanelView(vm: vm)
        XCTAssertTrue(panel.showsBackToPlanControl)
    }

    // MARK: - Expanded panel visibility (guard fix)

    func testExpandedPanelShowsWhenHoverIsVisible() {
        // Create a real HoverWindowController with a visible hover panel.
        let (vm, _) = makeVM()
        let controller = HoverWindowController(
            vm: vm,
            isAnySessionActive: { true }
        )
        // Manually present the hover to make it visible.
        // In test environment, we order it front so panel.isVisible = true.
        controller.present()

        // Give the run loop a tick to process the present.
        let exp = expectation(description: "panel visible")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // Toggle expanded — should NOT early-return from the guard.
        vm.toggleExpanded()

        // Give Combine sink a tick to fire.
        let exp2 = expectation(description: "expanded toggled")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertTrue(vm.isExpanded, "isExpanded should be true after toggle")

        // Clean up.
        controller.dismiss()
    }
}
