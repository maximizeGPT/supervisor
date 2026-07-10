// Evaluator.swift - v0.2.0 M2c. The Evaluator.
//
// The Planner decomposes the objective; the Generator (a live Claude Code
// session) works each step. The Evaluator closes the loop: it grades the
// step's REAL output against that step's rubric (doneCriteria) and returns a
// verdict { passed, score, feedback }. It is the skeptic in the harness.
//
// The cardinal rule of this component: grade ONLY on observed ground truth,
// NEVER on the session's self-claimed success. Models flatter their own work
// ("Done! The feature is fully implemented and all tests pass.") even when the
// build is red or no test was run. So the verdict is decided externally, from
// what actually happened: the commands that ran, their exit/error state, the
// test and build output, the errors, the file changes. The assistant's prose
// is provided to the judge only as a CLAIM to be checked against that ground
// truth, explicitly not as evidence the work is done.
//
// Design (mirrors QuestionAnswerer.swift / Planner.swift deliberately):
//   - `Evaluating` protocol mirrors `Planning` / `Dispatching` so the Evaluator
//     is mockable; tests inject a stub that returns a canned verdict.
//   - `Observation` is a plain, gradable value type - a compact snapshot of
//     what the session did since the step was injected. It is the unit-testable
//     input; the LLM never sees the raw event stream, only this distilled view.
//   - One forced-tool LLM call, `record_verdict`, the same SHAPE as
//     record_plan / record_answer: a single structured object decoded by a
//     static parser. It returns { passed, score, feedback }.
//   - The pass gate is a configurable threshold (default 0.8): a step passes
//     only when score >= threshold AND the judge set passed=true. The two are
//     ANDed so neither a generous boolean nor a high score alone can pass a
//     step the other disagrees with. Calibration via few-shot examples is a
//     future step (see the threshold comment below).
//   - `persistVerdict` writes the verdict via PlanStore.updateStep (status
//     passed/failed + verdict + incremented attempts). It is exposed so M2d can
//     call it from the live loop; nothing here invokes it on a live path.
//
// Model: defaults to the same model the Planner / Dispatcher use
// (client.provider.defaultTriageModel) but is an init parameter so evaluation
// quality can be tuned independently. A stronger model is a strong candidate
// here: judging is the quality-critical call in the loop, and a sharper grader
// catches flattered self-reports a cheap model would wave through.

import Foundation

// MARK: - Observation

/// A compact, gradable snapshot of what a Claude Code session actually did
/// for one plan step, distilled from the raw event stream into the slice the
/// Evaluator grades on. Plain value type so it is trivially unit-testable and
/// carries no engine wiring.
///
/// The fields are ordered by how much the judge should trust them: the tool
/// commands, their results, the errors, and the file changes are GROUND TRUTH;
/// `assistantText` is the session's own CLAIM and is graded skeptically, never
/// taken as proof.
public struct Observation: Sendable, Equatable {

    /// One Bash command the session ran in the step window, paired with the
    /// ground-truth result of running it. This is the spine of the evidence:
    /// what the session tried, and what actually happened when it did.
    public struct CommandRun: Sendable, Equatable {
        /// The command as issued (e.g. "swift build", "swift test --filter X").
        public var command: String
        /// A short human description the tool call carried, if any.
        public var description: String?
        /// The command's combined output (stdout/stderr), as captured. May be
        /// truncated by the builder to keep the observation cheap to grade.
        public var output: String
        /// Whether the tool result was flagged an error (non-zero exit / failure).
        public var isError: Bool

        public init(command: String, description: String? = nil, output: String, isError: Bool) {
            self.command = command
            self.description = description
            self.output = output
            self.isError = isError
        }
    }

    /// A file the session changed in the step window. Ground truth that the
    /// step actually touched code (an empty list when the step claims an edit
    /// is a strong fail signal). Edit/Write tool events are not emitted by the
    /// observation pipeline yet (v0.1.0 emits Bash only); the builder fills this
    /// from whatever the event stream carries today and the field is ready for
    /// the live Edit/Write hookup in M2d.
    public struct FileChange: Sendable, Equatable {
        /// The path that changed, as reported.
        public var path: String
        /// "edit" | "write" | "create" | "delete" - the kind of change, free
        /// text since the source can vary (tool call, git status, diff).
        public var kind: String
        /// Optional unified-diff snippet or a one-line summary of the change.
        public var summary: String?

