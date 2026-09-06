// RemoteNotifyPolicyTests.swift
//
// The volume contract for the remote channel. These tests are the reason the
// policy is a pure function: "which events reach the owner's phone" is a
// product decision that should be readable as a table, not inferred from a
// chain of ifs inside a network call.
//
// Coverage:
//   - every InterventionOutcome case has an explicit expected verdict
//   - severity only matters on the notifyOnly path
//   - dedupe keys collapse repeats but not distinct categories/sessions

import XCTest
@testable import SupervisorCore

final class RemoteNotifyPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func decision(
        sessionId: String = "sess-1",
        severity: FlagSeverity = .high,
        category: String = "destructive_action_pending"
    ) -> TriageDecision {
        TriageDecision(
            sessionId: sessionId,
            cwd: "/Users/test/work/repo",
            candidate: TriageCandidate(
                category: category,
                severity: severity,
                matchedCommand: "rm -rf /Users/test/work/repo/build",
                action: .pause,
                reasoningPlain: "plain",
                reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: sessionId,
                command: "rm -rf /Users/test/work/repo/build",
                description: nil,
                toolUseId: "t1",
                turnUUID: "u1",
                ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku",
            prePost: .preExecution
        )
    }

    // MARK: - Deliver cases

    func testPauseDelivers() {
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(),
            outcome: .pauseSucceeded(pid: 42, recoveryDocPath: nil)
        )
        XCTAssertEqual(v, .deliver(reason: "worker_paused"))
    }

    func testKillDelivers() {
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(),
            outcome: .killSucceeded(recoveryDocPath: nil)
        )
        XCTAssertEqual(v, .deliver(reason: "worker_killed"))
    }

    func testProposedMediumDelivers() {
        // Propose-and-wait is a wait on the owner. If nobody sees it, the
        // proposal never gets approved and the session stalls forever.
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(category: "worker_idle_post_completion"),
            outcome: .continueProposedMedium(proposal: "do the thing", justification: "because", copiedToClipboard: false)
        )
        XCTAssertEqual(v, .deliver(reason: "awaiting_owner_approval"))
    }

    func testLowConfidenceDelivers() {
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(category: "worker_idle_post_completion"),
            outcome: .continueLowConfidence(reasoning: "no queue items")
        )
        XCTAssertEqual(v, .deliver(reason: "awaiting_owner_direction"))
    }

    func testInjectDegradedDelivers() {
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(category: "user_question_pending"),
            outcome: .injectDegraded(intendedText: "yes", reason: "no_hosting_app", copiedToClipboard: true)
        )
        XCTAssertEqual(v, .deliver(reason: "answer_needs_manual_paste"))
    }

    func testScreenRecordingDeniedDelivers() {
        // The plan is alive and waiting on one System Settings toggle only
        // the owner can flip. That is blocked-on-a-human by definition.
        let v = RemoteNotifyPolicy.verdict(
            decision: decision(category: "user_question_pending"),
            outcome: .screenRecordingDenied(intendedText: "yes", copiedToClipboard: true)
        )
        XCTAssertEqual(v, .deliver(reason: "screen_recording_permission_off"))
    }

    func testHighSeverityNotifyDelivers() {
        let v = RemoteNotifyPolicy.verdict(decision: decision(severity: .high), outcome: .notifyOnly)
        XCTAssertEqual(v, .deliver(reason: "high_severity_flag"))
    }

    // MARK: - Skip cases

    func testMediumSeverityNotifySkips() {
        let v = RemoteNotifyPolicy.verdict(decision: decision(severity: .medium), outcome: .notifyOnly)
        XCTAssertEqual(v, .skip(reason: "medium_severity_notify"))
    }

    func testLowSeverityNotifySkips() {
        let v = RemoteNotifyPolicy.verdict(decision: decision(severity: .low), outcome: .notifyOnly)
        XCTAssertEqual(v, .skip(reason: "low_severity_notify"))
    }

    func testInjectSucceededSkipsRegardlessOfSeverity() {
        // Supervisor answered the question. Nothing is blocked, so nothing
        // should buzz. Severity is irrelevant on a handled path.
        for severity in FlagSeverity.allCases {
            let v = RemoteNotifyPolicy.verdict(
                decision: decision(severity: severity),
                outcome: .injectSucceeded(pid: 7, bytes: 12)
            )
            XCTAssertEqual(v, .skip(reason: "handled_supervisor_answered"),
                           "severity \(severity.rawValue) must not make a handled inject page the owner")
        }
    }

    func testContinueFiredSkipsRegardlessOfSeverity() {
        for severity in FlagSeverity.allCases {
            let v = RemoteNotifyPolicy.verdict(
                decision: decision(severity: severity),
                outcome: .continueFired(pid: 7, bytes: 12, promptHead: "next task")
            )
            XCTAssertEqual(v, .skip(reason: "handled_supervisor_dispatched"),
                           "severity \(severity.rawValue) must not make a fired dispatch page the owner")
        }
    }

    func testQueuedSkipsBecauseTheHumanIsPresent() {
        // HumanActivityProbe deferred the delivery because a keystroke just
        // landed. Buzzing a phone in the owner's pocket while they type is
        // exactly the noise that gets the channel muted.
        for severity in FlagSeverity.allCases {
            let v = RemoteNotifyPolicy.verdict(
                decision: decision(severity: severity),
                outcome: .queued(promptHead: "next task")
            )
            XCTAssertEqual(v, .skip(reason: "handled_queued_human_present"))
        }
    }

    func testVerdictHelpers() {
        XCTAssertTrue(RemoteNotifyVerdict.deliver(reason: "x").isDeliver)
        XCTAssertFalse(RemoteNotifyVerdict.skip(reason: "y").isDeliver)
        XCTAssertEqual(RemoteNotifyVerdict.skip(reason: "y").reason, "y")
    }

    // MARK: - Dedupe keys

    func testDedupeKeyIgnoresPayloadDifferences() {
        // Two pauses of the same session for the same category collapse,
        // even though the recovery doc path differs between them.
        let a = RemoteNotifyPolicy.dedupeKey(
            decision: decision(),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        let b = RemoteNotifyPolicy.dedupeKey(
            decision: decision(),
            outcome: .pauseSucceeded(pid: 999, recoveryDocPath: URL(fileURLWithPath: "/tmp/doc.md"))
        )
        XCTAssertEqual(a, b)
    }

    func testDedupeKeySplitsOnCategory() {
        let a = RemoteNotifyPolicy.dedupeKey(
            decision: decision(category: "destructive_action_pending"),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        let b = RemoteNotifyPolicy.dedupeKey(
            decision: decision(category: "credential_exposure"),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        XCTAssertNotEqual(a, b, "a different category is a different problem and must not be collapsed")
    }

    func testDedupeKeySplitsOnSessionAndOutcome() {
        let base = RemoteNotifyPolicy.dedupeKey(
            decision: decision(sessionId: "a"),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        let otherSession = RemoteNotifyPolicy.dedupeKey(
            decision: decision(sessionId: "b"),
            outcome: .pauseSucceeded(pid: 1, recoveryDocPath: nil)
        )
        let otherOutcome = RemoteNotifyPolicy.dedupeKey(
            decision: decision(sessionId: "a"),
            outcome: .killSucceeded(recoveryDocPath: nil)
        )
        XCTAssertNotEqual(base, otherSession)
        XCTAssertNotEqual(base, otherOutcome)
    }

    func testOutcomeKindsAreStableAndDistinct() {
        // Every case of InterventionOutcome, so a new case added upstream
        // without a tag here shows up as a compile error in this array, not
        // as a silent collision inside a dedupe key.
        let kinds: [String] = [
            RemoteNotifyPolicy.outcomeKind(.notifyOnly),
            RemoteNotifyPolicy.outcomeKind(.pauseSucceeded(pid: 1, recoveryDocPath: nil)),
            RemoteNotifyPolicy.outcomeKind(.killSucceeded(recoveryDocPath: nil)),
            RemoteNotifyPolicy.outcomeKind(.injectSucceeded(pid: 1, bytes: 1)),
            RemoteNotifyPolicy.outcomeKind(.injectDegraded(intendedText: "x", reason: "y", copiedToClipboard: false)),
            RemoteNotifyPolicy.outcomeKind(.screenRecordingDenied(intendedText: "x", copiedToClipboard: false)),
            RemoteNotifyPolicy.outcomeKind(.continueFired(pid: 1, bytes: 1, promptHead: "h")),
            RemoteNotifyPolicy.outcomeKind(.continueProposedMedium(proposal: "p", justification: "j", copiedToClipboard: false)),
            RemoteNotifyPolicy.outcomeKind(.continueLowConfidence(reasoning: "r")),
            RemoteNotifyPolicy.outcomeKind(.queued(promptHead: "h")),
        ]
        XCTAssertEqual(Set(kinds).count, kinds.count, "outcome kinds must be distinct: \(kinds)")
        XCTAssertEqual(kinds.first, "notify")
        for kind in kinds {
            XCTAssertFalse(kind.contains(" "), "kind \(kind) must be a single token for the dedupe key and trace log")
        }
    }
}
