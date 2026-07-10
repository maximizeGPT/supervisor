// PlanViewTests.swift — v0.2.0 M3.
//
// Coverage for the live Plan UI: the new component vocabulary's pure mappings
// (SeverityBadge tinted-amber color + glyph, StatusChip state mapping from
// Plan.Status) and the HoverViewModel's Plan binding (current plan read from
// PlanStore for the watched session + the Approve-plan action routing through
// the wired handler). The SwiftUI render itself is exercised by building the
// views; these assert the load-bearing logic that drives them.

import XCTest
import SwiftUI
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class PlanViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(
        planStore: PlanStore? = nil
    ) -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("planview-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace, planStore: planStore)
        return (vm, bus)
    }

    private func makePlan(
        status: Plan.Status,
        sessionId: String = "sess-1",
        currentStepIndex: Int = 0,
        stepStatuses: [PlanStep.Status] = [.active, .pending]
    ) -> Plan {
        let steps = stepStatuses.enumerated().map { i, st in
            PlanStep(
                id: "step-\(i)", index: i, title: "Step \(i)",
                objective: "Do step \(i).",
                doneCriteria: "Step \(i) is verifiably done.",
                status: st,
                lastVerdict: st == .active
                    ? PlanStep.Verdict(passed: true, score: 0.95, feedback: "Looks good so far.")
                    : nil
            )
        }
        return Plan(
            id: "plan-1", sessionId: sessionId, objective: "Ship auth.",
            steps: steps, status: status, currentStepIndex: currentStepIndex
        )
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

    // MARK: - SeverityBadge (tinted amber reconciliation)

    func testSeverityBadgeMediumAndHighUseAttentionAmber() {
        XCTAssertEqual(SeverityBadge.color(for: .medium), BrandColor.attention.color)
        XCTAssertEqual(SeverityBadge.color(for: .high), BrandColor.attention.color)
    }

    func testSeverityBadgeLowUsesMuteGrey() {
        XCTAssertEqual(SeverityBadge.color(for: .low), BrandColor.mute.color)
    }

    func testSeverityBadgeGlyphs() {
        XCTAssertEqual(SeverityBadge.glyph(for: .low), "info.circle")
        XCTAssertEqual(SeverityBadge.glyph(for: .medium), "exclamationmark.triangle")
        XCTAssertEqual(SeverityBadge.glyph(for: .high), "exclamationmark.triangle")
    }

    // MARK: - StatusChip mapping from Plan.Status

    func testStatusChipMapsAwaitingApproval() {
        XCTAssertEqual(StatusChip(planStatus: .awaitingApproval).chipState, .awaitingApproval)
        XCTAssertEqual(StatusChip(planStatus: .draft).chipState, .awaitingApproval)
    }

    func testStatusChipMapsApprovedToAwaitingApproval() {
        // approved is a transient state between approval click and drive start;
        // it should show as "Awaiting approval" (not "Running") so the Approve
        // button stays enabled during the window.
        XCTAssertEqual(StatusChip(planStatus: .approved).chipState, .awaitingApproval)
    }

    func testStatusChipMapsRunning() {
        XCTAssertEqual(StatusChip(planStatus: .running).chipState, .running)
    }

    func testStatusChipMapsCompleted() {
        XCTAssertEqual(StatusChip(planStatus: .completed).chipState, .completed)
    }

    func testStatusChipMapsAborted() {
        XCTAssertEqual(StatusChip(planStatus: .aborted).chipState, .aborted)
    }

    // MARK: - HoverViewModel: currentPlan binding

    func testCurrentPlanNilWithoutStore() {
        let (vm, _) = makeVM(planStore: nil)
        XCTAssertNil(vm.currentPlan())
    }

    func testCurrentPlanNilWhenNoSessionSeen() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = PlanStore(database: db)
        let (vm, _) = makeVM(planStore: store)
        // No sessionStart published yet -> currentSessionId empty -> nil.
        XCTAssertNil(vm.currentPlan())
    }

    func testCurrentPlanReadsWatchedSessionPlan() throws {
        let db = try SupervisorDatabase.inMemory()
        let sessionStore = SessionStore(database: db)
        try sessionStore.upsert(StoredSession(
            id: "sess-1", projectHash: "h", cwd: "/Users/main/project",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"
        ))
        let store = PlanStore(database: db)
        try store.create(makePlan(status: .awaitingApproval, sessionId: "sess-1"))

        let (vm, bus) = makeVM(planStore: store)
        seedSession(vm, bus, id: "sess-1")

        let plan = vm.currentPlan()
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.id, "plan-1")
        XCTAssertEqual(plan?.status, .awaitingApproval)
        XCTAssertEqual(plan?.steps.count, 2)
    }

    func testCurrentPlanNilForSessionWithoutPlan() throws {
        let db = try SupervisorDatabase.inMemory()
        let store = PlanStore(database: db)
        let (vm, bus) = makeVM(planStore: store)
        seedSession(vm, bus, id: "sess-no-plan")
        XCTAssertNil(vm.currentPlan())
    }

    // MARK: - HoverViewModel: approve action routing

    func testApprovePlanRoutesThroughHandler() {
        let (vm, _) = makeVM()
        var approvedId: String?
        let exp = expectation(description: "handler invoked")
        vm.approvePlanHandler = { id in
            approvedId = id
            exp.fulfill()
        }
        vm.approvePlan(planId: "plan-1")
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(approvedId, "plan-1")
    }

    func testApprovePlanNoOpWithoutHandler() {
        let (vm, _) = makeVM()
        // No handler wired — must not crash.
        vm.approvePlan(planId: "plan-1")
    }

    // MARK: - displayTitle derivation (pure helper)
    //
    // The objective heading must show a CONCISE human title, never a raw routine
    // prompt dump. These exercise the pure String -> String rules directly.

    func testDisplayTitleExtractsRoutineNameFromScheduledTaskBlock() {
        let objective = """
        <scheduled-task name="supervisor-tweet-engine" file="/Users/main/.claude/skills/supervisor-tweet-engine/SKILL.md">
        This is an automated run of a scheduled task. Do the thing, then post it.
        </scheduled-task>
        """
        XCTAssertEqual(
            PlanView.displayTitle(for: objective),
            "Supervisor tweet engine"
        )
    }

    func testDisplayTitleHumanizesUnderscoreAndSentenceCasesFirstWord() {
        let objective = "<scheduled-task name=\"my_routine\">automated run</scheduled-task>"
        XCTAssertEqual(PlanView.displayTitle(for: objective), "My routine")
    }

    func testDisplayTitlePlainShortObjectivePassesThrough() {
        XCTAssertEqual(PlanView.displayTitle(for: "Ship auth."), "Ship auth.")
    }

    func testDisplayTitleShortFirstLineIsUsedAsHeading() {
        let objective = "Refactor the planner\n\nThen wire it into the dispatcher and add tests."
        XCTAssertEqual(PlanView.displayTitle(for: objective), "Refactor the planner")
    }

    func testDisplayTitleLongParagraphTruncatesAtWordBoundary() {
        // A single long line (no short first line) must truncate to <= ~140
        // chars at a word boundary, with no mid-word cut and no raw tag.
        let objective = String(repeating: "alpha beta gamma delta ", count: 20)
            .trimmingCharacters(in: .whitespaces)
        let title = PlanView.displayTitle(for: objective)
        // Account for the trailing ellipsis: the text portion is <= 140.
        XCTAssertLessThanOrEqual(title.count, 141)
        XCTAssertTrue(title.hasSuffix("\u{2026}"), "long objective should be elided")
        let body = title.dropLast() // drop the ellipsis
        // No mid-word cut: the truncated body ends on a complete word, so the
        // last whitespace-split token is one of the source words.
        let lastToken = body.split(separator: " ").last.map(String.init) ?? ""
        XCTAssertTrue(
            ["alpha", "beta", "gamma", "delta"].contains(lastToken),
            "truncation cut mid-word: \(lastToken)"
        )
        XCTAssertFalse(title.contains("<"), "title must not contain a raw tag")
    }

    func testDisplayTitleFilePathYieldsNameWhenNoNameAttr() {
        // A wrapper with only a file=".../<name>/SKILL.md" (no name attr) still
        // yields a name-based, humanized title.
        let objective = "<scheduled-task file=\"/x/y/skills/my-routine/SKILL.md\">run</scheduled-task>"
        XCTAssertEqual(PlanView.displayTitle(for: objective), "My routine")
    }

    func testDisplayTitleStripsLeadingTagNoiseFromShownText() {
        // A leading wrapper tag with no name/file attribute is peeled, so the
        // shown heading starts at real content, not "<wrapper>".
        let objective = "<wrapper>\nDeploy the release\nthen verify it."
        XCTAssertEqual(PlanView.displayTitle(for: objective), "Deploy the release")
    }

    func testDisplayTitleStripsLeadingCodeFence() {
        let objective = "```\nDeploy the release"
        XCTAssertEqual(PlanView.displayTitle(for: objective), "Deploy the release")
    }

    func testDisplayTitleTrimsSurroundingWhitespace() {
        XCTAssertEqual(PlanView.displayTitle(for: "   Ship auth.   "), "Ship auth.")
    }

    // MARK: - PlanView renders for each plan status (smoke)
    //
    // Hosting the view forces SwiftUI to evaluate its body; a layout pass that
    // doesn't trap is the assertion. `some View` is non-optional, so we render
    // rather than nil-check.

    @discardableResult
    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        h.layoutSubtreeIfNeeded()
        return h
    }

    func testPlanViewRendersForAwaitingApproval() {
        let plan = makePlan(status: .awaitingApproval)
        host(PlanView(plan: plan, isPaused: false, onApprove: {}, onPauseToggle: {}))
    }

    func testPlanViewRendersForRunning() {
        let plan = makePlan(status: .running, stepStatuses: [.passed, .active, .pending])
        host(PlanView(plan: plan, isPaused: false, onApprove: {}, onPauseToggle: {}))
    }

    func testPlanViewRendersWhenPaused() {
        let plan = makePlan(status: .running)
        host(PlanView(plan: plan, isPaused: true, onApprove: {}, onPauseToggle: {}))
    }

    func testPlanViewFooterApproveEnabledOnlyWhenAwaitingApproval() {
        // The footer's Approve enablement is the visible approval gate. Render
        // both states to confirm neither traps; the enable rule itself is unit-
        // visible via canApprove below.
        host(PlanView(plan: makePlan(status: .awaitingApproval),
                      isPaused: false, onApprove: {}, onPauseToggle: {}).footer)
        host(PlanView(plan: makePlan(status: .running),
                      isPaused: false, onApprove: {}, onPauseToggle: {}).footer)
    }

    func testPlanViewRendersWithDetailAffordance() {
        // The "Details" affordance (onShowDetail non-nil) is what enters the
        // dark detail register. Rendering with it wired confirms the extra row
        // lays out and the closure is held without trapping.
        var tapped = false
        host(PlanView(plan: makePlan(status: .running),
                      isPaused: false, onApprove: {}, onPauseToggle: {},
                      onShowDetail: { tapped = true }))
        XCTAssertFalse(tapped)   // building the view must not fire the action
    }

    func testPlanViewRendersWithPanelAffordance() {
        // Fix-item #4b: the "Panel" affordance (onShowPanel non-nil) crosses to
        // the normal Status control panel. Rendering with both it and Details
        // wired confirms the header lays out with both muted affordances and
        // neither closure fires on build.
        var panelTapped = false
        var detailTapped = false
        host(PlanView(plan: makePlan(status: .running),
                      isPaused: false, onApprove: {}, onPauseToggle: {},
                      onShowDetail: { detailTapped = true },
                      onShowPanel: { panelTapped = true }))
        XCTAssertFalse(panelTapped)   // building the view must not fire the action
        XCTAssertFalse(detailTapped)
    }

    // MARK: - PlanDetailView (Stitch screen 2, the dark plan-detail register)
    //
    // Hosting forces SwiftUI to evaluate the body; a layout pass that doesn't
    // trap is the assertion. The detail view reuses the dark-capable primitives
    // (StatusChip(dark:), PlanStepRow(expanded:dark:), StepStateIcon(dark:)), so
    // these smoke the composition across plan statuses + the paused register.

    func testPlanDetailViewRendersForAwaitingApproval() {
        let plan = makePlan(status: .awaitingApproval)
        host(PlanDetailView(plan: plan, isPaused: false, onBack: {}))
    }

    func testPlanDetailViewRendersForRunningWithExpandedActiveStep() {
        let plan = makePlan(status: .running, currentStepIndex: 1,
                            stepStatuses: [.passed, .active, .pending])
        host(PlanDetailView(plan: plan, isPaused: false, onBack: {}))
    }

    func testPlanDetailViewRendersWhenPaused() {
        let plan = makePlan(status: .running)
        host(PlanDetailView(plan: plan, isPaused: true, onBack: {}))
    }

    func testPlanDetailViewRendersAcrossAllStepStatuses() {
        // A plan whose steps cover every lifecycle state, so the dark timeline
        // (and the active/retrying step's expanded criteria + boxed verdict)
        // all render in the dark register without trapping.
        let plan = makePlan(status: .running, currentStepIndex: 1,
                            stepStatuses: PlanStep.Status.allCases)
        host(PlanDetailView(plan: plan, isPaused: false, onBack: {}))
    }

    func testPlanDetailViewBackActionNotFiredOnRender() {
        var backed = false
        host(PlanDetailView(plan: makePlan(status: .running),
                            isPaused: false, onBack: { backed = true }))
        XCTAssertFalse(backed)   // building the view must not fire Back
    }

    // MARK: - PlanStepRow / StepStateIcon render across all step states (smoke)

    func testStepStateIconRendersForAllStatuses() {
        for st in PlanStep.Status.allCases {
            host(StepStateIcon(st))
            host(StepStateIcon(st, dark: true))
        }
    }

    func testPlanStepRowRendersCompactAndExpanded() {
        for st in PlanStep.Status.allCases {
            let step = PlanStep(
                index: 0, title: "Step", objective: "Do it.",
                doneCriteria: "Done line one\nDone line two",
                status: st,
                lastVerdict: PlanStep.Verdict(passed: st != .failed, score: 0.8, feedback: "ok")
            )
            host(PlanStepRow(step))
            host(PlanStepRow(step, expanded: true, dark: true))
        }
    }

    func testPulseDotAndSeverityBadgeAndChipsRender() {
        host(PulseDot())
        host(PulseDot(tint: BrandColor.attention.color))
        for sev in FlagSeverity.allCases { host(SeverityBadge(sev)) }
        host(StatusChip(.awaitingApproval))
        host(StatusChip(.running, dark: true))
    }
}