        public init(path: String, kind: String, summary: String? = nil) {
            self.path = path
            self.kind = kind
            self.summary = summary
        }
    }

    /// The step the loop injected, echoed onto the observation so the snapshot
    /// is self-contained for logging/tests. The Evaluator grades against the
    /// PlanStep passed to `evaluate`, not this; this is a convenience label.
    public var stepTitle: String

    /// The session's assistant prose in the window. This is the session's
    /// self-report / CLAIM of what it did. It is the LEAST trusted field: the
    /// judge reads it only to check the claim against the ground truth below,
    /// and is told explicitly to disregard any "it works / done / all green"
    /// assertion that the results do not back up.
    public var assistantText: String

    /// Every Bash command run in the window with its result. Ground truth.
    public var commands: [CommandRun]

    /// Files changed in the window. Ground truth that code actually moved.
    public var fileChanges: [FileChange]

    /// A distilled list of error lines / failure signals pulled from the
    /// command outputs (compile errors, failed assertions, non-zero exits).
    /// Surfaced separately so the judge does not have to re-derive them from
    /// the raw output, and so a step that produced ANY error is hard to pass.
    public var errors: [String]

    public init(
        stepTitle: String = "",
        assistantText: String = "",
        commands: [CommandRun] = [],
        fileChanges: [FileChange] = [],
        errors: [String] = []
    ) {
        self.stepTitle = stepTitle
        self.assistantText = assistantText
        self.commands = commands
        self.fileChanges = fileChanges
        self.errors = errors
    }

    /// True when there is no ground-truth evidence of work at all - no commands
    /// ran and no files changed. An "empty" observation cannot satisfy a
    /// build/test rubric no matter what the assistant text claims; the prompt
    /// leans on this and the Evaluator notes it in the trace.
    public var hasNoGroundTruth: Bool {
        commands.isEmpty && fileChanges.isEmpty
    }
}

// MARK: - ObservationBuilder

/// Translates the existing session-event representation into an `Observation`.
///
/// Pure function over an EXPLICIT input array of `SupervisorEvent` (the real
/// observation-pipeline type) so it is unit-testable with a canned event list
/// and has no dependency on the live bus. The engine, in M2d, will assemble the
/// "events since this step was injected" window and hand it here; this builder
/// only knows how to distill a window it is given.
public enum ObservationBuilder {

    /// Per-command and total output caps so a noisy step (a huge test log)
    /// cannot blow the judge's context. Truncation keeps the HEAD and TAIL of
    /// the output, where build/test verdicts and the final error live.
    public static let maxOutputPerCommand = 4000
    public static let maxTotalOutput = 16000

    /// Build an `Observation` from an explicit, already-windowed event array.
    ///
    /// - `events`: the session events that occurred in the step window, in
    ///   order. Bash calls are paired with their results by `toolUseId`;
    ///   assistant text is concatenated; error signals are distilled from
    ///   error-flagged results and from compiler/test markers in any output.
    /// - `stepTitle`: optional label echoed onto the observation.
    ///
    /// Edit/Write tool events are not emitted by the pipeline yet (the parser
    /// ignores non-Bash tool calls as of v0.1.0), so `fileChanges` is empty
    /// from a pure-Bash event window today.
    // M2d: when Edit/Write tool-call events land in SupervisorEvent (and the
    // engine assembles the live "events since step start" window), extend this
    // to populate `fileChanges` from them and call it from the live loop. The
    // pure signature below stays the same; only new event cases get mapped.
    public static func build(from events: [SupervisorEvent], stepTitle: String = "") -> Observation {
        var assistantChunks: [String] = []
        var commands: [Observation.CommandRun] = []
        var errors: [String] = []

        // Pair Bash calls with their results by tool-use id. Results can arrive
        // after their call in the stream, so index the results first.
        var resultsByToolUse: [String: BashToolResultInfo] = [:]
        for event in events {
            if case let .bashToolResult(info) = event {
                resultsByToolUse[info.toolUseId] = info
            }
        }

        var totalOutput = 0
        for event in events {
            switch event {
            case .assistantText(let info):
                let t = info.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { assistantChunks.append(t) }

            case .bashToolCall(let call):
                let result = resultsByToolUse[call.toolUseId]
                var output = result?.output ?? ""
                let budget = max(0, min(Self.maxOutputPerCommand, Self.maxTotalOutput - totalOutput))
                output = Self.truncateOutput(output, limit: budget)
                totalOutput += output.utf8.count
                let isError = result?.isError ?? false
                commands.append(Observation.CommandRun(
                    command: call.command,
                    description: call.description,
                    output: output,
                    isError: isError
                ))
                // Distill error signals: an error-flagged result, plus any
                // lines in the output that look like a compile/test failure.
                if isError {
                    errors.append("command failed: \(call.command.prefix(160))")
                }
                errors.append(contentsOf: Self.errorLines(in: output))

            default:
                // sessionStart / userPrompt / bashToolResult (already indexed) /
                // systemSignal carry no gradable ground truth for a step.
                continue
            }
        }

        // De-duplicate error lines while preserving order; cap the count so a
        // pathological log cannot flood the verdict prompt.
        var seen = Set<String>()
        let dedupedErrors = errors.filter { seen.insert($0).inserted }.prefix(40)

        return Observation(
            stepTitle: stepTitle,
            assistantText: assistantChunks.joined(separator: "\n\n"),
            commands: commands,
            fileChanges: [],
            errors: Array(dedupedErrors)
        )
    }

