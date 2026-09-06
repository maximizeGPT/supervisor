// Dispatcher.swift — v0.4.0 Part B.
//
// Second-stage call for the worker_idle_post_completion flag.
//
// The primary triage call (record_triage in TriagePrompt.swift) decides
// WHETHER the worker is idle on an autonomous branch — a yes/no question
// the rubric body answers from a small context window. The Dispatcher
// answers the next question: now that we know the worker is idle, what
// task should it pick up next, and what prompt do we type into Claude
// Code's input to start it?
//
// That second question needs a much larger context than the triage
// rubric: PRINCIPLES.md (~28k chars), the session's last 10 turns,
// the current branch's commits, the open GitHub issue queue. So the
// design is two separate Haiku calls — keeps the triage rubric small
// and stateless, lets the Dispatcher carry the dispatch-shaped
// context. Same factoring as QuestionAnswerer's split from the
// primary triage call in v0.3.0.
//
// The Dispatcher's voice and constraints:
//
//   - It picks from documented work (open issues, mechanical
//     follow-on from recent commits). It does NOT invent feature
//     scope per §1d "file an issue, don't build the feature now."
//   - It returns confidence based on how clear the next task is,
//     not how plausible. PRINCIPLES §3a: write the asymmetry note
//     in the justification.
//   - It writes the next_task_proposal grounded in THIS session's
//     actual recent state: the worker's last messages and output,
//     the files/commits/errors in play, and the concrete next step
//     that follows. The proposal IS the prompt that gets injected,
//     so it reads like a senior collaborator who just read the
//     conversation, not generic boilerplate addressed to a user.
//
// Cost envelope (PRINCIPLES §9e): one dispatch is ~4-6k input + ~500
// output tokens against Haiku 4.5 → ~$0.005-0.008 per fire. With the
// idleReTriageIntervalSeconds=60s gate from Part A, even a continuously
// idle session caps at one dispatch/minute = $0.30/hr. Well under the
// $0.50 autonomous envelope.

import Foundation

// MARK: - Result types

/// Outcome of one Dispatcher call. The router branches on this:
/// `.ready` with confidence=.high triggers an inject; confidence=.medium
/// triggers a propose-and-wait banner; `.lowConfidence` triggers a
/// surface-the-idle-state banner; `.error` degrades to notify with the
/// underlying error as the trace reason.
public enum DispatchResult: Sendable, Equatable {
    /// The Dispatcher picked a task. `prompt` is the body to inject;
    /// `justification` lands in the trace + the asymmetry note;
    /// `confidence` decides whether to inject (.high) or surface
    /// (.medium). The router never injects on .medium — the spec's
    /// "propose and wait" path from Part A.
    ///
    /// `priorDispatchesEchoed` carries Haiku's read of the
    /// `prior_dispatches_considered` input — useful for the trace
    /// post-mortem to confirm Haiku saw the loop-state signal. nil
    /// when Haiku didn't echo it back (likely when Part C hasn't
    /// instrumented the engine yet).
    case ready(
        prompt: String,
        justification: String,
        confidence: DispatchConfidence,
        selectedPath: SelectedPath,
        selectedIssueNumber: Int?,
        priorDispatchesEchoed: Int?,
        requiresHumanPresence: Bool
    )
    /// The Dispatcher saw the idle state but couldn't pick a task
    /// with enough confidence to dispatch OR propose. `reasoning`
    /// surfaces in the banner so the user knows WHY supervisor went
    /// quiet rather than just hanging.
    case lowConfidence(reasoning: String)
    /// The Dispatcher itself errored — network, parse failure, etc.
    /// The router degrades to a plain notify; the error string lands
    /// in the trace.
    case error(reasoning: String)
    /// The session objective is complete. The loop stops cleanly (success) —
    /// the engine ends the loop on this rather than waiting for the
    /// 3-consecutive-low backstop. `summary` is the model's one-line account of
    /// what was built, for the trace + the "done" banner.
    case objectiveComplete(summary: String)

    public static func == (lhs: DispatchResult, rhs: DispatchResult) -> Bool {
        switch (lhs, rhs) {
        case let (.ready(p1, j1, c1, sp1, n1, e1, h1), .ready(p2, j2, c2, sp2, n2, e2, h2)):
            return p1 == p2 && j1 == j2 && c1 == c2 && sp1 == sp2 && n1 == n2 && e1 == e2 && h1 == h2
        case let (.lowConfidence(r1), .lowConfidence(r2)):
            return r1 == r2
        case let (.error(r1), .error(r2)):
            return r1 == r2
        case let (.objectiveComplete(s1), .objectiveComplete(s2)):
            return s1 == s2
        default:
            return false
        }
    }
}

public enum DispatchConfidence: String, Sendable, Equatable {
    case high
    case medium
    case low
}

/// Which of the two dispatch paths the Dispatcher picked (per spec B3).
/// `continue_branch` = mechanical follow-on from the current branch
/// (missing tests for new code, missing CHANGELOG, etc.).
/// `transition_to_issue` = jump to a sized issue from the queue.
/// `low_confidence_no_action` = no clear next task; surface to user.
public enum SelectedPath: String, Sendable, Equatable {
    case continueBranch = "continue_branch"
    case transitionToIssue = "transition_to_issue"
    case lowConfidenceNoAction = "low_confidence_no_action"
    /// The session objective is already met by the work so far — the loop should
    /// stop (success), not pick another task. Distinct from
    /// low_confidence_no_action ("couldn't pick") — this is "nothing left to
    /// pick, the thing is built." (Swift dispatcher only; the Python hook's
    /// schema doesn't include it, so it never emits it.)
    case objectiveComplete = "objective_complete"
}

// MARK: - Session context

