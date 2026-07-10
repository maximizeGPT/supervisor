// ReviewPrompt.swift — v0.3.x REVIEW dimension.
//
// Builds the Anthropic request body for one code-review call and decodes the
// forced `record_review` tool output. Mirrors the TriagePrompt idiom (forced
// tool call, structured output, empty array = all-clear) so the LLMClient path,
// redaction, cost cap, and multi-provider translation are all inherited unchanged.
//
// The SYSTEM PROMPT is the primary noise control. Supervisor's whole posture is
// that an ignorable low-value nitpick is worse than silence, so the prompt sets a
// high bar, enumerates what is NOT a finding, and states plainly that an empty
// `findings` array is the correct and common answer. The confidence field lets
// the engine apply the owner's Decision Sensitivity dial as a second gate.

import Foundation

/// One decoded finding from a `record_review` call.
public struct ReviewFinding: Sendable, Equatable {
    /// Tight category vocabulary — the kinds of substantive problem worth a flag.
    public enum Category: String, Sendable, Equatable, CaseIterable {
        case incorrectAssumption = "incorrect_assumption"
        case missedEdgeCase = "missed_edge_case"
        case contradictsEarlierDecision = "contradicts_earlier_decision"
        case overlookedDetail = "overlooked_detail"
        case correctnessRisk = "correctness_risk"
        case securityRisk = "security_risk"
    }

    public let category: Category
    public let severity: FlagSeverity                    // low | medium | high (reuses the flag vocabulary)
    public let confidence: EngineeringAnswer.Confidence  // low | medium | high (drives the sensitivity gate)
    /// The file this finding is about (echoed back so a multi-file batch maps
    /// each finding to its file even when the model summarizes across them).
    public let filePath: String
    public let title: String                             // one plain sentence a busy owner can skim
    public let detail: String                            // the technical "why", and the failing case
    public let lineHint: String?                         // optional code/line reference

    public init(
        category: Category,
        severity: FlagSeverity,
        confidence: EngineeringAnswer.Confidence,
        filePath: String,
        title: String,
        detail: String,
        lineHint: String? = nil
    ) {
        self.category = category
        self.severity = severity
        self.confidence = confidence
        self.filePath = filePath
        self.title = title
        self.detail = detail
        self.lineHint = lineHint
    }
}

/// The context ReviewEngine assembles for one review call: the changes in a
/// single worker turn, plus enough session context to judge them.
public struct ReviewInput: Sendable {
    public let cwd: String?
    public let gitBranch: String?
    /// The task the owner set (most recent owner prompt), for judging whether the
    /// change actually does what was asked.
    public let objective: String?
    /// True when `objective` was written by the owner (vs. Supervisor-injected).
    public let objectiveFromOwner: Bool
    /// The worker's stated reasoning for this turn's changes (the assistant text
    /// in the same turn), so the reviewer can check the code against the intent.
    public let assistantReasoning: String?
    /// The edits under review — one worker turn's worth (batched by ReviewEngine).
    public let edits: [FileEditInfo]
    /// Compact one-liners of earlier changes/decisions this session, so the
    /// reviewer can catch a contradiction with an earlier decision.
    public let priorContext: [String]

    public init(
        cwd: String?,
        gitBranch: String?,
        objective: String?,
        objectiveFromOwner: Bool,
        assistantReasoning: String?,
        edits: [FileEditInfo],
        priorContext: [String]
    ) {
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.objective = objective
        self.objectiveFromOwner = objectiveFromOwner
        self.assistantReasoning = assistantReasoning
        self.edits = edits
        self.priorContext = priorContext
    }
}

public enum ReviewPrompt {

    public static let recordReviewToolName = "record_review"

    /// Overall prompt budget guard — cap the total edit text embedded so a batch
    /// of large writes can't blow the input. The per-hunk cap already applied at
    /// parse time (16 KB); this bounds the SUM across a turn's edits.
    static let totalEditCharCap = 24_000

