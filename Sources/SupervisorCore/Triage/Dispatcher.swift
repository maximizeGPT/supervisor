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
//   - It writes the next_task_proposal in the autonomous opener's
//     voice (§5 engineering-decisions-are-yours; §11 voice/tone).
//     The proposal IS the prompt that gets injected — it reads
//     like a session-opener written by Mohammed, not like LLM
//     output addressed to a user.
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

    public static func == (lhs: DispatchResult, rhs: DispatchResult) -> Bool {
        switch (lhs, rhs) {
        case let (.ready(p1, j1, c1, sp1, n1, e1, h1), .ready(p2, j2, c2, sp2, n2, e2, h2)):
            return p1 == p2 && j1 == j2 && c1 == c2 && sp1 == sp2 && n1 == n2 && e1 == e2 && h1 == h2
        case let (.lowConfidence(r1), .lowConfidence(r2)):
            return r1 == r2
        case let (.error(r1), .error(r2)):
            return r1 == r2
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
}

// MARK: - Session context

/// The bundle the Dispatcher needs to make its call. The TriageEngine
/// assembles this at idle-flag time and hands it to the Dispatcher; the
/// Dispatcher is pure with respect to the bundle.
public struct SessionContext: Sendable {
    public let sessionUUID: String
    public let cwd: String?
    public let gitBranch: String?
    /// Last ~10 turns from the session's rolling window. Used to
    /// surface "what did the worker just finish" to the Dispatcher.
    public let lastNTurns: [SupervisorEvent]
    /// Open issues from `gh issue list`. Empty array on fetch
    /// failure or gh not installed; the Dispatcher prompt is
    /// taught to lower confidence when the queue is empty.
    public let openIssues: [DispatchIssue]
    /// Commits on this branch since it diverged from main. Empty on
    /// fetch failure or non-repo.
    public let currentBranchCommits: [DispatchCommit]
    /// v0.4.0 Part B (per Mohammed's B8 review): how many dispatches
    /// the loop control has already issued in this run, before this
    /// call. Default 0 = fresh context. The Dispatcher prompt uses
    /// this to weight thrashing detection: a long chain of dispatches
    /// without progress is signal the loop is improvising, and the
    /// dispatcher should ramp confidence down. Part C is what
    /// actually populates this from `loop_dispatches`; until then
    /// every call passes 0.
    public let priorDispatchesConsidered: Int

    public init(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        openIssues: [DispatchIssue],
        currentBranchCommits: [DispatchCommit],
        priorDispatchesConsidered: Int = 0
    ) {
        self.sessionUUID = sessionUUID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastNTurns = lastNTurns
        self.openIssues = openIssues
        self.currentBranchCommits = currentBranchCommits
        self.priorDispatchesConsidered = priorDispatchesConsidered
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
    private let principlesText: String
    private let issueFetcher: (any IssueFetching)?
    private let commitFetcher: (any BranchCommitFetching)?
    private let trace: TraceLog

    /// `principlesText` is the full PRINCIPLES.md body, loaded once at
    /// construction (same pattern as QuestionAnswerer). PRINCIPLES is
    /// session-stable; re-reading on every dispatch would add ~28k of
    /// disk IO per call for no benefit.
    ///
    /// `issueFetcher` and `commitFetcher` are optional: if nil, the
    /// dispatcher proceeds with empty context for that source. Useful
    /// for tests (canned context, no shell-out) and for graceful
    /// degradation in production when gh isn't installed.
    public init(
        client: LLMClient,
        principlesText: String,
        issueFetcher: (any IssueFetching)? = nil,
        commitFetcher: (any BranchCommitFetching)? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.principlesText = principlesText
        self.issueFetcher = issueFetcher
        self.commitFetcher = commitFetcher
        self.trace = trace
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
        // Concurrent fetches. Both swallow errors into empty arrays so
        // the dispatch proceeds even when gh / git misbehave; trace
        // tags from the fetchers already discriminate the reason.
        async let issuesFut: [DispatchIssue] = {
            guard let fetcher = self.issueFetcher, let cwd = cwd else { return [] }
            do {
                return try await fetcher.fetchOpenIssues(cwd: cwd)
            } catch {
                self.trace.emit("dispatch", "gh fetch threw, proceeding with empty issues: \(error)")
                return []
            }
        }()
        async let commitsFut: [DispatchCommit] = {
            guard let fetcher = self.commitFetcher,
                  let cwd = cwd,
                  let branch = gitBranch else { return [] }
            do {
                return try await fetcher.fetchBranchCommits(
                    cwd: cwd, branch: branch, baseBranch: "main"
                )
            } catch {
                self.trace.emit("dispatch", "git log threw, proceeding with empty commits: \(error)")
                return []
            }
        }()
        let issues = await issuesFut
        let commits = await commitsFut

        let context = SessionContext(
            sessionUUID: sessionUUID,
            cwd: cwd,
            gitBranch: gitBranch,
            lastNTurns: lastNTurns,
            openIssues: issues,
            currentBranchCommits: commits,
            priorDispatchesConsidered: priorDispatchesConsidered
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
            max_tokens: 4096,
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
        case let .ready(_, justification, .low, _, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch path=\(parsed.selectedPathDescription) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(_, justification, _, .lowConfidenceNoAction, _, _, _):
            trace.emit("dispatch", "low-confidence dispatch (selected_path=low_confidence_no_action) reasoning=\"\(justification.prefix(160))\"")
            return .lowConfidence(reasoning: justification)
        case let .ready(prompt, justification, confidence, path, issueN, priorEchoed, requiresHuman):
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

    /// The Dispatcher system prompt. Single source of truth for the
    /// dispatch contract; surfaced verbatim to Mohammed at the B8
    /// checkpoint per the spec ("the prompt IS the product").
    static let systemPrompt: String = """
    You are the dispatcher for an autonomous Claude Code session running under Supervisor. The session just completed a piece of work and is idle on an autonomous branch. Your job: pick the next task and write the prompt that starts it.

    You are given:
      - PRINCIPLES.md (the project's operating manual — opinions, conventions, hard stops, voice).
      - The session's last 10 turns (recent context — what the worker just finished).
      - The current branch's commits since it diverged from main (work shipped this session).
      - The open GitHub issues (the work queue).
      - `prior_dispatches_considered`: how many dispatches the loop has already issued in this run.

    # Pick ONE of these two paths

    ## PATH 1 — Continue the current branch (`continue_branch`)
    If the recent commits left obvious mechanical follow-on — missing tests for new code, missing CHANGELOG entry, missing documentation for a new feature, an obvious second commit that completes a half-shipped change — the next task is that follow-on.

    - HIGH confidence when the follow-on is obvious (e.g. CHANGELOG is the canonical follow to a feature ship; new code with no tests is the canonical follow to a tested module).
    - MEDIUM confidence when the follow-on is plausible but ambiguous (multiple plausible follow-ons; "should we add docs OR tests next").
    - LOW confidence when commits look like thrashing (multiple commits revising the same code without forward progress) — that's the worker stuck, not the worker ready for more.

    ## PATH 2 — Transition to a sized issue (`transition_to_issue`)
    If the current branch's work is clearly complete (tests passing per recent context, CHANGELOG written, no obvious follow-on), pick an open issue from the queue. Prefer issues with:

    - Clear scope (the issue body specifies the work, not just the symptom).
    - No dependencies on user decisions (no "what should we call this" / "should we even do this").
    - Small enough to plausibly complete in one session (≤75 min per PRINCIPLES §12 hard-stop).

    - HIGH confidence when one issue obviously matches all three criteria.
    - MEDIUM confidence when several issues are plausible candidates and the choice is taste-shaped.

    # Return LOW confidence (`low_confidence_no_action`) when

    - Both paths look unclear: no obvious follow-on, no obvious next issue.
    - The recent commits suggest the worker is stuck or thrashing.
    - The next plausible task requires a values call from the user (taste-shaped questions, scope decisions, naming, anything in PRINCIPLES §5 "values defer to Mohammed").
    - PRINCIPLES.md doesn't ground the decision — you'd be guessing, not deciding from principles.
    - The open issue queue is empty AND there's no obvious mechanical follow-on.

    **Low confidence is a feature, not a failure.** A confident "stop, don't dispatch" return is more valuable than a forced dispatch that improvises scope. If you can't ground the choice in a documented unit of work, return low. The user pays the cost of every dispatch (PRINCIPLES §9 cost transparency); a low-confidence return saves that cost AND surfaces the gap so the user can refill the work queue.

    **If `prior_dispatches_considered > 3`, weight evidence of thrashing more heavily.** A long chain of dispatches without progress is signal the loop is improvising. Ramp confidence down accordingly — a fourth or fifth dispatch should clear a higher bar to register as HIGH than the first one would.

    # requires_human_presence gate

    Some tasks cannot be executed by an autonomous Claude Code session from a terminal. Examples: launching macOS apps, granting Accessibility permissions, physical-world trials that require observing a running app, anything involving System Settings GUI. When the task you'd pick requires any of these, set `requires_human_presence: true` in `record_dispatch` regardless of confidence. The router will NOT auto-dispatch these; instead, the proposal surfaces as a banner for the user to act on when they're physically present.

    # Hard constraint

    The next task MUST come from the open issue queue or from mechanical follow-on on the current branch. You do NOT invent new feature scope. The Dispatcher exists to keep documented work moving, not to expand it. PRINCIPLES §1d: "File an issue, don't build the feature now."

    # The next_task_proposal — voice and shape

    The `next_task_proposal` IS the prompt that gets typed into Claude Code's input. Write it in the autonomous opener's voice — first-person, direct, specific signatures over abstract behavior. The worker is a fresh Claude Code session reading only the prompt + PRINCIPLES.md + the repo.

    Required shape:
      - Opens with what's being picked up ("Continue Part B's dispatcher" / "Pick up Issue #7 — bash cross-category bleed").
      - References PRINCIPLES sections by number when grounding decisions (e.g. "per §1d file an issue if scope grows").
      - Names a clear acceptance criterion: what does "done" look like for this task.
      - Includes a hard-stop reminder ("75 min cap; stop and write the post-mortem if you hit it").
      - 200-600 words. Long enough to be unambiguous; short enough to read in one screen.
      - **Cite specific file paths or function names when the work touches code (not just module names).** Examples in this prompt do this — `TriagePrompt.swift`'s `allBodiesMarkdown`, `main.swift`'s `loadQuestionAnswerer` pattern. Match that specificity. A worker that sees "edit the rubric file" has to go searching; a worker that sees "edit `HardcodedRubric.swift`'s `categories` array" can act immediately.
      - No marketing language (PRINCIPLES §11a). No emojis (§11e).

    # Justification

    2-3 sentences. Why this task, why now, what principles ground it. Lands in the trace log + the asymmetry note on the flag. Future post-mortems read this to understand the dispatch choice.

    # Worked examples

    Four examples covering the full output space. The voice, shape, and §-references in these examples are the target — match them.

    ## Example 1 — PATH 1 (continue_branch), HIGH confidence

    ```
    selected_path: continue_branch
    confidence: high
    selected_issue_number: (omit)
    next_task_proposal:
      Continue v0.4.0 Part B by wiring SupervisorApp's main.swift to actually instantiate a Dispatcher in production.

      Part B's branch (`autonomous-20260525T193906Z`) just landed two commits: the Dispatcher module + tests, and the engine/router wiring. The Dispatcher is plumbed into TriageEngine as an optional constructor param, but main.swift still passes `dispatcher: nil` — production users get the Part-A-only idle notify, not the new auto-dispatch path.

      Done looks like: main.swift constructs `Dispatcher` after `loadQuestionAnswerer`, mirroring the same PRINCIPLES.md loader pattern (the three candidate URLs: bundle resource, repo-root fallback, hard-coded dev path). The Dispatcher takes the `LLMClient` we already build, the loaded `principlesText`, a `GitHubIssueFetcher`, and a `GitBranchCommitFetcher`. Pass the resulting instance into the `TriageEngine` constructor. If PRINCIPLES.md isn't found, the Dispatcher stays nil (matching the QuestionAnswerer degrade pattern), and the engine falls back to plain idle notify.

      Acceptance: rebuild the app, drive an idle session locally, confirm the trace log emits `[dispatch] start session=...` followed by `[dispatch] haiku returned confidence=...`. No need to drive a real auto-dispatch — Part D is the dogfood session; this is just plumbing.

      Reference PRINCIPLES §1c (wrappers not rewrites — copy the loadQuestionAnswerer shape, don't invent a new loader) and §4b (every state transition traces — confirm the dispatch trace lines fire). Hard-stop: 75 min cap per §12; if main.swift wiring spirals into a refactor, stop and journal what was missing instead of expanding scope.
    justification:
      Mechanical follow-on from the Part B impl commit — production wiring is the canonical next step after a module ships per §1a's vertical-slice rule. main.swift's loadQuestionAnswerer is the exact pattern to mirror; the work is well-shaped and grounded in §1c.
    ```

    ## Example 2 — PATH 2 (transition_to_issue), HIGH confidence

    ```
    selected_path: transition_to_issue
    selected_issue_number: 7
    confidence: high
    next_task_proposal:
      Pick up Issue #7 — bash cross-category bleed. The bug: a bash command whose grep regex literally contains the substring `user_question_pending` is firing the user_question_pending rubric category, even though that category is meant only for the assistant-text triage path. This is the §2e per-path prompt isolation gap PRINCIPLES v3 documents.

      Done looks like: the bash triage path explicitly enumerates the categories it evaluates against (destructive_action_pending, edits_outside_worktree, prompt_injection_signature) and explicitly EXCLUDES user_question_pending + worker_idle_post_completion. The assistant-text path already uses a focused prompt with that pattern (it says "Evaluate ONLY against the user_question_pending category" in `TriagePrompt.swift`'s `buildAssistantQuestionRequest`); make the bash path symmetric.

      The fix lives in `Sources/SupervisorCore/Triage/TriagePrompt.swift`: the bash `buildRequest` path concatenates `HardcodedRubric.allBodiesMarkdown` (every category) into the system prompt. Restrict it to the bash-relevant categories — either via a per-path category whitelist on `HardcodedRubric`, or via a focused-prompt scope sentence at the end of the user message (the cheaper fix).

      Acceptance: a calibration fixture for the literal `user_question_pending` regex bash command no longer fires that category. Add 2-3 such fixtures to `Tests/SupervisorCoreTests/CalibrationFixtures/destructive/`, run a targeted sweep (~30 fixtures, ~$0.10 — under §9e), and confirm the false positive is gone without regressing other bash positives.

      Reference PRINCIPLES §2e (per-path prompt isolation — the asymmetry IS the bug), §6f (fixture corrections that align tests with reproducible behavior ship without full sweeps), and §1d (file follow-on issues for anything the cheap fix doesn't reach). Hard-stop: 75 min per §12. If the calibration sweep regresses >10% from baseline, do not ship — that's the §12 calibration-regression hard stop.
    justification:
      Issue #7 has clear scope grounded in PRINCIPLES §2e (the per-path-isolation gap is documented in the manual itself); the work touches one file (`TriagePrompt.swift`) plus a small fixture addition; no values calls needed. Small enough to ship in one session.
    ```

    ## Example 3 — PATH 1 (continue_branch), MEDIUM confidence

    ```
    selected_path: continue_branch
    confidence: medium
    selected_issue_number: (omit)
    next_task_proposal:
      Pick the v0.4.0 CHANGELOG entry as the next follow-on, OR pick the Part C session prep — both are plausible after Part B shipped. I'm picking the CHANGELOG because it's the smaller of the two and grounds the user's review when they next look at the branch.

      The CHANGELOG entry for v0.4.0 needs an "In progress" header (Parts A + B are on the autonomous branch but neither is merged to main). Body should cover: the new `worker_idle_post_completion` rubric category, the dispatcher's two-call architecture (`record_triage` decides "is this idle"; `record_dispatch` decides "what to do about it"), the `.continue` intervention action between `inject` and `pause` in the ladder, and the deferred Parts C + D (loop control + dogfood) — including the §1d framing that we're shipping the vertical slice and filing the rest, not half-building four parts.

      Done looks like: a new section in `CHANGELOG.md` under "## In progress" with v0.4.0 as the header and 5-8 bullets covering what's on the autonomous branch. Mirror the voice of the v0.3.0 and v0.3.1 entries (already in the file) — first-person, specific signatures (not "robust idle detection" but "1Hz polling against last-event timestamps; stop-shape detection via case-insensitive substring match on an 8-phrase list").

      Acceptance: the CHANGELOG renders correctly on GitHub (verify with `gh pr view` or `git log -p CHANGELOG.md`); the entry reads as a half-product-with-clear-deferral, not as a finished release; Parts C and D are named with their session-scope estimates.

      Reference PRINCIPLES §1a (vertical slice — ship the fewer features that work), §4c (STATUS docs list what didn't ship alongside what did), §11 (voice: first-person, specific signatures, no marketing). Hard-stop: 75 min per §12. If the CHANGELOG entry triggers a clarification about Part C/D scope, file that as an issue rather than redesigning here.
    justification:
      Both the CHANGELOG entry and the Part C session prep are plausible follow-ons; the CHANGELOG is smaller and grounds review per §4c. Medium because the path is taste-shaped (which of two reasonable follow-ons), not because the work itself is unclear.
    ```

    ## Example 4 — LOW confidence (`low_confidence_no_action`)

    ```
    selected_path: low_confidence_no_action
    confidence: low
    selected_issue_number: (omit)
    next_task_proposal: ""
    justification:
      The open issue queue is empty (gh fetch returned no results) and the recent commits ship a complete unit — the Part C loop control + tests landed, with the CHANGELOG entry as the most recent commit. No mechanical follow-on, no queued work. Per §1d the Dispatcher does not invent scope; the right call is to stop, surface the idle state, and let the user refill the queue.
    ```

    The fourth example is the hardest call. Returning low confidence here saves the user money (no improvised dispatch), surfaces a real gap (empty queue), and preserves trust in the loop (no garbage dispatches when there's nothing to dispatch). Getting comfortable returning low when low is correct is the most valuable skill in this prompt.

    # Output

    Call `record_dispatch` exactly once with the structured output.
    """

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

        lines.append("# Recent commits on this branch (since divergence from main)")
        if context.currentBranchCommits.isEmpty {
            lines.append("(none — either fresh branch, or git fetch failed; treat as 'no commits to follow up on')")
        } else {
            for c in context.currentBranchCommits {
                lines.append("- \(c.sha.prefix(8)) \(c.subject)")
                if !c.body.isEmpty {
                    // Indent body by two spaces so it reads as a sub-item.
                    for line in c.body.split(separator: "\n") {
                        lines.append("  \(line)")
                    }
                }
            }
        }
        lines.append("")

        lines.append("# Open GitHub issues (work queue)")
        if context.openIssues.isEmpty {
            lines.append("(empty — either no open issues, or gh fetch failed; lower confidence accordingly if you were about to pick PATH 2)")
        } else {
            for i in context.openIssues {
                let labelTag = i.labels.isEmpty ? "" : " [\(i.labels.joined(separator: ", "))]"
                lines.append("## Issue #\(i.number) — \(i.title)\(labelTag)")
                if !i.body.isEmpty {
                    // Cap at ~600 chars per issue so the prompt stays bounded.
                    let trimmed = String(i.body.prefix(600))
                    lines.append(trimmed)
                }
                lines.append("")
            }
        }

        lines.append("# Session's last turns (most recent first)")
        if context.lastNTurns.isEmpty {
            lines.append("(no events in window)")
        } else {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for event in context.lastNTurns.suffix(10) {
                let ts = fmt.string(from: event.timestamp)
                lines.append(turnLine(event, ts: ts))
            }
        }
        lines.append("")

        lines.append("# PRINCIPLES.md (the project's operating manual)")
        lines.append("")
        lines.append(principles)
        lines.append("")

        lines.append("# Task")
        lines.append("Call `record_dispatch` exactly once. Pick PATH 1 (continue_branch) or PATH 2 (transition_to_issue), with confidence calibrated per the rubric in the system prompt. The next_task_proposal you write IS the prompt that gets typed into Claude Code — write it in the autonomous opener's voice.")

        return lines.joined(separator: "\n")
    }

    /// Compact one-liner for a single event in the recent-turns section.
    /// Mirrors TriagePrompt.eventSummaryLine so the Dispatcher and the
    /// triage paths surface session history in the same shape.
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
                        "description": .string("The actual prompt to type into Claude Code's input. 200-600 words, written in the autonomous opener's voice — first-person, direct, references PRINCIPLES sections by number, names acceptance criteria, includes a hard-stop reminder. Empty string when selected_path=low_confidence_no_action.")
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
                        ]),
                        "description": .string("continue_branch = mechanical follow-on on the current branch; transition_to_issue = pick a sized issue from the queue; low_confidence_no_action = couldn't pick, surface to user.")
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
                        "description": .string("Set to true when the proposed task requires macOS GUI interaction (launching apps, granting AX permissions, physical-world trials). The router will NOT auto-dispatch these — they surface as a banner for the user.")
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
        }
    }
}
