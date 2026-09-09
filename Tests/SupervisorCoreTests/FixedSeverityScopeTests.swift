// FixedSeverityScopeTests.swift
//
// A severity-grading rule in the SHARED preamble is read by every category,
// including the ones whose own rubric fixes their severity outright. Four do:
// `user_question_pending`, `worker_idle_post_completion`, `wrong_trajectory`
// and `self_extension_needed` are ALWAYS medium. Only two are graded,
// `destructive_action_pending` and `edits_outside_worktree`, and both already
// carry the grading rule in their own bodies.
//
// The leak is not cosmetic. `RemoteNotifyPolicy` delivers a `.notifyOnly`
// outcome to the owner's phone only at `.high`, so an idle observation whose
// reasoning happens to say "production" gets graded HIGH by a preamble rule
// and pages him for a category designed never to page. The counterfactual is
// asserted here rather than described, because the whole point of the fix is
// that the medium is what reaches the pager.
//
// This is the same failure mode the 2026-09-07 sweep caught once already: a
// nine-line severity block in the shared preamble cost
// `prompt_injection_signature` four positives with its own rubric untouched.
//
// Offline by construction. These assert what the model is TOLD, never what it
// answers, so they run in `swift test` with no API key and no sweep budget.
// The live corpus in `CalibrationFixtures/` is bash-command shaped
// (`targetCategory` + `bashCommand`) and gated behind `SUPERVISOR_LIVE_API`;
// neither of these two categories fires from a bash command at all, so a
// fixture there could not express this case even with budget.

import XCTest
@testable import SupervisorCore

final class FixedSeverityScopeTests: XCTestCase {

    // MARK: - Fixtures

    /// The words the removed preamble paragraph promoted to HIGH.
    private static let triggerWords = ["permanently", "cannot be recovered", "production"]

    /// Directives that grade severity. None of these may appear anywhere
    /// except inside a graded category's own rubric body.
    private static let gradingDirectives = [
        "MEDIUM is the default tier",
        "the severity is HIGH",
        "Rate HIGH",
    ]

    /// A `worker_idle_post_completion` observation carrying all three trigger
    /// words. Nothing about it is destructive: the worker stopped and said so.
    private static let idleReasoning = """
        Worker said "shipped to production" 22 seconds ago and no new events have arrived since. \
        The release it just cut cannot be recovered by re-running the build, and the tag is \
        permanently on the remote.
        """

    /// A `user_question_pending` observation carrying all three trigger words.
    /// Claude Code is stopped waiting for an answer; it has done nothing.
    private static let questionReasoning = """
        Claude Code is asking whether to point the migration at production. It says the old rows \
        cannot be recovered once it runs, so it stopped and is permanently waiting on you.
        """

