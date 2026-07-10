// Planner.swift - v0.2.0 M2b. The Planner.
//
// The Dispatcher answers "what is the single next task for this idle
// session?" - one step at a time. The Planner answers a bigger question
// once, up front: "decompose this session's OBJECTIVE into an ordered,
// approval-gated plan of sprint-sized steps." That plan is the standing
// human gate (PLAN.md: approve-plan-then-auto-run): Supervisor surfaces it
// for a one-time approval, then the loop drives the steps.
//
// This is the engine, Stitch-independent, and it does NOT replace the
// Dispatcher - the Dispatcher remains the single-step fallback. Wiring the
// Planner into the live loop is M2d, not here.
//
// Design (mirrors Dispatcher.swift deliberately so the two read the same):
//   - `Planning` protocol mirrors `Dispatching` so the Planner is mockable.
//   - The SAME SessionContext, assembled by the SAME SessionContextBuilder
//     the Dispatcher uses (no duplicated fetch/read wiring).
//   - One forced-tool LLM call, `record_plan`, the same SHAPE as
//     record_dispatch: a single structured object, decoded by a static
//     parser. It returns 3-7 steps, each { title, objective, doneCriteria }.
//   - The SAME anti-fabrication backstops, now shared via ProposalBackstops
//     + the injected ProposalGrounding. A step that cannot be grounded is
//     DROPPED (the multi-step analogue of the Dispatcher degrading an
//     ungrounded proposal to low-confidence). If grounding drops everything,
//     the plan does not persist and the call returns .ungrounded.
//   - The produced plan persists via PlanStore with status=awaitingApproval
//     and every step pending.
//
// Model: defaults to the same model the Dispatcher uses
// (client.provider.defaultTriageModel) but is an init parameter so it can
// be tuned later WITHOUT touching the Dispatcher's model.

import Foundation

// MARK: - Result

/// Outcome of one Planner call.
public enum PlanResult: Sendable, Equatable {
    /// The Planner produced and PERSISTED a plan. The `Plan` is the
    /// awaiting-approval plan (status=awaitingApproval, steps pending) as it
    /// was written. Callers surface it for the one-time approval gate.
    case planned(Plan)
    /// The model returned a plan but EVERY step failed to ground (or it
    /// returned no usable steps at all), so nothing was persisted. `reasoning`
    /// surfaces why - the multi-step analogue of the Dispatcher's
    /// low-confidence idle. The loop falls back to the single-step Dispatcher.
    case ungrounded(reasoning: String)
    /// The Planner itself errored - network, parse failure, etc. Nothing
    /// persisted; the error string lands in the trace.
    case error(reasoning: String)
}

// MARK: - Planning protocol

/// Protocol for the engine-facing Planner surface. Concrete impl is
/// `Planner`; tests inject a mock that returns canned results. Mirrors
/// `Dispatching`.
public protocol Planning: Sendable {
    /// Assemble a SessionContext (fetches issues + commits internally, like
    /// the Dispatcher) and run the Planner call, persisting the result.
    /// Returns the structured `PlanResult`. Never throws.
    func planForSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent]
    ) async -> PlanResult

    /// Re-plan: given an EXISTING plan plus a fresh observation/verdict,
    /// produce updated REMAINING steps - keep every completed step verbatim,
    /// revise the rest. Persists a new plan (awaiting approval) and returns
    /// it. Not wired into any loop yet; implemented + unit-tested per M2b.
    func replan(
        existing: Plan,
        observation: String,
        cwd: String?
    ) async -> PlanResult
}

// MARK: - The Planner

public final class Planner: Planning, Sendable {

    private let client: LLMClient
    private let model: String
    private let store: PlanStore
    private let fallbackPrinciplesText: String
    private let principlesPath: URL?
    private let issueFetcher: (any IssueFetching)?
    private let commitFetcher: (any BranchCommitFetching)?
    private let dispatchHistory: (any DispatchHistoryReading)?
    private let grounder: (any ProposalGrounding)?
    private let trace: TraceLog

    /// Step-count clamp. 3..7, "prefer fewer coherent steps over a long
    /// mega-plan" (M2b spec). The cap is enforced after grounding so a
    /// fabricated 8th step that grounding would drop never costs us a real one.
    public static let minSteps = 3
    public static let maxSteps = 7