    /// Keep the head and tail of an oversized output around the elided middle,
    /// where build/test summaries and the final error live. A negative or zero
    /// limit yields an empty string (the budget is already spent).
    static func truncateOutput(_ output: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard output.utf8.count > limit else { return output }
        let head = String(output.prefix(limit * 2 / 3))
        let tail = String(output.suffix(limit / 3))
        return head + "\n...[output truncated]...\n" + tail
    }

    /// Heuristic distillation of failure lines from a command's output. Matches
    /// common compiler / test-runner failure markers (case-insensitive). This
    /// is a CONVENIENCE for the judge, not the verdict: the judge still reads
    /// the full (truncated) output. Conservative on purpose - a missed marker
    /// just means the judge reads it in the raw output instead.
    static func errorLines(in output: String) -> [String] {
        guard !output.isEmpty else { return [] }
        let markers = [
            "error:", "fatal error", "failed", "failure", "exception",
            "assertionfailure", "xctassert", "test suite", "cannot find",
            "no such", "undefined", "panic", "traceback", "compilation failed",
        ]
        var hits: [String] = []
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                hits.append(String(line.prefix(200)))
            }
            if hits.count >= 20 { break }
        }
        return hits
    }
}

// MARK: - Evaluating protocol

/// Protocol for the engine-facing Evaluator surface. Concrete impl is
/// `Evaluator`; tests inject a mock returning a canned verdict. Mirrors
/// `Planning` / `Dispatching`.
public protocol Evaluating: Sendable {
    /// Grade a step's observed output against its rubric. Never throws - a
    /// transport or parse failure degrades to a conservative fail verdict so a
    /// broken judge call can never falsely pass a step.
    func evaluate(step: PlanStep, observation: Observation) async -> PlanStep.Verdict
}

// MARK: - The Evaluator

public final class Evaluator: Evaluating, Sendable {

    private let client: LLMClient
    private let model: String
    private let store: PlanStore?
    private let threshold: Double
    private let trace: TraceLog

    /// Default pass threshold. A step passes only when the judge's score is at
    /// least this AND the judge set passed=true. 0.8 is a deliberately strict
    /// default: in a skeptical evaluator we would rather redirect-and-retry a
    /// borderline step than advance on a soft pass.
    //
    // Calibration note: this single scalar is the v1 knob. The next step is
    // few-shot calibration - seed the judge with a handful of labeled
    // (observation, correct verdict) pairs so the score distribution is
    // anchored, then tune this threshold against that, the same way the triage
    // prompt was calibrated. Until then it is a tunable constant.
    public static let defaultThreshold = 0.8