/// The bundle the Dispatcher needs to make its call. The TriageEngine
/// assembles this at idle-flag time and hands it to the Dispatcher; the
/// Dispatcher is pure with respect to the bundle.
/// Read-only access to the recent `next_task_proposal` heads the dispatcher
/// already produced for a session. Injected into the Dispatcher so it can see
/// — and not re-propose — work it dispatched earlier this run. Without this the
/// dispatcher is amnesiac: it re-reads the same Known Gaps / Issues every cycle
/// and re-proposes already-completed work (the stale-loop failure the owner
/// hit — "calibrate Issue #12" dispatched three times). `LoopDispatchStore`
/// conforms in production; tests pass a canned array or nil.
public protocol DispatchHistoryReading: Sendable {
    /// Recent ready-dispatch proposal heads for `sessionId`, newest first.
    /// Implementations skip low-confidence / error rows (they carry no
    /// proposal). At most `limit` entries.
    func recentProposalHeads(sessionId: String, limit: Int) -> [String]
}

public struct SessionContext: Sendable {
    public let sessionUUID: String
    public let cwd: String?
    public let gitBranch: String?
    /// Last ~10 turns from the session's rolling window. Used to
    /// surface "what did the worker just finish" to the Dispatcher.
    public let lastNTurns: [SupervisorEvent]
    /// Open issues from `gh issue list`. Empty array on fetch
    /// failure or gh not installed.
    public let openIssues: [DispatchIssue]
    /// Commits on this branch since it diverged from main. Empty on
    /// fetch failure or non-repo.
    public let currentBranchCommits: [DispatchCommit]
    /// Recent pull requests (open + merged/closed) for the session's repo,
    /// from `gh pr list --state all`. Empty array on fetch failure or gh not
    /// installed. Lets the dispatcher SEE PR state (e.g. a MERGED PR) so it
    /// verifies instead of hallucinating "the PR was never opened".
    public let recentPullRequests: [DispatchPullRequest]
    /// How many dispatches the loop has already issued in this run.
    public let priorDispatchesConsidered: Int
    /// PRODUCT-DIRECTION.md content — the project's north star.
    /// Empty string if the file doesn't exist.
    public let productDirection: String
    /// The session's objective — the user's opening ask, read from the
    /// transcript. The through-line the loop drives toward: the dispatcher picks
    /// the next concrete step toward THIS, not merely a local follow-on. nil when
    /// no opening prompt is found (the loop falls back to local reasoning).
    public let objective: String?
    /// Known Gaps section from trial-notes.md — standing record of
    /// unfinished, unticketed, or blocked work.
    public let knownGaps: String
    /// TODO/FIXME markers from source files.
    public let sourceMarkers: [String]
    /// `git diff --stat main..HEAD` output lines.
    public let recentFilesChanged: [String]
    /// Proposal heads the dispatcher already produced this run (newest
    /// first). Surfaced to the model so it doesn't re-propose them, and used
    /// by the deterministic `stalenessRejection` backstop. Empty for a fresh
    /// loop or when no history reader is wired.
    public let recentDispatchProposals: [String]

    public init(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        openIssues: [DispatchIssue],
        currentBranchCommits: [DispatchCommit],
        recentPullRequests: [DispatchPullRequest] = [],
        priorDispatchesConsidered: Int = 0,
        productDirection: String = "",
        objective: String? = nil,
        knownGaps: String = "",
        sourceMarkers: [String] = [],
        recentFilesChanged: [String] = [],
        recentDispatchProposals: [String] = []
    ) {
        self.sessionUUID = sessionUUID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastNTurns = lastNTurns
        self.openIssues = openIssues
        self.currentBranchCommits = currentBranchCommits
        self.recentPullRequests = recentPullRequests
        self.priorDispatchesConsidered = priorDispatchesConsidered
        self.productDirection = productDirection
        self.objective = objective
        self.knownGaps = knownGaps
        self.sourceMarkers = sourceMarkers
        self.recentFilesChanged = recentFilesChanged
        self.recentDispatchProposals = recentDispatchProposals
    }
}

/// A GitHub issue as seen by the Dispatcher. Mirrors the JSON shape
/// returned by `gh issue list --json number,title,body,labels` so the
/// IssueFetcher can decode directly. Labels carried as strings.
public struct DispatchIssue: Sendable, Equatable, Codable {
    public let number: Int
    public let title: String
    public let body: String
    public let labels: [String]

    public init(number: Int, title: String, body: String, labels: [String]) {
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
    }

    /// Match the gh JSON: labels arrive as `[{"name": "..."}, ...]`.
    /// We flatten to a string array at decode time so the Dispatcher
    /// prompt sees `bug, v0.4.0` rather than nested objects.
    enum CodingKeys: String, CodingKey {
        case number, title, body, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = (try? c.decode(String.self, forKey: .body)) ?? ""
        if let raw = try? c.decode([[String: String]].self, forKey: .labels) {
            self.labels = raw.compactMap { $0["name"] }
        } else {
            self.labels = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(labels.map { ["name": $0] }, forKey: .labels)
    }
}

/// One commit on the current branch since divergence from main. The
/// Dispatcher uses these to spot mechanical follow-on (e.g. "you just
/// added a feature but no CHANGELOG entry").
public struct DispatchCommit: Sendable, Equatable {
    public let sha: String
    public let subject: String
    public let body: String

    public init(sha: String, subject: String, body: String) {
        self.sha = sha
        self.subject = subject
        self.body = body
    }
}

/// One pull request (open or merged/closed) for the session's repo. Mirrors
/// the JSON shape returned by `gh pr list --json
/// number,title,state,headRefName,mergedAt,updatedAt`. The Dispatcher uses
/// these to SEE PR state so it verifies instead of hallucinating — e.g. a PR
/// that is MERGED must not be re-proposed as "never opened". `gh` reports
/// `state` as OPEN/CLOSED plus a separate `mergedAt`; the fetcher normalizes a
/// non-null `mergedAt` to state MERGED at decode time so the prompt sees a
/// single tri-state (OPEN/MERGED/CLOSED).
public struct DispatchPullRequest: Sendable, Equatable, Codable {
    public let number: Int
    public let title: String
    public let state: String
    public let headRefName: String
    public let updatedAt: String