    /// The reviewer system prompt. This bar is the feature: report only what a
    /// competent reviewer would stop and comment on because it is likely WRONG or
    /// MISSED — never mere preference. Empty `findings` is correct and common.
    public static let systemPrompt = """
    You are Supervisor's code reviewer. You watch a Claude Code session and review the code changes the worker just wrote, on the fly, while the work is in progress. Your job is to catch SUBSTANTIVE problems the worker may have missed, so the owner finds out now instead of later.

    Review the CHANGES UNDER REVIEW against the task the owner set, the worker's stated reasoning, and the earlier context from this session.

    Report a finding ONLY when it is one of these, and you are fairly sure it is real:
    - An incorrect assumption baked into the code (the change assumes something about inputs, types, state, or the environment that is not guaranteed).
    - An edge case the change overlooks (nil/empty/boundary/negative/overflow, an error path left unhandled, a concurrency or ordering hazard, an off-by-one).
    - A line that misses something important the task or surrounding code requires (a case not handled, a required call omitted, a condition inverted).
    - Logic that contradicts an earlier decision in THIS session (the owner's stated intent, or an earlier change shown in the prior context).
    - A change that looks correct but breaks an invariant, a security property, or the stated task.

    Do NOT report any of these — they are noise, and noise is worse than silence:
    - Style, formatting, naming, import order, or anything you would phrase as "consider", "might want to", "could be cleaner", or "nit".
    - Subjective preferences or alternative approaches that are not actually wrong.
    - Restating what the code does, praise, or a summary.
    - Missing tests, unless the absence hides a specific bug you can name.
    - Speculation you cannot ground in the actual changed lines shown below.
    - A problem the same change already handles elsewhere in the visible diff.
    - Documentation typos, date/version-string/changelog edits, comment wording, or formatting — these are never findings, even if a value looks wrong; they are not code the change breaks.

    The bar: only report an issue a competent engineer reviewing this diff would stop and comment on because it is likely WRONG or MISSED — not merely different from how they would have written it. If you are not fairly sure, do not report it. An empty `findings` array is the correct and common answer. Silence is better than a low-value nitpick.

    For every finding: name the specific file, state the specific problem in one plain sentence (the `title`), and in `detail` give the concrete failing input or condition and why it goes wrong. Ground it in the changed lines you were shown — do not invent code you cannot see.

    Grounding (a hard rule). Every finding MUST be about a line that literally appears in the CHANGES UNDER REVIEW. Put the exact changed line your finding is about in `line_hint`; if you cannot quote a real added or changed line that exhibits the problem, discard the finding. Never describe code that is not shown to you — a class, function, or caller you are imagining is not evidence. Before you conclude, enumerate every control-flow branch the change ADDS or ALTERS — each new switch/case, enum arm, or condition — and check whether the shown code actually handles it; a newly added case with no matching handler in the diff is exactly the kind of overlooked detail worth flagging.

    Safe as written = silence. If the change is correct given only what you can see, emit nothing. Do NOT flag best-practice preferences or hypothetical future misuse unless a concrete input in scope actually triggers a failure — for example a query string built only from internal constants or enum cases (not external input), a force-unwrap a guard right above makes safe, or an intentional tightening of validation. When the safety of a change depends on code you cannot see, do not claim a high-confidence bug: stay silent, or report it at low confidence as an open question. This abstention NEVER applies to a change that INTRODUCES a real security problem, secret/credential exposure, data loss, or an authentication/authorization gap — those are always worth flagging (e.g. writing a token/password/key into logs, or dropping an authz check the surrounding code enforces). The abstention covers style and speculative concerns, not a concrete harm the diff creates.

    Confidence: `high` = you can point to the exact changed line and the exact condition under which it fails. `medium` = the problem is likely but depends on code not shown. `low` = a hunch; report `low` ONLY when severity is `high` (a plausible serious bug worth a look). Severity: `high` = likely breakage, data loss, or a security hole; `medium` = a real bug in a narrower case; `low` = a genuine but minor correctness issue.

    You are reviewing an in-progress session — the worker may fix it in a later turn. Only report what is wrong AS WRITTEN and important enough to flag now. Call `record_review` exactly once.
    """