    /// - `client`: the shared LLM client (redaction + provider are inherited).
    /// - `store`: optional PlanStore; required only for `persistVerdict`. The
    ///   Evaluator can grade without a store (pure `evaluate`), which keeps it
    ///   usable in tests and lets M2d own when persistence happens.
    /// - `model`: defaults to `client.provider.defaultTriageModel` (same as the
    ///   Planner/Dispatcher) but is injectable so a stronger grader can be used
    ///   without changing the other calls.
    /// - `threshold`: the pass gate; defaults to `defaultThreshold` (0.8).
    public init(
        client: LLMClient,
        store: PlanStore? = nil,
        model: String? = nil,
        threshold: Double = Evaluator.defaultThreshold,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.store = store
        self.model = model ?? client.provider.defaultTriageModel
        self.threshold = threshold
        self.trace = trace
    }

    /// The configured pass threshold (exposed so callers / tests can read the
    /// gate the verdict was decided against).
    public var passThreshold: Double { threshold }

    // MARK: - Grade

    public func evaluate(step: PlanStep, observation: Observation) async -> PlanStep.Verdict {
        let req = AnthropicMessageRequest(
            model: model,
            max_tokens: 1024,
            system: Self.systemPrompt,
            messages: [
                .init(role: "user", content: .string(Self.userMessage(step: step, observation: observation)))
            ],
            tools: [Self.recordVerdictTool],
            tool_choice: .forced(Self.recordVerdictToolName)
        )

        trace.emit("eval", "evaluate started step=\(step.id) title=\(step.title.prefix(48)) model=\(model) commands=\(observation.commands.count) errors=\(observation.errors.count) noGroundTruth=\(observation.hasNoGroundTruth)")

        let resp: AnthropicMessageResponse
        do {
            resp = try await client.createMessage(req)
        } catch {
            // A judge that cannot be reached must NOT pass a step. Degrade to a
            // conservative fail so the loop redirects rather than advancing on
            // an unverified step.
            trace.emit("eval", "ERROR evaluate call failed step=\(step.id): \(error)")
            return PlanStep.Verdict(
                passed: false,
                score: 0,
                feedback: "Could not evaluate this step (judge call failed: \(error)). Treating as not done; re-attempt and ensure the done-criteria are met."
            )
        }

        trace.emit("eval", "evaluate returned model=\(resp.model) input=\(resp.usage.input_tokens) output=\(resp.usage.output_tokens) stop_reason=\(resp.stop_reason ?? "(nil)")")

        guard let raw = Self.parseVerdict(from: resp) else {
            let contentSummary = resp.content.map { "\($0.type):\($0.name ?? "-")" }.joined(separator: ", ")
            trace.emit("eval", "ERROR parse failed step=\(step.id) content=[\(contentSummary)]; degrading to fail")
            return PlanStep.Verdict(
                passed: false,
                score: 0,
                feedback: "Could not parse the evaluation result; treating the step as not done. Re-attempt and meet the done-criteria explicitly."
            )
        }

        // The gate: clamp the score, then require BOTH the judge's boolean and
        // score >= threshold. ANDing them means neither a generous boolean nor
        // a high score alone can pass a step the other disagrees with.
        let score = min(1.0, max(0.0, raw.score))
        let passed = raw.passed && score >= threshold
        let verdict = PlanStep.Verdict(passed: passed, score: score, feedback: raw.feedback)

        trace.emit("eval", "verdict step=\(step.id) passed=\(passed) score=\(String(format: "%.2f", score)) threshold=\(String(format: "%.2f", threshold)) judgeBool=\(raw.passed) feedback=\(raw.feedback.prefix(120))")
        return verdict
    }

    // MARK: - Persist (exposed for M2d; not invoked from any live path here)

    /// Persist a verdict for a step: write status (passed/failed), the verdict,
    /// and the incremented attempt count via PlanStore.updateStep. Exposed so
    /// the M2d loop can call it after `evaluate`; nothing in this milestone
    /// invokes it on a live code path. Requires a store (set at init); throws if
    /// no store was provided.
    ///
    /// - `step`: the step that was graded (its current `attempts` is the base).
    /// - `verdict`: the verdict from `evaluate`.
    /// - Returns the new attempt count written.
    @discardableResult
    public func persistVerdict(step: PlanStep, verdict: PlanStep.Verdict, now: Date = Date()) throws -> Int {
        guard let store else {
            throw EvaluatorError.noStore
        }
        let newAttempts = step.attempts + 1
        let status: PlanStep.Status = verdict.passed ? .passed : .failed
        try store.updateStep(
            stepId: step.id,
            status: status,
            attempts: newAttempts,
            verdict: verdict,
            now: now
        )
        trace.emit("eval", "persisted verdict step=\(step.id) status=\(status.rawValue) attempts=\(newAttempts) passed=\(verdict.passed)")
        return newAttempts
    }