    public init(number: Int, title: String, state: String, headRefName: String, updatedAt: String) {
        self.number = number
        self.title = title
        self.state = state
        self.headRefName = headRefName
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case number, title, state, headRefName, mergedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.headRefName = (try? c.decode(String.self, forKey: .headRefName)) ?? ""
        self.updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        // gh returns state OPEN/CLOSED and a separate mergedAt timestamp. A
        // non-null mergedAt means the PR landed — normalize to MERGED so the
        // prompt sees a single tri-state instead of a CLOSED that was actually
        // merged. `mergedAt` decodes to nil when JSON null or absent.
        let rawState = (try? c.decode(String.self, forKey: .state)) ?? ""
        let mergedAt = (try? c.decode(String?.self, forKey: .mergedAt)) ?? nil
        if let mergedAt, !mergedAt.isEmpty {
            self.state = "MERGED"
        } else {
            self.state = rawState
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(state, forKey: .state)
        try c.encode(headRefName, forKey: .headRefName)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - The Dispatcher

/// Protocol for the engine-facing Dispatcher surface. Concrete impl
/// is `Dispatcher`; tests inject a mock that returns canned results.
public protocol Dispatching: Sendable {
    /// Assemble a SessionContext (fetches issues + commits internally)
    /// and run the Dispatcher call. Engine calls this on every idle
    /// fire; returns the structured result that the engine maps onto
    /// the TriageCandidate before handing to the router.
    ///
    /// `priorDispatchesConsidered` is the loop control's count of
    /// prior dispatches in this run (Part C populates this from the
    /// `loop_dispatches` table; 0 until then). The Dispatcher prompt
    /// uses it to weight thrashing detection.
    func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        priorDispatchesConsidered: Int
    ) async -> DispatchResult
}

extension Dispatching {
    /// Default arg = 0 keeps every existing call site source-compatible.
    /// New Part C callers pass an actual count; everyone else gets the
    /// fresh-context behavior.
    public func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent]
    ) async -> DispatchResult {
        await dispatchForIdleSession(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            priorDispatchesConsidered: 0
        )
    }
}

public final class Dispatcher: Dispatching, Sendable {

    private let client: LLMClient
    private let fallbackPrinciplesText: String
    private let principlesPath: URL?
    private let issueFetcher: (any IssueFetching)?
    private let commitFetcher: (any BranchCommitFetching)?
    private let prFetcher: (any PRFetching)?
    private let dispatchHistory: (any DispatchHistoryReading)?
    private let grounder: (any ProposalGrounding)?
    private let trace: TraceLog

    /// `principlesText` is the fallback PRINCIPLES.md body. If
    /// `principlesPath` is provided, the Dispatcher re-reads from disk
    /// on each dispatch call so a 4-hour loop picks up edits. The disk
    /// read (~28k, <1ms on SSD) is cheap relative to the Haiku call.
    /// Falls back to the constructor text if the file read fails.
    ///
    /// `issueFetcher` and `commitFetcher` are optional: if nil, the
    /// dispatcher proceeds with empty context for that source.
    public init(
        client: LLMClient,
        principlesText: String,
        principlesPath: URL? = nil,
        issueFetcher: (any IssueFetching)? = nil,
        commitFetcher: (any BranchCommitFetching)? = nil,
        prFetcher: (any PRFetching)? = nil,
        dispatchHistory: (any DispatchHistoryReading)? = nil,
        grounder: (any ProposalGrounding)? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.fallbackPrinciplesText = principlesText
        self.principlesPath = principlesPath
        self.issueFetcher = issueFetcher
        self.commitFetcher = commitFetcher
        self.prFetcher = prFetcher
        self.dispatchHistory = dispatchHistory
        self.grounder = grounder
        self.trace = trace
    }

    /// Read PRINCIPLES.md from disk if a path is set, falling back to
    /// the constructor-provided text. Re-reads on every dispatch so
    /// long-running loops pick up edits. A re-read that comes back below
    /// the stub threshold (a stale bundle's near-empty PRINCIPLES.md) is
    /// rejected in favor of the constructor text so a mid-loop swap to a
    /// stub bundle can't degrade the dispatch contract.
    private var principlesText: String {
        guard let path = principlesPath,
              let fresh = try? String(contentsOf: path, encoding: .utf8),
              !fresh.isEmpty else {
            return fallbackPrinciplesText
        }
        if fresh.count < PrinciplesResolver.stubThreshold {
            trace.emit("dispatch", "PRINCIPLES re-read at \(path.path) is only \(fresh.count) chars (looks like a stub); using fallback text")
            return fallbackPrinciplesText
        }
        return fresh
    }

    /// Engine-facing entry point. Concurrently fetches issues + commits
    /// (each with its own timeout/cache, both degrade silently to empty
    /// arrays on failure), assembles SessionContext, then runs the
    /// Haiku dispatch call.
    public func dispatchForIdleSession(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        priorDispatchesConsidered: Int
    ) async -> DispatchResult {
        // Context assembly (issues + commits + objective + known gaps +
        // product direction + recent proposals) is factored into
        // SessionContextBuilder so the Planner builds the SAME bundle from
        // the SAME sources rather than duplicating the fetch/read logic.
        let context = await SessionContextBuilder.build(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            priorDispatchesConsidered: priorDispatchesConsidered,
            issueFetcher: issueFetcher,
            commitFetcher: commitFetcher,
            prFetcher: prFetcher,
            dispatchHistory: dispatchHistory,
            trace: trace,
            traceTag: "dispatch"
        )
        return await dispatch(context: context)
    }