    /// `model` defaults to the Dispatcher's model
    /// (`client.provider.defaultTriageModel`) but is injectable so the
    /// Planner's model can be tuned later WITHOUT changing the Dispatcher.
    ///
    /// `principlesText` is the fallback PRINCIPLES.md body; if `principlesPath`
    /// is set, it is re-read on each call (cheap relative to the LLM call).
    /// `issueFetcher` / `commitFetcher` / `dispatchHistory` / `grounder` are
    /// optional, exactly as on the Dispatcher; nil yields empty context / no
    /// repo grounding.
    public init(
        client: LLMClient,
        store: PlanStore,
        principlesText: String,
        model: String? = nil,
        principlesPath: URL? = nil,
        issueFetcher: (any IssueFetching)? = nil,
        commitFetcher: (any BranchCommitFetching)? = nil,
        dispatchHistory: (any DispatchHistoryReading)? = nil,
        grounder: (any ProposalGrounding)? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.store = store
        self.model = model ?? client.provider.defaultTriageModel
        self.fallbackPrinciplesText = principlesText
        self.principlesPath = principlesPath
        self.issueFetcher = issueFetcher
        self.commitFetcher = commitFetcher
        self.dispatchHistory = dispatchHistory
        self.grounder = grounder
        self.trace = trace
    }

    /// Re-read PRINCIPLES.md from disk if a path is set, else the constructor
    /// text. Same pattern as the Dispatcher, including the stub guard: a
    /// re-read below the stub threshold (a stale near-empty bundle file)
    /// is rejected in favor of the constructor text.
    private var principlesText: String {
        guard let path = principlesPath,
              let fresh = try? String(contentsOf: path, encoding: .utf8),
              !fresh.isEmpty else {
            return fallbackPrinciplesText
        }
        if fresh.count < PrinciplesResolver.stubThreshold {
            trace.emit("plan", "PRINCIPLES re-read at \(path.path) is only \(fresh.count) chars (looks like a stub); using fallback text")
            return fallbackPrinciplesText
        }
        return fresh
    }

    // MARK: - Engine-facing entry point