    public enum EvaluatorError: Error, Sendable {
        /// `persistVerdict` was called on an Evaluator built without a store.
        case noStore
    }

    // MARK: - Prompts

    static let systemPrompt: String = """
    You are Supervisor's Evaluator: a strict, skeptical external judge in a
    Planner/Generator/Evaluator loop. A live Claude Code session (the Generator)
    was given ONE plan step and worked it. Your job is to decide, from the REAL
    output of that session, whether the step's done-criteria are met - and to
    give feedback specific enough to redirect the session if they are not.

    THE CARDINAL RULE: grade ONLY on observed ground truth, NEVER on the
    session's own claim that it succeeded. Generators routinely flatter their
    own work - they say "Done", "fully implemented", "all tests pass", "the
    build is green" even when no test ran, the build is red, or no file changed.
    Treat the assistant's prose as a CLAIM to verify, not as evidence. If the
    claim is not backed by the commands, their results, the errors, and the file
    changes, the claim is worth nothing. Judge externally.

    How to grade:
      - Read the done-criteria. They are the ONLY rubric. Do not grade against
        your own idea of "good"; grade against what the step says "done" means.
      - Check each criterion against the GROUND TRUTH: the commands that ran and
        their results, the error lines, and the files that changed. A criterion
        like "the new test passes and swift build is green" is met ONLY if you
        can see a build/test command that actually ran AND succeeded (no error
        flag, no failure in its output). If you cannot see it happen, it is NOT
        met - absence of evidence is a FAIL, not a pass on trust.
      - If there is NO ground truth at all (no commands ran, no files changed),
        the step is not done - score it low no matter how confident the prose.
      - Any compile error, failed assertion, or non-zero exit that bears on a
        criterion means that criterion is unmet.

    Scoring:
      - score is 0.0 to 1.0: the fraction of the done-criteria actually met,
        weighted by how load-bearing each is. 1.0 = every criterion verifiably
        met on the ground truth. 0.0 = nothing met / no evidence of work.
      - passed is your boolean call of whether the step is genuinely complete.
        Be conservative: when the evidence is partial or ambiguous, passed=false
        and score reflects the partial credit. Supervisor applies its own
        threshold on top of your score, so do not inflate to "help it across".

    Feedback (this is injected back into the session as a redirect, so make it
    count):
      - Be SPECIFIC and ACTIONABLE. Name exactly which criterion is unmet and
        what the ground truth shows instead (e.g. "swift build failed:
        'cannot find type Foo in scope' in Bar.swift - the new type is not
        declared; declare it and re-run the build" ). Quote the real error.
      - On a pass, say briefly what evidence satisfied the criteria.
      - NEVER write vague feedback like "make it better", "improve quality", or
        "looks good" - that cannot redirect anything. Point at the gap.

    Call `record_verdict` exactly once with passed, score, and feedback.
    """