    private func decision(
        category: String,
        severity: FlagSeverity,
        reasoningPlain: String
    ) -> TriageDecision {
        TriageDecision(
            sessionId: "sess-fixed-severity",
            cwd: "/Users/test/work/repo",
            candidate: TriageCandidate(
                category: category,
                severity: severity,
                matchedCommand: "stop_reason: end_turn",
                action: .notify,
                reasoningPlain: reasoningPlain,
                reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "sess-fixed-severity",
                command: "stop_reason: end_turn",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku",
            prePost: .alreadyExecuted
        )
    }

    private func assertNoGradingDirective(
        in prompt: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for directive in Self.gradingDirectives {
            XCTAssertFalse(
                prompt.contains(directive),
                "the \(path) path's prompt carries only categories that fix their own severity, so a grading directive (\"\(directive)\") in it can only contradict them",
                file: file,
                line: line
            )
        }
    }

    // MARK: - The preamble itself

    /// The preamble is what every path shares, so it is the one place a
    /// severity rule reaches a category it was never calibrated on. It states
    /// where the rating comes from and stops there.
    func testSharedPreambleGradesNothingItself() {
        let preamble = TriagePrompt.systemPrompt(categoriesMarkdown: "")

        assertNoGradingDirective(in: preamble, path: "shared preamble")
        for word in Self.triggerWords {
            XCTAssertFalse(
                preamble.contains(word),
                "\"\(word)\" in the shared preamble is a severity trigger for every category at once, which is the leak"
            )
        }
        XCTAssertTrue(
            preamble.contains("Severity is rated, never used to decide whether to fire"),
            "the one category-agnostic thing about severity has to survive: it is true of graded and fixed categories alike"
        )
        XCTAssertTrue(
            preamble.contains("when a category fixes its severity, the fixed value IS the severity"),
            "the preamble must point at the category's own rule, or the model has nowhere to read the rating from"
        )
    }

    // MARK: - worker_idle_post_completion

    /// The reported leak, as the pipeline would actually run it: the idle path
    /// sends `worker_idle_post_completion` and nothing else, that body fixes
    /// medium, and no rule the model can see raises it off medium no matter
    /// what its own reasoning says.
    func testIdleObservationNamingProductionStaysMedium() {
        XCTAssertTrue(
            Self.triggerWords.allSatisfy { Self.idleReasoning.contains($0) },
            "precondition: the fixture has to carry the trigger words or it tests nothing"
        )
        XCTAssertTrue(
            HardcodedRubric.workerIdlePostCompletion.body.contains("ALWAYS medium"),
            "worker_idle_post_completion fixes its severity; if that ever changes this whole test is the wrong shape"
        )

        let prompt = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.idleCategoriesMarkdown
        )
        assertNoGradingDirective(in: prompt, path: "idle")
        for word in Self.triggerWords {
            XCTAssertFalse(
                prompt.contains(word),
                "the idle path's prompt names \"\(word)\", so an idle reasoning containing it has a rule to match against"
            )
        }
    }

    /// Why the medium matters. `.notifyOnly` at medium stays on the Mac; the
    /// same outcome at high wakes the owner's phone. The second assertion is
    /// the counterfactual: it is the page the leak was sending.
    func testMediumIdleFlagDoesNotPageTheOwnerButAHighOneWould() {
        let stayed = RemoteNotifyPolicy.verdict(
            decision: decision(
                category: "worker_idle_post_completion",
                severity: .medium,
                reasoningPlain: Self.idleReasoning
            ),
            outcome: .notifyOnly
        )
        XCTAssertEqual(
            stayed, .skip(reason: "medium_severity_notify"),
            "an idle worker is not a reason to buzz a phone; the category was designed never to page"
        )

        let leaked = RemoteNotifyPolicy.verdict(
            decision: decision(
                category: "worker_idle_post_completion",
                severity: .high,
                reasoningPlain: Self.idleReasoning
            ),
            outcome: .notifyOnly
        )
        XCTAssertEqual(
            leaked, .deliver(reason: "high_severity_flag"),
            "this is the cost of the leak, pinned so nobody has to re-derive it: one word in the reasoning and the same observation pages him"
        )
    }

    // MARK: - user_question_pending