    /// Pick the next task for an idle worker and produce the prompt to
    /// inject. Returns a structured `DispatchResult`; the caller (router)
    /// decides what to do with each case. Never throws — all errors land
    /// in `.error(reasoning:)` so the dispatch call cannot crash the
    /// engine.
    public func dispatch(context: SessionContext) async -> DispatchResult {
        let req = AnthropicMessageRequest(
            model: client.provider.defaultTriageModel,
            max_tokens: 8192,
            system: Self.systemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.userMessage(
                    context: context,
                    principles: principlesText
                )))
            ],
            tools: [Self.recordDispatchTool],
            tool_choice: .forced(Self.recordDispatchToolName)
        )

        trace.emit("dispatch", "haiku call started session=\(context.sessionUUID) issues=\(context.openIssues.count) commits=\(context.currentBranchCommits.count) turns=\(context.lastNTurns.count)")

        let resp: AnthropicMessageResponse
        do {
            resp = try await client.createMessage(req)
        } catch {
            trace.emit("dispatch", "ERROR haiku call failed: \(error)")
            return .error(reasoning: "Haiku call failed: \(error)")
        }

        trace.emit("dispatch", "haiku returned model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens) stop_reason=\(resp.stop_reason ?? "(nil)")")

        guard let parsed = Self.parseDispatchResult(from: resp) else {
            // Diagnostic: dump content block types + first 300 chars of any
            // tool_use input so we can see truncated JSON from max_tokens hits.
            let contentSummary = resp.content.map { "\($0.type):\($0.name ?? "-")" }.joined(separator: ", ")
            let rawHead = resp.content.first.flatMap { block -> String? in
                guard let input = block.input else { return nil }
                let s = String(describing: input)
                return String(s.prefix(300))
            } ?? "(no input)"
            trace.emit("dispatch", "ERROR parse failed stop_reason=\(resp.stop_reason ?? "(nil)") content=[\(contentSummary)] input_head=\"\(rawHead)\"")
            return .error(reasoning: "Dispatcher did not return a parseable record_dispatch call. stop_reason=\(resp.stop_reason ?? "(nil)")")
        }

        // Defensive: if the model returned confidence=.low OR
        // selectedPath=.lowConfidenceNoAction, normalize to .lowConfidence
        // regardless of what next_task_proposal says — the router
        // shouldn't inject a half-confidence proposal.
        switch parsed {
        case let .ready(prompt, justification, _, .objectiveComplete, _, _, _):
            // The model judged the session objective MET. Terminal success,
            // regardless of confidence — completion is a judgment, not a task to
            // dispatch, so it wins over the low-confidence normalization below.
            // summary prefers the proposal field (where the prompt asks for the
            // one-line account), falling back to the justification.
            let summary = prompt.isEmpty ? justification : prompt
            trace.emit("dispatch", "objective_complete summary=\"\(summary.prefix(160))\"")
            return .objectiveComplete(summary: summary)
        case let .ready(_, justification, .low, _, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch path=\(parsed.selectedPathDescription) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(_, justification, _, .lowConfidenceNoAction, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch (selected_path=low_confidence_no_action) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(prompt, justification, confidence, path, issueN, priorEchoed, requiresHuman):
            // ROOT-CAUSE PREMISE VERIFICATION. The in-app loop must not type a
            // proposal whose premise is false in the current tree. The runaway
            // was the dispatcher proposing to BUILD the loop / Dispatcher /
            // triage engine itself — machinery that already exists. The Python
            // Stop-hook grounds its proposals; the in-app loop never did, so it
            // dispatched "build the Dispatcher" raw. A rejected proposal
            // degrades to low-confidence (idle), which also feeds the
            // consecutive-low hard-stop, so a stuck dispatcher STOPS instead of
            // spinning — no manual kill needed.
            if let reject = Self.premiseRejection(proposal: prompt, justification: justification) {
                trace.emit("dispatch", "PREMISE_REJECT \(reject) — degrading to low-confidence idle (proposal builds/wires already-existing machinery)")
                return .lowConfidence(reasoning: "Premise rejected (\(reject)): the proposal builds or wires a component that already exists. Idling instead of dispatching already-done, self-referential work.")
            }
            // STALE-LOOP BACKSTOP. The model is shown its recent proposals (see
            // userMessage) and told not to repeat them, but if it re-proposes a
            // near-duplicate of work it already dispatched this run, degrade to
            // low-confidence. That idles the cycle AND feeds the consecutive-low
            // hard stop, so a stuck-repeating loop STOPS itself instead of
            // re-typing the same task at the worker — the failure the owner saw
            // ("calibrate Issue #12" dispatched three times). The prompt handles
            // re-worded repeats; this catches the case where the model ignores
            // the instruction outright.
            if let stale = Self.stalenessRejection(proposal: prompt, against: context.recentDispatchProposals) {
                trace.emit("dispatch", "STALE_REJECT \(stale) — degrading to low-confidence idle (proposal repeats a recent dispatch)")
                return .lowConfidence(reasoning: "Stale dispatch (\(stale)): this proposal repeats work already dispatched this run. Idling instead of re-typing the same task; if this recurs the consecutive-low stop will pause the loop.")
            }
            // ENV-CLAIM BACKSTOP. The dispatcher must not justify work with a
            // false UNBLOCKING PRECONDITION — "the ANTHROPIC_API_KEY is set;
            // sweeps are unblocked" when the key is absent (the live failure
            // 2026-06-04). Mirror of the Python hook's _ground_environment_claims.
            if let envReject = Self.environmentClaimRejection(proposal: prompt, justification: justification) {
                trace.emit("dispatch", "ENV_CLAIM_REJECT \(envReject) — degrading to low-confidence idle (fabricated unblocking precondition)")
                return .lowConfidence(reasoning: "Environment claim rejected (\(envReject)): the proposal asserts an unblocking precondition (API key / sweep available) that is not true. Idling instead of dispatching blocked work.")
            }
            // TASK 2: CROSS-PROJECT GROUNDING. The proposal must be about THIS
            // session's project. Verify every code symbol it names exists in the
            // repo at the session's cwd; a proposal that references another
            // project's code (a contaminated transcript proposing landing-page
            // work for the supervisor repo) fails to ground and is discarded.
            // Makes transcript contamination inert without scrubbing history.
            if let grounder {
                let cwd = context.cwd ?? ""
                if cwd.isEmpty {
                    trace.emit("dispatch", "CROSS_PROJECT_REJECT reason=no_cwd — cannot ground proposal; discarding")
                    return .lowConfidence(reasoning: "Cannot ground the proposal — this session's cwd is unresolved. Idling rather than dispatching ungrounded work.")
                }
                let missing = await grounder.missingSymbols(inProposal: prompt, cwd: cwd)
                if !missing.isEmpty {
                    let head = missing.prefix(5).joined(separator: ",")
                    trace.emit("dispatch", "CROSS_PROJECT_REJECT cwd=\(cwd) missing_symbols=\(head) — proposal names code absent from this session's repo; discarding")
                    return .lowConfidence(reasoning: "Cross-project proposal rejected: it references \(head), which does not exist in this session's repo (\(cwd)). Idling instead of dispatching another project's work into this session.")
                }
                // DEPLOY-STATE grounding: a proposal that justifies itself by
                // citing commits ("commit abc123 shipped X / was never
                // deployed") must reference REAL commits. A fabricated hash is a
                // fabricated premise (the 2026-06-07 "deploy the already-deployed
                // kill-catch" dispatch cited two hashes that don't exist). Check
                // proposal + justification — the deploy-state claim lives there.
                let badCommits = await grounder.missingCommits(inText: prompt + " " + justification, cwd: cwd)
                if !badCommits.isEmpty {
                    let head = badCommits.prefix(5).joined(separator: ",")
                    trace.emit("dispatch", "DEPLOY_STATE_REJECT cwd=\(cwd) missing_commits=\(head) — proposal cites commits absent from the repo; discarding")
                    return .lowConfidence(reasoning: "Deploy-state claim rejected: the proposal cites commit(s) \(head) that don't exist in this repo — a fabricated 'shipped/deployed/never-deployed' premise. Idling instead of acting on an unverifiable claim.")
                }
            }
            trace.emit("dispatch", "ready confidence=\(confidence.rawValue) path=\(path.rawValue) issue=\(issueN.map(String.init) ?? "-") prior_echoed=\(priorEchoed.map(String.init) ?? "-") requires_human=\(requiresHuman) prompt_bytes=\(prompt.utf8.count) just=\"\(justification.prefix(120))\"")
            return .ready(
                prompt: prompt,
                justification: justification,
                confidence: confidence,
                selectedPath: path,
                selectedIssueNumber: issueN,
                priorDispatchesEchoed: priorEchoed,
                requiresHumanPresence: requiresHuman
            )
        default:
            return parsed
        }
    }

    // MARK: - Prompts

    /// The bundled prompt resource, resolved in THIS target's bundle
    /// (resource bundles are per-target, so tests must reach it through here
    /// rather than their own module bundle). Exposed internal for the
    /// install-path regression test.
    ///
    /// Deliberately NOT `Bundle.module`. The synthesized accessor probes only
    /// the .app ROOT and a hardcoded build-machine path, calls `fatalError`
    /// when both miss, and `build-app.sh` embeds the bundle in
    /// `Contents/Resources/` — neither location. On the build machine the
    /// hardcoded path hides it; on a user's Mac this static is reached from
    /// `systemPrompt` on the default-ON auto-dispatch path and would crash the
    /// app outright. `CoreResourceBundle` probes the packaged layouts and
    /// returns nil instead, so a missing bundle falls through to the
    /// `#filePath` candidates below and finally the loud stub.
    public static var bundledPromptURL: URL? {
        CoreResourceBundle.url(forResource: "dispatcher-system-prompt", withExtension: "txt")
    }

    /// The Dispatcher system prompt. Synced with
    /// `Tools/dispatch-loop-hook/dispatcher-system-prompt.txt` which is
    /// the canonical source for the Python hook path. When editing,
    /// update both. The .txt file is what the Python hook reads at
    /// runtime; this static is what the Swift in-app path uses.
    public static let systemPrompt: String = {
        // Resolve the prompt file on ANY checkout. The previous hardcoded
        // /Users/main/... path broke CI — the runner lives under
        // /Users/runner/work/..., so the load silently fell back to the stub
        // and every "prompt must contain X" test failed. `#filePath` is this
        // source file's location at COMPILE time, so we derive the repo root
        // from it portably (works on the runner, the owner's machine, and any
        // future clone). The file is git-tracked, so it's always in-tree.
        // FIRST candidate is the bundled SPM resource: the only one that
        // exists on an end user's machine (the dmg has no checkout). The
        // #filePath-derived candidates below only work where the BUILD
        // machine's checkout exists at that path — which is why every
        // install except the build machine's silently ran the stub until
        // the resource was bundled (audit finding B1).
        if let bundled = Dispatcher.bundledPromptURL,
           let text = try? String(contentsOf: bundled, encoding: .utf8), !text.isEmpty {
            return text
        }
        let rel = "Tools/dispatch-loop-hook/dispatcher-system-prompt.txt"
        let repoRoot = URL(fileURLWithPath: #filePath)  // <repo>/Sources/SupervisorCore/Triage/Dispatcher.swift
            .deletingLastPathComponent()   // Triage/
            .deletingLastPathComponent()   // SupervisorCore/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // <repo>/
        let candidates = [
            repoRoot.appendingPathComponent(rel),                                            // any checkout (CI, dev, clone)
            URL(fileURLWithPath: "/Users/main/supervisor/").appendingPathComponent(rel),     // owner's machine, belt-and-suspenders
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(rel),                                                // run-from-repo-root
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        // Fallback: minimal inline version. Should never fire now that the
        // path is checkout-relative — so if it does, say so loudly (stderr;
        // this static initializes before any TraceLog is injectable) instead
        // of silently dispatching off a one-line stub. The stub keeps the
        // loop functional; the warning keeps the degradation findable.
        FileHandle.standardError.write(Data(
            "Supervisor: dispatcher-system-prompt.txt not found at any candidate path; using the minimal inline dispatcher prompt\n".utf8
        ))
        return "You are the dispatcher for an autonomous Claude Code session. Pick the next task and write the prompt. Call record_dispatch exactly once."
    }()

    /// User message — pulls together the live context the system prompt
    /// references. Same pattern as `QuestionAnswerer.engineeringUserMessage`.
    static func userMessage(context: SessionContext, principles: String) -> String {
        var lines: [String] = []

        lines.append("# Session context")
        lines.append("session: \(context.sessionUUID)")
        lines.append("cwd: \(context.cwd ?? "(unknown)")")
        lines.append("branch: \(context.gitBranch ?? "(unknown)")")
        lines.append("")

        lines.append("# Loop state")
        lines.append("prior_dispatches_considered: \(context.priorDispatchesConsidered)")
        lines.append("")

        lines.append("# Proposals you ALREADY dispatched this run (do NOT repeat)")
        if context.recentDispatchProposals.isEmpty {
            lines.append("(none yet — first dispatch of the run)")
        } else {
            lines.append("You already typed these into the worker. Do NOT propose any of them again,")
            lines.append("and do NOT re-word the same task. If the worker pushed back on one as")
            lines.append("already-done, believe it. If the single most useful move you can find")
            lines.append("duplicates one of these, the work is already underway or complete — return")
            lines.append("confidence=low (selected_path=low_confidence_no_action) instead of repeating.")
            for (idx, p) in context.recentDispatchProposals.enumerated() {
                lines.append("\(idx + 1). \(p)")
            }
        }
        lines.append("")

        // Session objective — the through-line, the single most important
        // anchor. Drives the dispatcher toward what the user actually asked for
        // instead of idling when the immediate thread looks done.
        lines.append("# SESSION OBJECTIVE (the user's opening ask — the through-line you are driving toward)")
        lines.append("")
        if let objective = context.objective, !objective.isEmpty {
            lines.append(objective)
            lines.append("")
            lines.append("Your PRIMARY job is to pick the next concrete step that moves toward THIS objective. A step toward the stated objective is grounded work, not invented scope. Treat the objective as unmet until the work it describes is actually built and verified; keep driving the worker toward it rather than idling, unless a safety gate or the human says otherwise.")
            lines.append("")
            lines.append("FIRST judge completion: if the recent transcript and shipped work show the objective is ALREADY met (built and verified), return selected_path=objective_complete with a one-line summary of what was built in next_task_proposal. Do NOT invent a follow-on task past a met objective. Only when it is genuinely unmet do you pick the next step toward it.")
            lines.append("HONOR THE WORKER'S REJECTION: if the recent transcript shows the worker pushed back on a task as already-done, stale, or wrong (e.g. \"that was already deployed three deploys ago\", \"this is the loop re-proposing finished work\"), treat that task as DONE and never re-propose it. The worker rejecting a proposal is the strongest possible signal it must not be dispatched — re-typing it at them is the exact failure to avoid.")
        } else {
            lines.append("(no opening prompt captured — fall back to local reasoning from recent work, PRODUCT-DIRECTION.md, and the backlog)")
        }
        lines.append("")

        // Product direction — the north star
        lines.append("# PRODUCT-DIRECTION.md (where the project is going)")
        lines.append("")
        if !context.productDirection.isEmpty {
            lines.append(context.productDirection)
        } else {
            lines.append("(not found — no PRODUCT-DIRECTION.md in repo root; reason from PRINCIPLES.md and recent work instead)")
        }
        lines.append("")

        lines.append("# Recent commits on this branch (since divergence from main)")
        if context.currentBranchCommits.isEmpty {
            lines.append("(none — either fresh branch, or git fetch failed; treat as 'no commits to follow up on')")
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
            lines.append("(none — either fresh branch, or git diff failed)")
        } else {
            for fl in context.recentFilesChanged {
                lines.append(fl)
            }
        }
        lines.append("")

        // Known Gaps — the standing work record
        lines.append("# Known Gaps (unfinished, unticketed, or blocked work)")
        lines.append("")
        if !context.knownGaps.isEmpty {
            lines.append(context.knownGaps)
        } else {
            lines.append("(no Known Gaps section found in trial-notes.md)")
        }
        lines.append("")

        lines.append("# Open GitHub issues")
        if context.openIssues.isEmpty {
            lines.append("(empty — this is normal; check Known Gaps and source markers for real remaining work)")
        } else {
            for i in context.openIssues {
                let labelTag = i.labels.isEmpty ? "" : " [\(i.labels.joined(separator: ", "))]"
                lines.append("## Issue #\(i.number) — \(i.title)\(labelTag)")
                if !i.body.isEmpty {
                    let trimmed = String(i.body.prefix(600))
                    lines.append(trimmed)
                }
                lines.append("")
            }
        }

        // Recent pull requests — open + merged. This is the PR state that lets
        // the dispatcher VERIFY whether the objective's deliverable already
        // landed (e.g. a MERGED PR) instead of hallucinating "the PR was never
        // opened". A MERGED PR whose title matches the objective is the strongest
        // signal the work shipped — do not re-propose it.
        lines.append("# Recent pull requests (open + merged)")
        if context.recentPullRequests.isEmpty {
            lines.append("(none found — either no PRs, or gh fetch failed; absence here does NOT prove a PR was never opened)")
        } else {
            for pr in context.recentPullRequests {
                lines.append("## PR #\(pr.number) [\(pr.state)] \(pr.title) (branch \(pr.headRefName))")
            }
        }
        lines.append("")

        // Source-level markers
        lines.append("# Source markers (TODO/FIXME in recently-touched files)")
        if !context.sourceMarkers.isEmpty {
            for m in context.sourceMarkers {
                lines.append(m)
            }
        } else {
            lines.append("(none found)")
        }
        lines.append("")

        lines.append("# Session's last turns (what the worker just did — 'the screen')")
        if context.lastNTurns.isEmpty {
            lines.append("(no events in window)")
        } else {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // The most-recent turns ARE the current state the proposal must
            // respond to, so give the last 3 more room (~600 chars) and keep
            // older turns compact (~240) to stay inside the token budget.
            let window = Array(context.lastNTurns.suffix(10))
            let recentCutoff = max(0, window.count - 3)
            for (idx, event) in window.enumerated() {
                let ts = fmt.string(from: event.timestamp)
                let maxLen = idx >= recentCutoff ? 600 : 240
                lines.append(turnLine(event, ts: ts, maxLen: maxLen))
            }
        }
        lines.append("")

        lines.append("# PRINCIPLES.md (the project's operating manual)")
        lines.append("")
        lines.append(principles)
        lines.append("")

        lines.append("# Task")
        lines.append("Call `record_dispatch` exactly once. Choose the single most useful next move that advances the project direction, grounded in the real state of the work. Write the next_task_proposal so it is SPECIFICALLY RELEVANT to the recent turns above: respond to what the worker just did and where this conversation actually is, naming the concrete files, commits, errors, or output in play. The next_task_proposal you write IS the prompt that gets typed into Claude Code, so write it like a senior collaborator who just read this exact conversation and is giving the specific next step, not generic boilerplate.")
        lines.append("Grounding honesty: before proposing anything the SESSION OBJECTIVE asks for, check the recent turns and the state above for whether it is ALREADY DONE. Autonomous sessions routinely finish the objective and land the deliverable somewhere only partly visible here (a merged PR, a different branch or repo, a deploy). If the recent turns show it was accomplished (a PR opened or merged, work shipped), do NOT re-propose it, and NEVER claim something \"was never done\" or \"is missing\" unless the context here actually shows its absence. The state shown to you is PARTIAL. When you cannot point to concrete present evidence that work is genuinely unfinished, return low_confidence_no_action instead of inventing a gap.")

        return lines.joined(separator: "\n")
    }

    /// Compact one-liner for a single event in the recent-turns section.
    /// Mirrors TriagePrompt.eventSummaryLine so the Dispatcher and the
    /// triage paths surface session history in the same shape.
    /// `maxLen` is the per-turn text budget. The recent-turns window passes a
    /// larger value for the last few turns so the model sees the actual current
    /// state, not a stub; older turns stay compact. Commands get a slightly
    /// tighter slice (maxLen-40) as they did before, kept proportional.
    private static func turnLine(_ event: SupervisorEvent, ts: String, maxLen: Int = 240) -> String {
        let cmdLen = max(0, maxLen - 40)
        switch event {
        case .sessionStart(let i):
            return "[\(ts)] sessionStart branch=\(i.gitBranch ?? "?")"
        case .userPrompt(let i):
            return "[\(ts)] userPrompt: \(i.text.prefix(maxLen))"
        case .assistantText(let i):
            return "[\(ts)] assistantText: \(i.text.prefix(maxLen))"
        case .bashToolCall(let i):
            return "[\(ts)] bashToolCall: \(i.command.prefix(cmdLen))"
        case .bashToolResult(let i):
            return "[\(ts)] bashToolResult error=\(i.isError) bytes=\(i.output.utf8.count)"
        case .fileEdit(let i):
            return "[\(ts)] fileEdit \(i.toolName) \(i.filePath) (\(i.hunks.count) change(s))"
        case .systemSignal(let i):
            return "[\(ts)] systemSignal \(i.subtype)"
        }
    }

    // MARK: - Tool schema

    static let recordDispatchToolName = "record_dispatch"

    /// `record_dispatch` — forced tool call shape. Mirrors the spec's
    /// output schema in B3. `next_task_proposal` is empty when
    /// `selected_path == low_confidence_no_action`.
    static var recordDispatchTool: AnthropicTool {
        AnthropicTool(
            name: recordDispatchToolName,
            description: "Record the dispatch verdict: which task to pick up next + the prompt to inject into Claude Code.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "next_task_proposal": .object([
                        "type": .string("string"),
                        "description": .string("The actual prompt to type into Claude Code's input. Ground it in where THIS conversation actually is right now: respond to the worker's most recent messages and output, the specific files, commits, and errors in play (see the 'Session's last turns' section), and the concrete next step that follows from them. Write like a senior collaborator who has just read the conversation: name a clear next action and how to know it is done. Be concrete and actionable; a tight, specific paragraph beats a long generic one. Do NOT emit generic boilerplate, and do NOT reference PRINCIPLES sections by number. Empty string when selected_path=low_confidence_no_action.")
                    ]),
                    "justification": .object([
                        "type": .string("string"),
                        "description": .string("2-3 sentences. Why this task, why now, what principles ground it. Lands in the trace log + the asymmetry note on the flag.")
                    ]),
                    "confidence": .object([
                        "type": .string("string"),
                        "enum": .array([.string("high"), .string("medium"), .string("low")]),
                        "description": .string("high → auto-dispatch (Supervisor types the prompt into Claude Code). medium → propose-and-wait (banner shows the proposal, user pastes if they want). low → surface the idle state (banner says 'I couldn't pick'). Per PRINCIPLES §9e budget envelope — only auto-dispatch on high.")
                    ]),
                    "selected_path": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("continue_branch"),
                            .string("transition_to_issue"),
                            .string("low_confidence_no_action"),
                            .string("objective_complete"),
                        ]),
                        "description": .string("continue_branch = mechanical follow-on on the current branch; transition_to_issue = pick a sized issue from the queue; low_confidence_no_action = couldn't pick a task, surface to user; objective_complete = the SESSION OBJECTIVE is already met by the work so far, so the loop should stop cleanly (put a one-line summary of what was built in next_task_proposal).")
                    ]),
                    "selected_issue_number": .object([
                        "type": .string("integer"),
                        "description": .string("REQUIRED when selected_path=transition_to_issue; omit otherwise. The issue number from the open queue.")
                    ]),
                    "prior_dispatches_considered": .object([
                        "type": .string("integer"),
                        "description": .string("Optional. Echo back the prior_dispatches_considered value you saw in the input, so the trace post-mortem can confirm you weighed thrashing detection correctly. Default 0 (fresh context). Populated by the engine; absent means the engine isn't yet instrumenting loop state (Part C ships the counter).")
                    ]),
                    "requires_human_presence": .object([
                        "type": .string("boolean"),
                        "description": .string("Set to true ONLY when the task is genuinely impossible for a terminal process — AX permission grants in System Settings, sustained visual observation trials. NOT for rebuilds, tests, commits, script execution, or any shell-executable operation. Default false.")
                    ]),
                ]),
                "required": .array([
                    .string("next_task_proposal"),
                    .string("justification"),
                    .string("confidence"),
                    .string("selected_path"),
                ])
            ])
        )
    }

    // MARK: - Parser

    // The string-only anti-fabrication backstops now live in
    // ProposalBackstops.swift so the Dispatcher and the Planner share ONE
    // copy. These thin forwarders preserve the Dispatcher's existing static
    // surface (and its tests) verbatim — observable behavior is unchanged.

    /// Forwards to `ProposalBackstops.premiseRejection`. See there for the
    /// full contract (rejects build/wire of already-existing machinery and
    /// false "X is missing" claims; never blocks genuine work ON a component).
    static func premiseRejection(proposal: String, justification: String) -> String? {
        ProposalBackstops.premiseRejection(proposal: proposal, justification: justification)
    }

    /// Forwards to `ProposalBackstops.stalenessRejection` — Jaccard-0.85
    /// near-verbatim repeat guard against re-dispatching this run's work.
    static func stalenessRejection(proposal: String, against recent: [String]) -> String? {
        ProposalBackstops.stalenessRejection(proposal: proposal, against: recent)
    }

    /// Forwards to `ProposalBackstops.significantTokens` — prefix-6 stemmed,
    /// stopword-stripped, number-preserving token set used for similarity.
    static func significantTokens(_ s: String) -> Set<String> {
        ProposalBackstops.significantTokens(s)
    }

    /// Forwards to `ProposalBackstops.environmentClaimRejection` — rejects a
    /// fabricated unblocking precondition ("the API key is set; sweeps are
    /// unblocked") when the key is actually absent.
    static func environmentClaimRejection(
        proposal: String,
        justification: String,
        anthropicKey: String? = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    ) -> String? {
        ProposalBackstops.environmentClaimRejection(
            proposal: proposal, justification: justification, anthropicKey: anthropicKey
        )
    }

    /// Forwards to `ProposalBackstops.assertsEnvironmentAvailability` — the
    /// positive-availability adjacency check (honest "it's blocked" passes).
    static func assertsEnvironmentAvailability(_ text: String) -> Bool {
        ProposalBackstops.assertsEnvironmentAvailability(text)
    }

    /// Decode the record_dispatch tool call into a DispatchResult.
    /// Returns nil if the response shape is unusable (no tool call /
    /// missing required fields). The caller maps nil to .error.
    static func parseDispatchResult(from response: AnthropicMessageResponse) -> DispatchResult? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == recordDispatchToolName,
                  case let .object(input)? = block.input
            else { continue }

            guard case let .string(proposal)? = input["next_task_proposal"],
                  case let .string(justification)? = input["justification"],
                  case let .string(confStr)? = input["confidence"],
                  case let .string(pathStr)? = input["selected_path"]
            else { return nil }

            let confidence = DispatchConfidence(rawValue: confStr) ?? .low
            let path = SelectedPath(rawValue: pathStr) ?? .lowConfidenceNoAction

            var issueNumber: Int? = nil
            if case let .integer(n)? = input["selected_issue_number"] {
                issueNumber = Int(n)
            }

            var priorEchoed: Int? = nil
            if case let .integer(n)? = input["prior_dispatches_considered"] {
                priorEchoed = Int(n)
            }

            var requiresHuman = false
            if case let .bool(b)? = input["requires_human_presence"] {
                requiresHuman = b
            }

            return .ready(
                prompt: proposal,
                justification: justification,
                confidence: confidence,
                selectedPath: path,
                selectedIssueNumber: issueNumber,
                priorDispatchesEchoed: priorEchoed,
                requiresHumanPresence: requiresHuman
            )
        }
        return nil
    }
}

// MARK: - Selected-path description helper

extension DispatchResult {
    /// Trace-line-friendly description of the selected path.
    var selectedPathDescription: String {
        switch self {
        case let .ready(_, _, _, path, _, _, _): return path.rawValue
        case .lowConfidence: return "low_confidence_no_action"
        case .error: return "error"
        case .objectiveComplete: return "objective_complete"
        }
    }
}