    /// The user message: the step's objective + done-criteria, then the
    /// observed ground truth, with the assistant's self-report fenced off as a
    /// CLAIM. Ordered so the rubric and the ground truth dominate and the
    /// self-report is visibly the least-trusted section.
    static func userMessage(step: PlanStep, observation: Observation) -> String {
        var lines: [String] = []

        lines.append("# The plan step being graded")
        lines.append("title: \(step.title)")
        lines.append("")
        lines.append("## What the step asked the session to do (objective)")
        lines.append(step.objective.isEmpty ? "(no objective text)" : step.objective)
        lines.append("")
        lines.append("## DONE-CRITERIA - the ONLY rubric; grade against THESE")
        lines.append(step.doneCriteria.isEmpty ? "(no done-criteria provided)" : step.doneCriteria)
        lines.append("")

        lines.append("# OBSERVED GROUND TRUTH (what actually happened - grade on THIS)")
        lines.append("")

        lines.append("## Commands the session ran, with their real results")
        if observation.commands.isEmpty {
            lines.append("(no commands ran - there is no execution evidence the work was done or verified)")
        } else {
            for (i, c) in observation.commands.enumerated() {
                lines.append("### Command \(i + 1)\(c.isError ? "  [RESULT: ERROR]" : "  [RESULT: ok]")")
                lines.append("$ \(c.command)")
                if let d = c.description, !d.isEmpty { lines.append("(\(d))") }
                lines.append("output:")
                lines.append(c.output.isEmpty ? "(no output captured)" : c.output)
                lines.append("")
            }
        }
        lines.append("")

        lines.append("## Files the session changed")
        if observation.fileChanges.isEmpty {
            lines.append("(no file changes observed)")
        } else {
            for f in observation.fileChanges {
                let s = (f.summary?.isEmpty == false) ? " - \(f.summary!)" : ""
                lines.append("- [\(f.kind)] \(f.path)\(s)")
            }
        }
        lines.append("")

        lines.append("## Distilled error / failure signals from the output")
        if observation.errors.isEmpty {
            lines.append("(none detected - still confirm success from the command results above, do not assume)")
        } else {
            for e in observation.errors { lines.append("- \(e)") }
        }
        lines.append("")

        lines.append("# The session's OWN CLAIM (a self-report - DO NOT trust; verify against the ground truth above)")
        lines.append("")
        lines.append(observation.assistantText.isEmpty
            ? "(the session said nothing - grade purely on the ground truth above)"
            : observation.assistantText)
        lines.append("")

        lines.append("# Task")
        lines.append("Grade the step ONLY against its done-criteria, using ONLY the observed ground truth. Explicitly DISREGARD any claim of success above that the commands, results, errors, and file changes do not back up. Give specific, actionable feedback naming the unmet criterion and the real evidence. Call `record_verdict` exactly once.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Tool schema

    static let recordVerdictToolName = "record_verdict"

    /// `record_verdict` - forced tool call, same SHAPE as record_plan /
    /// record_answer: one structured object { passed, score, feedback }.
    static var recordVerdictTool: AnthropicTool {
        AnthropicTool(
            name: recordVerdictToolName,
            description: "Record the evaluation verdict for the plan step, graded on observed ground truth against the step's done-criteria.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "passed": .object([
                        "type": .string("boolean"),
                        "description": .string("True only if the step's done-criteria are genuinely met on the observed ground truth. Be conservative; do not pass on the session's self-report.")
                    ]),
                    "score": .object([
                        "type": .string("number"),
                        "description": .string("0.0 to 1.0: the fraction of the done-criteria verifiably met on the ground truth. 1.0 = all met; 0.0 = none / no evidence of work.")
                    ]),
                    "feedback": .object([
                        "type": .string("string"),
                        "description": .string("Specific, actionable. Name the unmet criterion and quote the real evidence (e.g. the actual build error). Suitable to inject back as a redirect. Never vague.")
                    ]),
                ]),
                "required": .array([.string("passed"), .string("score"), .string("feedback")])
            ])
        )
    }

    // MARK: - Parser

    /// The raw judge output before the threshold gate is applied. `passed` here
    /// is the judge's own boolean; the Evaluator ANDs it with score>=threshold.
    struct RawVerdict: Sendable, Equatable {
        let passed: Bool
        let score: Double
        let feedback: String
    }

    /// Decode the record_verdict tool call. Returns nil if the response carries
    /// no usable record_verdict call (the Evaluator then degrades to a fail).
    /// The score arrives as JSON; it may decode as a double (0.45) or, for a
    /// whole value, an integer (1 or 0) - both are accepted.
    static func parseVerdict(from response: AnthropicMessageResponse) -> RawVerdict? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == recordVerdictToolName,
                  case let .object(input)? = block.input
            else { continue }

            guard case let .bool(passed)? = input["passed"] else { return nil }
            guard let score = doubleValue(input["score"]) else { return nil }
            let feedback: String
            if case let .string(f)? = input["feedback"] {
                feedback = f
            } else {
                feedback = ""
            }
            return RawVerdict(passed: passed, score: score, feedback: feedback)
        }
        return nil
    }

    /// Read a JSON number that may be encoded as a double, an integer, or a
    /// numeric string (some OpenAI-compat providers stringify numbers).
    static func doubleValue(_ json: AnthropicJSON?) -> Double? {
        switch json {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
