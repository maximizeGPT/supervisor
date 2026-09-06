// BlockedSessionRepagerTests.swift
//
// The 45-minute re-page policy as a table: which flags count as blocked,
// what clears them (response, session movement, restart-after-kill,
// supersession, the 24h horizon), and the pure per-flag cadence decision.
// Everything here is a pure function over fixture rows; no timers, no DB.

import XCTest
@testable import SupervisorCore

final class BlockedSessionRepagerTests: XCTestCase {

    private typealias Repager = BlockedSessionRepager

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func flag(
        id: String = "f1",
        sessionId: String = "s1",
        ts: Date,
        outcome: InterventionOutcomeKind?,
        userResponse: FlagUserResponse? = nil
    ) -> StoredFlag {
        StoredFlag(
            id: id,
            sessionId: sessionId,
            ts: ts,
            category: "destructive_action_pending",
            severity: .high,
            action: .pause,
            reasoningPlain: "plain",
            reasoningTechnical: "technical",
            userResponse: userResponse,
            interventionOutcome: outcome
        )
    }

    private func session(
        id: String = "s1",
        cwd: String = "/Users/test/proj",
        startedAt: Date? = nil,
        lastSeenAt: Date
    ) -> StoredSession {
        StoredSession(
            id: id,
            projectHash: "-tmp",
            cwd: cwd,
            startedAt: startedAt ?? lastSeenAt.addingTimeInterval(-600),
            lastSeenAt: lastSeenAt,
            jsonlPath: "/tmp/x.jsonl"
        )
    }

    // MARK: - shouldRemind (the pure cadence decision)

    func testFirstReminderIsDueOneIntervalAfterTheBlock() {
        let blocked = t0
        XCTAssertFalse(Repager.shouldRemind(blockedSince: blocked, lastRemindedAt: nil, now: t0.addingTimeInterval(44 * 60)))
        XCTAssertTrue(Repager.shouldRemind(blockedSince: blocked, lastRemindedAt: nil, now: t0.addingTimeInterval(45 * 60)),
                      "the intervention channel already paged at t0; the reminder starts one interval later")
    }

    func testSubsequentRemindersAnchorOnTheLastReminder() {
        let blocked = t0
        let reminded = t0.addingTimeInterval(45 * 60)
        XCTAssertFalse(Repager.shouldRemind(blockedSince: blocked, lastRemindedAt: reminded, now: reminded.addingTimeInterval(44 * 60)))
        XCTAssertTrue(Repager.shouldRemind(blockedSince: blocked, lastRemindedAt: reminded, now: reminded.addingTimeInterval(45 * 60)))
    }

    // MARK: - scan: what counts as blocked

    func testEachBlockedOutcomeKindReminds() {
        let now = t0.addingTimeInterval(46 * 60)
        for outcome in Repager.blockedOutcomes {
            let reminders = Repager.scan(
                flags: [flag(ts: t0, outcome: outcome)],
                sessions: [session(lastSeenAt: t0)],
                lastReminded: [:],
                now: now
            )
            XCTAssertEqual(reminders.map(\.outcome), [outcome], "\(outcome) is blocked-on-owner")
        }
    }

    func testHandledOutcomesNeverRemind() {
        let now = t0.addingTimeInterval(46 * 60)
        for outcome in [InterventionOutcomeKind.notifyOnly, .injectSucceeded, .continueFired, .queued] {
            let reminders = Repager.scan(
                flags: [flag(ts: t0, outcome: outcome)],
                sessions: [session(lastSeenAt: t0)],
                lastReminded: [:],
                now: now
            )
            XCTAssertTrue(reminders.isEmpty, "\(outcome) is handled; nothing is waiting")
        }
        // No recorded outcome at all (old rows, tests) is not evidence of a block.
        XCTAssertTrue(Repager.scan(
            flags: [flag(ts: t0, outcome: nil)],
            sessions: [session(lastSeenAt: t0)],
            lastReminded: [:], now: now
        ).isEmpty)
    }

    // MARK: - scan: what clears a block