    /// Same shape on the assistant-text path. Both categories it carries
    /// (`user_question_pending`, `wrong_trajectory`) fix medium, so this path
    /// has no graded category at all.
    func testPendingQuestionNamingProductionStaysMedium() {
        XCTAssertTrue(
            Self.triggerWords.allSatisfy { Self.questionReasoning.contains($0) },
            "precondition: the fixture has to carry the trigger words or it tests nothing"
        )
        XCTAssertTrue(
            HardcodedRubric.userQuestionPending.body.contains("ALWAYS medium"),
            "user_question_pending fixes its severity"
        )
        XCTAssertTrue(
            HardcodedRubric.wrongTrajectory.body.contains("Severity: ALWAYS medium"),
            "the other category on this path fixes its severity too, which is why the path needs no grading rule"
        )

        let prompt = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.assistantTextCategoriesMarkdown
        )
        assertNoGradingDirective(in: prompt, path: "assistant-text")
        // "production" survives on this path as an example of a question worth
        // flagging ("Should I deploy to production?"), which is exactly why the
        // absence of a rule keyed to the word is what gets asserted, not the
        // absence of the word.
        for word in ["permanently", "cannot be recovered"] {
            XCTAssertFalse(
                prompt.contains(word),
                "the assistant-text path's prompt names \"\(word)\", so a pending-question reasoning containing it has a rule to match against"
            )
        }
    }

    func testMediumQuestionFlagDoesNotPageTheOwnerButAHighOneWould() {
        let stayed = RemoteNotifyPolicy.verdict(
            decision: decision(
                category: "user_question_pending",
                severity: .medium,
                reasoningPlain: Self.questionReasoning
            ),
            outcome: .notifyOnly
        )
        XCTAssertEqual(stayed, .skip(reason: "medium_severity_notify"))

        let leaked = RemoteNotifyPolicy.verdict(
            decision: decision(
                category: "user_question_pending",
                severity: .high,
                reasoningPlain: Self.questionReasoning
            ),
            outcome: .notifyOnly
        )
        XCTAssertEqual(leaked, .deliver(reason: "high_severity_flag"))
    }

    // MARK: - The graded categories keep the rule

    /// The other half of the fix: scoping the rule must not delete it. The
    /// bash path is the only one with graded categories, and it still carries
    /// every clause the preamble paragraph used to state, in the bodies where
    /// the sweep measured them.
    func testBashPathStillCarriesTheFullGradingRule() {
        let prompt = TriagePrompt.systemPrompt(
            categoriesMarkdown: HardcodedRubric.bashCategoriesMarkdown
        )

        // destructive_action_pending, with a superset of the preamble's
        // trigger words. This is the clause the 2026-09-07 sweep was aimed at.
        XCTAssertTrue(prompt.contains("The default tier is MEDIUM."))
        XCTAssertTrue(prompt.contains("Severity never decides WHETHER to"))
        XCTAssertTrue(prompt.contains("IRREVERSIBLE local loss"))
        XCTAssertTrue(prompt.contains("SHARED blast radius"))
        XCTAssertTrue(prompt.contains("ELEVATED privilege"))
        for word in Self.triggerWords {
            XCTAssertTrue(
                prompt.contains("\"\(word)\""),
                "destructive_action_pending's own consistency check must still name \"\(word)\" or the fix traded a leak for a regression"
            )
        }

        // edits_outside_worktree grades independently, and its HIGH tier is a
        // CLOSED list. The preamble paragraph said to rate HIGH on
        // irreversibility, which this category's own rule does not accept, so
        // the paragraph was overriding this one too, not only the fixed ones.
        XCTAssertTrue(prompt.contains("Severity rule — default tier is MEDIUM."))
        XCTAssertTrue(
            prompt.contains("Upgrade to HIGH only if:"),
            "the closed HIGH list is the whole rule for this category: a credentials path or a system path, nothing else"
        )
    }

    /// Structural guard, so the next person who adds a category does not have
    /// to know this history: any path whose categories ALL fix their severity
    /// must ship a prompt with no grading directive in it.
    func testNoPathOfFixedSeverityCategoriesShipsAGradingDirective() {
        let paths: [(String, [RubricCategory])] = [
            ("idle", HardcodedRubric.idleCategories),
            ("assistant-text", HardcodedRubric.assistantTextCategories),
            ("bash", HardcodedRubric.bashCategories),
        ]
        for (name, categories) in paths {
            let allFixed = categories.allSatisfy { $0.body.contains("ALWAYS medium") }
            guard allFixed else { continue }
            let markdown = categories
                .map { "## \($0.name)\n\n\($0.body)" }
                .joined(separator: "\n\n")
            assertNoGradingDirective(
                in: TriagePrompt.systemPrompt(categoriesMarkdown: markdown),
                path: name
            )
        }
    }
}
