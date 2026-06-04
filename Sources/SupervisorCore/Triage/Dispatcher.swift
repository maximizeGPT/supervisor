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
    /// failure or gh not installed.
    public let openIssues: [DispatchIssue]
    /// Commits on this branch since it diverged from main. Empty on
    /// fetch failure or non-repo.
    public let currentBranchCommits: [DispatchCommit]
    /// How many dispatches the loop has already issued in this run.
    public let priorDispatchesConsidered: Int
    /// PRODUCT-DIRECTION.md content — the project's north star.
    /// Empty string if the file doesn't exist.
    public let productDirection: String
    /// Known Gaps section from trial-notes.md — standing record of
    /// unfinished, unticketed, or blocked work.
    public let knownGaps: String
    /// TODO/FIXME markers from source files.
    public let sourceMarkers: [String]
    /// `git diff --stat main..HEAD` output lines.
    public let recentFilesChanged: [String]

    public init(
        sessionUUID: String,
        cwd: String?,
        gitBranch: String?,
        lastNTurns: [SupervisorEvent],
        openIssues: [DispatchIssue],
        currentBranchCommits: [DispatchCommit],
        priorDispatchesConsidered: Int = 0,
        productDirection: String = "",
        knownGaps: String = "",
        sourceMarkers: [String] = [],
        recentFilesChanged: [String] = []
    ) {
        self.sessionUUID = sessionUUID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastNTurns = lastNTurns
        self.openIssues = openIssues
        self.currentBranchCommits = currentBranchCommits
        self.priorDispatchesConsidered = priorDispatchesConsidered
        self.productDirection = productDirection
        self.knownGaps = knownGaps
        self.sourceMarkers = sourceMarkers
        self.recentFilesChanged = recentFilesChanged
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
    private let fallbackPrinciplesText: String
    private let principlesPath: URL?
    private let issueFetcher: (any IssueFetching)?
    private let commitFetcher: (any BranchCommitFetching)?
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
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.fallbackPrinciplesText = principlesText
        self.principlesPath = principlesPath
        self.issueFetcher = issueFetcher
        self.commitFetcher = commitFetcher
        self.trace = trace
    }

    /// Read PRINCIPLES.md from disk if a path is set, falling back to
    /// the constructor-provided text. Re-reads on every dispatch so
    /// long-running loops pick up edits.
    private var principlesText: String {
        guard let path = principlesPath,
              let fresh = try? String(contentsOf: path, encoding: .utf8),
              !fresh.isEmpty else {
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

    /// The Dispatcher system prompt. Synced with
    /// `Tools/dispatch-loop-hook/dispatcher-system-prompt.txt` which is
    /// the canonical source for the Python hook path. When editing,
    /// update both. The .txt file is what the Python hook reads at
    /// runtime; this static is what the Swift in-app path uses.
    static let systemPrompt: String = {
        // Try to load from the .txt file at the known repo-relative path.
        // Falls back to a minimal inline prompt if the file isn't found
        // (e.g. when running from a built .app bundle without the repo).
        let candidates = [
            // Repo-relative (dev builds, autonomous sessions)
            URL(fileURLWithPath: "/Users/main/supervisor/Tools/dispatch-loop-hook/dispatcher-system-prompt.txt"),
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        // Fallback: minimal inline version. Should never fire in practice
        // since the dispatch loop only runs in the repo working directory.
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
        lines.append("Call `record_dispatch` exactly once. Choose the single most useful next move that advances the project direction, grounded in the real state of the work. The next_task_proposal you write IS the prompt that gets typed into Claude Code — write it like a senior collaborator giving specific, actionable direction.")

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
                        "description": .string("The actual prompt to type into Claude Code's input. 150-300 words, written in the autonomous opener's voice — first-person, direct, references PRINCIPLES sections by number, names acceptance criteria, includes a hard-stop reminder. Empty string when selected_path=low_confidence_no_action.")
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

    /// Root-cause premise verification. Returns a rejection reason if the
    /// proposal's premise is false in the current tree, else nil.
    ///
    /// The recurring runaway: the dispatcher proposing to BUILD / WIRE the
    /// dispatch loop, the Dispatcher, the triage engine, the inject path — all
    /// of which already exist — i.e. the loop describing itself as work. This
    /// is the discipline the worker applies by hand ("verify the premise: is
    /// this already done?"), now enforced deterministically so the in-app loop
    /// can never type already-done, self-referential work.
    ///
    /// PRECISE by construction (phrase-anchored, not bag-of-words) so it
    /// rejects "build the Dispatcher" but NEVER "add a test for the
    /// dispatcher" or "fix the dispatcher's grounding" — only a build/wire verb
    /// applied directly to an existing component, or a false "X is not
    /// wired/built/missing" claim about one.
    static func premiseRejection(proposal: String, justification: String) -> String? {
        let text = (proposal + " ⋄ " + justification).lowercased()

        // Core machinery that ALREADY EXISTS in this repo. Proposing to build
        // or wire any of these is a false premise (and the loop's CLOSED rule:
        // it dispatches PRODUCT work, never builds itself).
        let existing = [
            "dispatch loop", "dispatcher", "loopcontroller", "loop controller", "loopconfig",
            "triage engine", "triageengine", "inject path", "injector", "interventionrouter",
            "intervention router", "dispatch engine", "dispatch queue", "self-extender",
            "selfextender", "dispatch hook", "deterministic catch", "deterministiccatch",
            "questionanswerer", "question answerer", "hardcodedrubric",
        ]
        // Build-from-scratch verbs (NOT fix/improve/add-test/review/close — those
        // are legitimate work ON existing code).
        let buildVerbs = ["build ", "implement ", "wire up ", "wire the ", "stand up ",
                          "introduce ", "create the ", "create a ", "write the ", "design the "]
        // Prepositions that, between a build verb and a component, make the
        // component a MODIFIER, not the thing being built ("a test FOR the
        // dispatcher"). Bias toward allowing when one is present.
        let prepositions = [" for ", " of ", " to ", " about ", " on ", " with ", " in ", " into "]
        // False "it's not there" claims directly after a component.
        let missingSuffixes = [" is not wired", " is not built", " is missing", " does not exist",
                              " doesn't exist", " isn't wired", " is not implemented",
                              " is not yet wired", " is not yet built", " needs to be built",
                              " needs to be wired"]

        for comp in existing {
            guard let r = text.range(of: comp) else { continue }
            // Window just BEFORE the component: a build verb here (and no
            // intervening preposition) means the component is the build object.
            // Catches "build the CGEventPost-based Dispatcher" (adjectives in
            // between) but not "build a test for the dispatcher".
            let winStart = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let before = String(text[winStart..<r.lowerBound])
            if buildVerbs.contains(where: { before.contains($0) }),
               !prepositions.contains(where: { before.contains($0) }) {
                return "build_existing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
            // Window just AFTER the component: a false "not there" claim.
            let winEnd = text.index(r.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
            let after = String(text[r.upperBound..<winEnd])
            if missingSuffixes.contains(where: { after.contains($0) }) {
                return "false_missing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
        }
        return nil
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
        }
    }
}