    func testOwnerResponseStopsReminders() {
        let now = t0.addingTimeInterval(46 * 60)
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .pauseSucceeded, userResponse: .rejected)],
            sessions: [session(lastSeenAt: t0)],
            lastReminded: [:],
            now: now
        )
        XCTAssertTrue(reminders.isEmpty, "an answered flag is a cleared block")
    }

    func testSessionMovementAfterTheFlagStopsReminders() {
        // The panel's Resume writes no user_response; the session moving
        // again is how a resume shows up in the durable record.
        let now = t0.addingTimeInterval(46 * 60)
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .pauseSucceeded)],
            sessions: [session(lastSeenAt: t0.addingTimeInterval(120))],
            lastReminded: [:],
            now: now
        )
        XCTAssertTrue(reminders.isEmpty, "events after the flag mean the session resumed")
    }

    func testActivitySlackDoesNotCountAsMovement() {
        // The intervention's own surrounding events land moments after the
        // flag row; that is not a resume.
        let now = t0.addingTimeInterval(46 * 60)
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .pauseSucceeded)],
            sessions: [session(lastSeenAt: t0.addingTimeInterval(10))],
            lastReminded: [:],
            now: now
        )
        XCTAssertEqual(reminders.count, 1)
    }

    func testRestartInTheSameCwdClearsAKill() {
        let now = t0.addingTimeInterval(46 * 60)
        let killed = session(id: "s1", cwd: "/Users/test/proj", lastSeenAt: t0)
        let fresh = session(id: "s2", cwd: "/Users/test/proj",
                            startedAt: t0.addingTimeInterval(600),
                            lastSeenAt: t0.addingTimeInterval(700))
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .killSucceeded)],
            sessions: [killed, fresh],
            lastReminded: [:],
            now: now
        )
        XCTAssertTrue(reminders.isEmpty, "the restart is the thing the reminder was asking for")
    }

    func testRestartInAnotherCwdDoesNotClearAKill() {
        let now = t0.addingTimeInterval(46 * 60)
        let killed = session(id: "s1", cwd: "/Users/test/proj", lastSeenAt: t0)
        let unrelated = session(id: "s2", cwd: "/Users/test/other",
                                startedAt: t0.addingTimeInterval(600),
                                lastSeenAt: t0.addingTimeInterval(700))
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .killSucceeded)],
            sessions: [killed, unrelated],
            lastReminded: [:],
            now: now
        )
        XCTAssertEqual(reminders.count, 1)
    }

    func testNewerBlockedFlagSupersedesOlderOnTheSameSession() {
        // A pause that later got killed reminds about the CURRENT state.
        let now = t0.addingTimeInterval(2 * 3600)
        let reminders = Repager.scan(
            flags: [
                flag(id: "f-pause", ts: t0, outcome: .pauseSucceeded),
                flag(id: "f-kill", ts: t0.addingTimeInterval(3600), outcome: .killSucceeded),
            ],
            sessions: [session(lastSeenAt: t0.addingTimeInterval(3600))],
            lastReminded: [:],
            now: now
        )
        XCTAssertEqual(reminders.map(\.flagId), ["f-kill"],
                       "one reminder per session, and it describes the newest block")
    }

    func testStaleFlagHorizonStopsReminders() {
        let now = t0.addingTimeInterval(Repager.staleFlagHorizon + 60)
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .pauseSucceeded)],
            sessions: [session(lastSeenAt: t0)],
            lastReminded: [:],
            now: now
        )
        XCTAssertTrue(reminders.isEmpty,
                      "an owner who ignored a full day of reminders has decided; stop nagging")
    }

    func testUnknownSessionRowFailsQuiet() {
        let now = t0.addingTimeInterval(46 * 60)
        let reminders = Repager.scan(
            flags: [flag(ts: t0, outcome: .pauseSucceeded)],
            sessions: [],
            lastReminded: [:],
            now: now
        )
        XCTAssertTrue(reminders.isEmpty,
                      "with no way to verify the block still stands, silence beats a wrong page")
    }

    func testLedgerHoldsTheCadenceAcrossPasses() {
        // Pass 1 at +46m reminds; pass 2 at +60m must not; pass 3 at +91m
        // (45m after the last reminder) must.
        let blockedFlag = flag(ts: t0, outcome: .pauseSucceeded)
        let sessions = [session(lastSeenAt: t0)]

        let pass1 = Repager.scan(flags: [blockedFlag], sessions: sessions, lastReminded: [:], now: t0.addingTimeInterval(46 * 60))
        XCTAssertEqual(pass1.count, 1)
        let ledger = [blockedFlag.id: t0.addingTimeInterval(46 * 60)]

        let pass2 = Repager.scan(flags: [blockedFlag], sessions: sessions, lastReminded: ledger, now: t0.addingTimeInterval(60 * 60))
        XCTAssertTrue(pass2.isEmpty)

        let pass3 = Repager.scan(flags: [blockedFlag], sessions: sessions, lastReminded: ledger, now: t0.addingTimeInterval(91 * 60))
        XCTAssertEqual(pass3.count, 1)
    }

    // MARK: - Copy

    func testReminderCopyIsMinimalAndDashless() {
        let reminder = Repager.Reminder(
            flagId: "f1", sessionId: "abcdef1234567890",
            outcome: .pauseSucceeded, blockedSince: t0
        )
        let (title, body) = Repager.message(for: reminder, now: t0.addingTimeInterval(47 * 60))
        XCTAssertEqual(title, "Supervisor is still waiting on you")
        XCTAssertTrue(body.contains("still paused"), body)
        XCTAssertTrue(body.contains("47m"), body)
        XCTAssertTrue(body.contains("abcdef12"), "8-char prefix identifies the session")
        XCTAssertFalse(body.contains("abcdef123"), "never the full session id")
        XCTAssertFalse(body.contains("\u{2014}"), "no em dashes in user-facing copy")
        XCTAssertFalse(body.contains("/Users"), "nothing path-shaped: \(body)")
    }

    func testDurationsReadAsHoursAndMinutes() {
        XCTAssertEqual(Repager.describeDuration(30), "1m")
        XCTAssertEqual(Repager.describeDuration(46 * 60), "46m")
        XCTAssertEqual(Repager.describeDuration(60 * 60), "1h")
        XCTAssertEqual(Repager.describeDuration(3 * 3600 + 12 * 60), "3h 12m")
    }
}