    /// JSON schema for the forced structured output.
    public static var recordReviewTool: AnthropicTool {
        AnthropicTool(
            name: recordReviewToolName,
            description: "Record the code-review verdict. Call exactly once. An empty `findings` array means no substantive issue — the correct and common answer.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "findings": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "category": .object([
                                    "type": .string("string"),
                                    "enum": .array(ReviewFinding.Category.allCases.map { .string($0.rawValue) })
                                ]),
                                "severity": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("low"), .string("medium"), .string("high")])
                                ]),
                                "confidence": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("high"), .string("medium"), .string("low")]),
                                    "description": .string("high = exact line + exact failing condition; medium = likely but depends on code not shown; low = a hunch (allowed ONLY when severity is high).")
                                ]),
                                "file_path": .object([
                                    "type": .string("string"),
                                    "description": .string("The file this finding is about (copy the path exactly as shown in the changes under review).")
                                ]),
                                "title": .object([
                                    "type": .string("string"),
                                    "description": .string("One plain sentence a busy owner can skim. Names the specific problem, not a category.")
                                ]),
                                "detail": .object([
                                    "type": .string("string"),
                                    "description": .string("The concrete failing input or condition and why the change is wrong under it. Grounded in the changed lines.")
                                ]),
                                "line_hint": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional. A short quote of the exact changed line/snippet the finding is about.")
                                ])
                            ]),
                            "required": .array([
                                .string("category"),
                                .string("severity"),
                                .string("confidence"),
                                .string("file_path"),
                                .string("title"),
                                .string("detail")
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("findings")])
            ])
        )
    }

    /// Build the review request for one turn's batch of edits.
    public static func buildRequest(model: String, input: ReviewInput) -> AnthropicMessageRequest {
        AnthropicMessageRequest(
            model: model,
            max_tokens: 1024,
            system: systemPrompt,
            messages: [.init(role: "user", content: .string(userMessage(input)))],
            tools: [recordReviewTool],
            tool_choice: .forced(recordReviewToolName)
        )
    }

    // MARK: - User message

    static func userMessage(_ input: ReviewInput) -> String {
        var s = ""
        if let cwd = input.cwd, !cwd.isEmpty {
            s += "# Session working directory\n\(cwd)\n\n"
        }
        if let branch = input.gitBranch, !branch.isEmpty {
            s += "# Git branch\n\(branch)\n\n"
        }
        if let objective = input.objective, !objective.isEmpty {
            let tag = input.objectiveFromOwner
                ? "(the owner asked for this)"
                : "(NOT the owner — Supervisor-injected; treat as background only)"
            s += "# What the worker is trying to do \(tag)\n\(objective.prefix(1200))\n\n"
        }
        if let reasoning = input.assistantReasoning, !reasoning.isEmpty {
            s += "# The worker's stated reasoning for this change\n\(reasoning.prefix(1500))\n\n"
        }
        if !input.priorContext.isEmpty {
            s += "# Earlier context this session (for catching contradictions; do not re-review these)\n"
            s += input.priorContext.suffix(20).joined(separator: "\n")
            s += "\n\n"
        }
        s += "# Changes under review\n"
        s += renderEdits(input.edits)
        s += "\nReview ONLY the changes under review above. Report substantive problems via `record_review`; an empty `findings` array is correct if there is nothing a competent reviewer would stop and flag."
        return s
    }

    /// Render a turn's edits as skimmable, diff-shaped blocks, bounded by
    /// `totalEditCharCap` so a batch of large writes can't blow the input.
    static func renderEdits(_ edits: [FileEditInfo]) -> String {
        var out = ""
        var budget = totalEditCharCap
        for edit in edits {
            guard budget > 0 else {
                out += "\n…[further edits omitted to fit the review budget]\n"
                break
            }
            for (i, hunk) in edit.hunks.enumerated() {
                var block = ""
                if let old = hunk.oldString {
                    // Edit / MultiEdit: an old→new replacement.
                    block += "--- \(edit.toolName) \(edit.filePath) (change \(i + 1) of \(edit.hunks.count)) ---\n"
                    block += "REMOVED:\n\(old)\n"
                    block += "ADDED:\n\(hunk.newString)\n"
                } else {
                    // Write: whole-file content.
                    block += "--- \(edit.toolName) \(edit.filePath) (new/overwritten content) ---\n"
                    block += "\(hunk.newString)\n"
                }
                if block.count > budget {
                    block = String(block.prefix(budget)) + " …[truncated]\n"
                }
                out += block + "\n"
                budget -= block.count
                if budget <= 0 { break }
            }
        }
        return out
    }
}