    public func planForSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent]
    ) async -> PlanResult {
        let context = await SessionContextBuilder.build(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            issueFetcher: issueFetcher,
            commitFetcher: commitFetcher,
            dispatchHistory: dispatchHistory,
            trace: trace,
            traceTag: "plan"
        )
        return await plan(context: context)
    }

    /// Decompose the objective in `context` into an ordered plan, ground each
    /// step, and persist the survivors as an awaiting-approval plan. Returns a
    /// structured `PlanResult`; never throws - all errors land in
    /// `.error(reasoning:)` so the call cannot crash the engine.
    public func plan(context: SessionContext) async -> PlanResult {
        let req = AnthropicMessageRequest(
            model: model,
            max_tokens: 8192,
            system: Self.systemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.userMessage(
                    context: context,
                    principles: principlesText
                )))
            ],
            tools: [Self.recordPlanTool],
            tool_choice: .forced(Self.recordPlanToolName)
        )

        trace.emit("plan", "plan call started session=\(context.sessionUUID) model=\(model) issues=\(context.openIssues.count) commits=\(context.currentBranchCommits.count) turns=\(context.lastNTurns.count)")

        let resp: AnthropicMessageResponse
        do {
            resp = try await client.createMessage(req)
        } catch {
            trace.emit("plan", "ERROR plan call failed: \(error)")
            return .error(reasoning: "Plan call failed: \(error)")
        }

        trace.emit("plan", "plan returned model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens) stop_reason=\(resp.stop_reason ?? "(nil)")")

        guard let rawSteps = Self.parsePlanSteps(from: resp), !rawSteps.isEmpty else {
            let contentSummary = resp.content.map { "\($0.type):\($0.name ?? "-")" }.joined(separator: ", ")
            trace.emit("plan", "ERROR parse failed stop_reason=\(resp.stop_reason ?? "(nil)") content=[\(contentSummary)]")
            return .error(reasoning: "Planner did not return a parseable record_plan call. stop_reason=\(resp.stop_reason ?? "(nil)")")
        }

        // Objective for the plan: prefer the session objective; fall back to a
        // short label so the plan still has a through-line if no opening prompt
        // was captured.
        let objective = (context.objective?.isEmpty == false)
            ? context.objective!
            : "(objective not captured from transcript; planned from repo + backlog state)"

        let survivors = await groundedSteps(
            rawSteps, context: context, recent: context.recentDispatchProposals
        )
        guard !survivors.isEmpty else {
            trace.emit("plan", "UNGROUNDED all \(rawSteps.count) proposed steps dropped by backstops; not persisting")
            return .ungrounded(reasoning: "Every proposed step failed grounding (self-referential, stale, fabricated precondition, or cross-project). Idling the planner; the single-step Dispatcher remains the fallback.")
        }

        let plan = Self.assemble(
            sessionId: context.sessionUUID,
            objective: objective,
            steps: survivors
        )
        do {
            try store.create(plan)
        } catch {
            trace.emit("plan", "ERROR persist failed: \(error)")
            return .error(reasoning: "Plan produced but PlanStore.create failed: \(error)")
        }
        trace.emit("plan", "planned + persisted plan=\(plan.id) steps=\(plan.steps.count) status=\(plan.status.rawValue)")
        // v0.2.0 M4-prep: log the full step list (index, title, done-criteria) at
        // info level so the owner can REVIEW the plan in the trace before approving
        // it via the approve-plan marker - the loop is exercisable live before the
        // M3 approval UI exists. The notification "plan ready to approve" is fired
        // separately by the engine's createPlan -> notify path; this is the detail.
        Self.logPlanSteps(plan, trace: trace)
        return .planned(plan)
    }

    /// Emit one info-level trace line per step so the owner can read the proposed
    /// plan (and its rubrics) before approving. Called on a freshly created or
    /// re-planned plan. Plain text, no em dashes.
    static func logPlanSteps(_ plan: Plan, trace: TraceLog) {
        trace.emit("plan", "PLAN READY for approval: plan=\(plan.id) session=\(plan.sessionId) steps=\(plan.steps.count) objective=\"\(plan.objective.prefix(160))\"")
        for step in plan.steps {
            trace.emit("plan", "  step \(step.index + 1)/\(plan.steps.count): \(step.title) | done-criteria: \(step.doneCriteria.prefix(200))")
        }
    }

    // MARK: - Re-plan

    public func replan(
        existing: Plan,
        observation: String,
        cwd: String?
    ) async -> PlanResult {
        // Completed steps are carried VERBATIM - re-planning never re-does or
        // revises work already graded done. Everything else is open for revision.
        let completed = existing.steps.filter { $0.status == .passed }
        let remainingOld = existing.steps.filter { $0.status != .passed }

        let req = AnthropicMessageRequest(
            model: model,
            max_tokens: 8192,
            system: Self.replanSystemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.replanUserMessage(
                    existing: existing,
                    completed: completed,
                    remainingOld: remainingOld,
                    observation: observation,
                    principles: principlesText
                )))
            ],
            tools: [Self.recordPlanTool],
            tool_choice: .forced(Self.recordPlanToolName)
        )

        trace.emit("plan", "replan call started plan=\(existing.id) completed=\(completed.count) remaining=\(remainingOld.count) model=\(model)")

        let resp: AnthropicMessageResponse
        do {
            resp = try await client.createMessage(req)
        } catch {
            trace.emit("plan", "ERROR replan call failed: \(error)")
            return .error(reasoning: "Re-plan call failed: \(error)")
        }

        guard let rawSteps = Self.parsePlanSteps(from: resp), !rawSteps.isEmpty else {
            trace.emit("plan", "ERROR replan parse failed stop_reason=\(resp.stop_reason ?? "(nil)")")
            return .error(reasoning: "Re-plan did not return a parseable record_plan call. stop_reason=\(resp.stop_reason ?? "(nil)")")
        }

        // Ground only the NEW (revised remainder) steps; completed steps are
        // already-done facts and are not re-grounded.
        let context = SessionContext(
            sessionUUID: existing.sessionId,
            cwd: cwd,
            gitBranch: nil,
            lastNTurns: [],
            openIssues: [],
            currentBranchCommits: [],
            objective: existing.objective
        )
        let revisedRemainder = await groundedSteps(rawSteps, context: context, recent: [])
        guard !revisedRemainder.isEmpty else {
            trace.emit("plan", "UNGROUNDED replan: every revised step dropped; not persisting")
            return .ungrounded(reasoning: "Every revised remaining step failed grounding. Keeping the existing plan; idling the re-planner.")
        }

        // Stitch completed (verbatim) + revised remainder into a fresh ordered
        // plan, re-indexed from 0. Completed steps keep their status/verdict so
        // the new plan reflects real progress.
        var stitched: [PlanStep] = []
        var idx = 0
        for step in completed {
            var carried = step
            carried.index = idx
            stitched.append(carried)
            idx += 1
        }
        for spec in revisedRemainder {
            // Stop once we hit the cap counting completed + revised together.
            guard stitched.count < Self.maxSteps else { break }
            stitched.append(PlanStep(
                index: idx,
                title: spec.title,
                objective: spec.objective,
                doneCriteria: spec.doneCriteria,
                status: .pending
            ))
            idx += 1
        }

        let plan = Plan(
            sessionId: existing.sessionId,
            objective: existing.objective,
            steps: stitched,
            status: .awaitingApproval,
            currentStepIndex: completed.count
        )
        do {
            try store.create(plan)
        } catch {
            trace.emit("plan", "ERROR replan persist failed: \(error)")
            return .error(reasoning: "Re-plan produced but PlanStore.create failed: \(error)")
        }
        trace.emit("plan", "re-planned + persisted plan=\(plan.id) carried=\(completed.count) revised=\(stitched.count - completed.count)")
        Self.logPlanSteps(plan, trace: trace)
        return .planned(plan)
    }

    // MARK: - Grounding (shared backstops + repo grounding)

    /// One proposed step before it becomes a persisted PlanStep. Plain spec the
    /// model returns; grounding filters these, then `assemble` numbers them.
    struct StepSpec: Sendable, Equatable {
        let title: String
        let objective: String
        let doneCriteria: String
    }

    /// Run every proposed step through the SAME anti-fabrication backstops the
    /// Dispatcher applies to a single proposal, dropping the ones that fail.
    /// The grounding text for a step is its objective + doneCriteria (the
    /// concrete spec), with the title as the proposal "head" for staleness.
    /// Returns the survivors in order, capped at `maxSteps`.
    private func groundedSteps(
        _ steps: [StepSpec],
        context: SessionContext,
        recent: [String]
    ) async -> [StepSpec] {
        var survivors: [StepSpec] = []
        for step in steps {
            guard survivors.count < Self.maxSteps else { break }
            let proposal = step.objective
            let justification = step.doneCriteria

            // Premise: a step that builds/wires already-existing machinery.
            if let reject = ProposalBackstops.premiseRejection(proposal: proposal, justification: justification) {
                trace.emit("plan", "DROP step \"\(step.title.prefix(48))\" PREMISE \(reject)")
                continue
            }
            // Staleness: a step that near-verbatim repeats recent dispatched work.
            if let stale = ProposalBackstops.stalenessRejection(proposal: step.title + " " + proposal, against: recent) {
                trace.emit("plan", "DROP step \"\(step.title.prefix(48))\" STALE \(stale)")
                continue
            }
            // Env-claim: a step justified by a fabricated unblocking precondition.
            if let envReject = ProposalBackstops.environmentClaimRejection(proposal: proposal, justification: justification) {
                trace.emit("plan", "DROP step \"\(step.title.prefix(48))\" ENV_CLAIM \(envReject)")
                continue
            }
            // Cross-project + deploy-state grounding (async, repo-backed), the
            // SAME ProposalGrounding the Dispatcher injects. A step that names
            // code or commits absent from THIS session's repo is dropped.
            if let grounder, let cwd = context.cwd, !cwd.isEmpty {
                let missing = await grounder.missingSymbols(inProposal: proposal, cwd: cwd)
                if !missing.isEmpty {
                    let head = missing.prefix(5).joined(separator: ",")
                    trace.emit("plan", "DROP step \"\(step.title.prefix(48))\" CROSS_PROJECT missing=\(head)")
                    continue
                }
                let badCommits = await grounder.missingCommits(inText: proposal + " " + justification, cwd: cwd)
                if !badCommits.isEmpty {
                    let head = badCommits.prefix(5).joined(separator: ",")
                    trace.emit("plan", "DROP step \"\(step.title.prefix(48))\" DEPLOY_STATE missing_commits=\(head)")
                    continue
                }
            }
            survivors.append(step)
        }
        return survivors
    }

    /// Build the awaiting-approval Plan from the grounded step specs: status
    /// awaitingApproval, every step pending, indices 0-based and contiguous.
    static func assemble(sessionId: String, objective: String, steps: [StepSpec]) -> Plan {
        let planSteps = steps.enumerated().map { idx, spec in
            PlanStep(
                index: idx,
                title: spec.title,
                objective: spec.objective,
                doneCriteria: spec.doneCriteria,
                status: .pending
            )
        }
        return Plan(
            sessionId: sessionId,
            objective: objective,
            steps: planSteps,
            status: .awaitingApproval,
            currentStepIndex: 0
        )
    }

    // MARK: - Prompts

    static let systemPrompt: String = """
    You are Supervisor's Planner. A user opened an autonomous Claude Code
    session with an OBJECTIVE (their opening ask). Your job is to decompose
    that objective into an ordered, sprint-sized PLAN that the loop will drive:
    each step is injected into Claude Code as a concrete spec, Claude works it,
    and an Evaluator grades the real output against the step's done-criteria
    before the loop advances.

    The plan you produce is surfaced to the human ONCE for approval, then the
    loop auto-runs it. So it must be COHERENT and GROUNDED, not aspirational.

    Rules:
      - Produce 3 to 7 steps. PREFER FEWER, coherent steps over a long
        mega-plan. If the objective is small, 3 focused steps is correct; do
        not pad to 7. Never exceed 7.
      - ORDER matters: each step should build on the ones before it. Step 1 is
        the first thing you would actually do; the last step finishes the
        objective.
      - Each step is SPRINT-SIZED: roughly one focused work session - a unit a
        senior engineer would pick up, do, and verify in one sitting. Not a
        single line of code; not a multi-week epic.
      - GROUND every step in the REAL state you are given (the objective, the
        repo, recent commits, Known Gaps, open issues, PRINCIPLES.md). Do NOT
        invent components, files, or commits. Do NOT propose building or wiring
        machinery that already exists - that is the cardinal failure. If you
        are not sure a thing exists, write the step as "verify X, then ..."
        rather than asserting it.
      - Do NOT propose work the transcript shows is already done.

    For EACH step provide three fields:
      - title:        a short human label (a few words) shown in the plan view.
      - objective:    the concrete spec injected into Claude Code - what to
                      build, in specific, actionable terms. Written like a
                      senior collaborator giving direction, grounded in the
                      named real state.
      - done_criteria: the rubric the Evaluator grades the observed output
                      against. Concrete and checkable ("the new test passes and
                      `swift build` is green"), not vague ("works well").

    Call `record_plan` exactly once with the ordered steps.
    """

    static let replanSystemPrompt: String = """
    You are Supervisor's Planner, RE-PLANNING an in-flight plan. The plan has
    completed some steps (graded done) and hit a new observation - a verdict, a
    blocker, or new information - that changes what remains.

    Your job: produce the UPDATED REMAINING steps. The completed steps are
    DONE and are carried forward unchanged by the system - do NOT re-issue
    them, do NOT re-do them. Revise only the not-yet-done remainder in light of
    the observation: drop steps the observation makes unnecessary, add steps it
    reveals are needed, reorder so the plan still finishes the objective.

    Same step rules as a fresh plan: ground every step in real state, no
    inventing components/files/commits, no proposing already-existing
    machinery, sprint-sized, concrete done-criteria. Return ONLY the revised
    remaining steps (the system prepends the completed ones); keep the TOTAL
    plan at 7 steps or fewer counting the completed ones.

    For each remaining step provide title, objective, and done_criteria, same
    as a fresh plan. Call `record_plan` exactly once.
    """

    /// User message for a fresh plan. Reuses the Dispatcher's context sections
    /// verbatim (objective, direction, commits, Known Gaps, issues, last turns,
    /// PRINCIPLES) so the Planner sees the SAME grounded picture, then asks for
    /// a decomposition instead of a single next task.
    static func userMessage(context: SessionContext, principles: String) -> String {
        var lines: [String] = []

        lines.append("# Session context")
        lines.append("session: \(context.sessionUUID)")
        lines.append("cwd: \(context.cwd ?? "(unknown)")")
        lines.append("branch: \(context.gitBranch ?? "(unknown)")")
        lines.append("")

        lines.append("# SESSION OBJECTIVE (the user's opening ask - decompose THIS into the plan)")
        lines.append("")
        if let objective = context.objective, !objective.isEmpty {
            lines.append(objective)
            lines.append("")
            lines.append("Decompose THIS objective into an ordered, sprint-sized plan. Every step must move toward this objective and be grounded in the real state below. If the work the objective describes is already built and verified per the recent turns, return the SMALLEST honest plan (a single verification step) rather than inventing follow-on scope.")
        } else {
            lines.append("(no opening prompt captured - plan from PRODUCT-DIRECTION.md, Known Gaps, the backlog, and recent work below)")
        }
        lines.append("")

        lines.append("# PRODUCT-DIRECTION.md (where the project is going)")
        lines.append("")
        lines.append(context.productDirection.isEmpty
            ? "(not found - reason from PRINCIPLES.md and recent work instead)"
            : context.productDirection)
        lines.append("")

        lines.append("# Recent commits on this branch (since divergence from main)")
        if context.currentBranchCommits.isEmpty {
            lines.append("(none - fresh branch or git fetch failed)")
        } else {
            for c in context.currentBranchCommits {
                lines.append("- \(c.sha.prefix(8)) \(c.subject)")
                if !c.body.isEmpty {
                    for line in c.body.split(separator: "\n") {
                        lines.append("  \(line)")
                    }
                }
            }
        }
        lines.append("")

        lines.append("# Recent files changed on this branch (git diff --stat main..HEAD)")
        if context.recentFilesChanged.isEmpty {
            lines.append("(none - fresh branch or git diff failed)")
        } else {
            for fl in context.recentFilesChanged { lines.append(fl) }
        }
        lines.append("")

        lines.append("# Known Gaps (unfinished, unticketed, or blocked work)")
        lines.append("")
        lines.append(context.knownGaps.isEmpty
            ? "(no Known Gaps section found in trial-notes.md)"
            : context.knownGaps)
        lines.append("")

        lines.append("# Open GitHub issues")
        if context.openIssues.isEmpty {
            lines.append("(empty - check Known Gaps and source markers for real remaining work)")
        } else {
            for i in context.openIssues {
                let labelTag = i.labels.isEmpty ? "" : " [\(i.labels.joined(separator: ", "))]"
                lines.append("## Issue #\(i.number) - \(i.title)\(labelTag)")
                if !i.body.isEmpty { lines.append(String(i.body.prefix(600))) }
                lines.append("")
            }
        }

        lines.append("# Source markers (TODO/FIXME in recently-touched files)")
        if context.sourceMarkers.isEmpty {
            lines.append("(none found)")
        } else {
            for m in context.sourceMarkers { lines.append(m) }
        }
        lines.append("")

        lines.append("# Session's last turns (what the worker just did - 'the screen')")
        if context.lastNTurns.isEmpty {
            lines.append("(no events in window)")
        } else {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for event in context.lastNTurns.suffix(10) {
                lines.append(turnLine(event, ts: fmt.string(from: event.timestamp)))
            }
        }
        lines.append("")

        lines.append("# PRINCIPLES.md (the project's operating manual)")
        lines.append("")
        lines.append(principles)
        lines.append("")

        lines.append("# Task")
        lines.append("Call `record_plan` exactly once. Decompose the objective into 3-7 ordered, sprint-sized steps, each grounded in the real state above. Prefer fewer coherent steps. Each step's `objective` IS the prompt that will be typed into Claude Code - write it as specific, actionable direction.")

        return lines.joined(separator: "\n")
    }

    /// User message for a re-plan: the existing plan's completed + remaining
    /// steps plus the new observation that triggered the re-plan.
    static func replanUserMessage(
        existing: Plan,
        completed: [PlanStep],
        remainingOld: [PlanStep],
        observation: String,
        principles: String
    ) -> String {
        var lines: [String] = []

        lines.append("# Objective (unchanged)")
        lines.append("")
        lines.append(existing.objective)
        lines.append("")

        lines.append("# Completed steps (DONE - carried forward by the system, do NOT re-issue)")
        if completed.isEmpty {
            lines.append("(none completed yet)")
        } else {
            for s in completed {
                lines.append("- [done] \(s.title): \(s.objective.prefix(160))")
            }
        }
        lines.append("")

        lines.append("# Remaining steps BEFORE this re-plan (revise these)")
        if remainingOld.isEmpty {
            lines.append("(none - the plan had no remaining steps)")
        } else {
            for s in remainingOld {
                lines.append("- [\(s.status.rawValue)] \(s.title): \(s.objective.prefix(160))")
            }
        }
        lines.append("")

        lines.append("# New observation that triggered the re-plan")
        lines.append("")
        lines.append(observation.isEmpty ? "(no observation text provided)" : observation)
        lines.append("")

        lines.append("# PRINCIPLES.md (the project's operating manual)")
        lines.append("")
        lines.append(principles)
        lines.append("")

        lines.append("# Task")
        lines.append("Call `record_plan` exactly once with the UPDATED REMAINING steps only (the system prepends the completed ones). Revise the remainder in light of the observation; keep the total plan at 7 steps or fewer.")

        return lines.joined(separator: "\n")
    }

    /// Compact one-liner for a single event. Mirrors Dispatcher.turnLine.
    private static func turnLine(_ event: SupervisorEvent, ts: String) -> String {
        switch event {
        case .sessionStart(let i):
            return "[\(ts)] sessionStart branch=\(i.gitBranch ?? "?")"
        case .userPrompt(let i):
            return "[\(ts)] userPrompt: \(i.text.prefix(240))"
        case .assistantText(let i):
            return "[\(ts)] assistantText: \(i.text.prefix(240))"
        case .bashToolCall(let i):
            return "[\(ts)] bashToolCall: \(i.command.prefix(200))"
        case .bashToolResult(let i):
            return "[\(ts)] bashToolResult error=\(i.isError) bytes=\(i.output.utf8.count)"
        case .fileEdit(let i):
            return "[\(ts)] fileEdit \(i.toolName) \(i.filePath) (\(i.hunks.count) change(s))"
        case .systemSignal(let i):
            return "[\(ts)] systemSignal \(i.subtype)"
        }
    }

    // MARK: - Tool schema

    static let recordPlanToolName = "record_plan"

    /// `record_plan` - forced tool call shape, same SHAPE as record_dispatch:
    /// one structured object. The object holds an ordered `steps` array, each
    /// step an object of { title, objective, done_criteria }.
    static var recordPlanTool: AnthropicTool {
        AnthropicTool(
            name: recordPlanToolName,
            description: "Record the decomposed plan: an ordered list of 3 to 7 sprint-sized steps for the session objective.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "steps": .object([
                        "type": .string("array"),
                        "description": .string("3 to 7 ordered steps. Index 0 is done first. Prefer fewer coherent steps; never exceed 7."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "description": .string("Short human label for the step (a few words), shown in the plan view.")
                                ]),
                                "objective": .object([
                                    "type": .string("string"),
                                    "description": .string("The concrete spec injected into Claude Code - what to build, in specific actionable terms. Written like a senior collaborator giving direction, grounded in real named state.")
                                ]),
                                "done_criteria": .object([
                                    "type": .string("string"),
                                    "description": .string("The rubric the Evaluator grades the observed output against. Concrete and checkable, not vague.")
                                ]),
                            ]),
                            "required": .array([
                                .string("title"), .string("objective"), .string("done_criteria")
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("steps")])
            ])
        )
    }

    // MARK: - Parser

    /// Decode the record_plan tool call into ordered StepSpecs. Returns nil if
    /// the response carries no usable record_plan call; skips individual steps
    /// missing a required field rather than failing the whole plan.
    static func parsePlanSteps(from response: AnthropicMessageResponse) -> [StepSpec]? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == recordPlanToolName,
                  case let .object(input)? = block.input,
                  case let .array(items)? = input["steps"]
            else { continue }

            var specs: [StepSpec] = []
            for item in items {
                guard case let .object(fields) = item,
                      case let .string(title)? = fields["title"],
                      case let .string(objective)? = fields["objective"],
                      case let .string(done)? = fields["done_criteria"]
                else { continue }
                let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let o = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                let d = done.trimmingCharacters(in: .whitespacesAndNewlines)
                // A step needs at least an objective to be a real step.
                guard !o.isEmpty else { continue }
                specs.append(StepSpec(
                    title: t.isEmpty ? String(o.prefix(48)) : t,
                    objective: o,
                    doneCriteria: d
                ))
            }
            return specs
        }
        return nil
    }
}
