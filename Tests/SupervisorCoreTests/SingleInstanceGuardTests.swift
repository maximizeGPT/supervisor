// SingleInstanceGuardTests.swift
//
// Pins the run/quit decision that replaced the ping-pong guard:
//   - no pidfile               -> run
//   - live other incumbent     -> quit (newcomer bows out)
//   - dead/stale recorded pid  -> run (take over)
//   - my own pid recorded      -> run (re-claim)
// Tests the DECISION function only; never calls NSApp.terminate.

import XCTest
@testable import SupervisorCore

final class SingleInstanceGuardTests: XCTestCase {

    private let myPID: Int32 = 1000

    override func tearDown() {
        // A winning claim() keeps its flock fd open in a process-static so the
        // kernel holds the lock for the process lifetime. Release it between
        // tests so a held lock never leaks into the next test.
        SingleInstanceGuard.releaseHeldLockForCrashSimulation()
        super.tearDown()
    }

    func testNoPidfileMayRun() {
        let decision = SingleInstanceGuard.decide(
            recordedPID: nil,
            myPID: myPID,
            isAlive: { _ in XCTFail("liveness should not be probed when no pid recorded"); return false }
        )
        XCTAssertEqual(decision, .run)
    }

    func testLiveOtherIncumbentMustQuit() {
        let otherPID: Int32 = 2000
        let decision = SingleInstanceGuard.decide(
            recordedPID: otherPID,
            myPID: myPID,
            isAlive: { $0 == otherPID }   // the incumbent is alive
        )
        XCTAssertEqual(decision, .quit(incumbentPID: otherPID))
    }

    func testDeadRecordedPidMayRun() {
        let stalePID: Int32 = 2000
        let decision = SingleInstanceGuard.decide(
            recordedPID: stalePID,
            myPID: myPID,
            isAlive: { _ in false }   // recorded pid is dead -> stale lock
        )
        XCTAssertEqual(decision, .run)
    }

    func testMyOwnPidMayRun() {
        let decision = SingleInstanceGuard.decide(
            recordedPID: myPID,
            myPID: myPID,
            isAlive: { _ in XCTFail("liveness should not be probed for my own pid"); return true }
        )
        XCTAssertEqual(decision, .run)
    }

    // MARK: - Round-trip of the file helpers (read/write/release)

    func testWriteReadReleaseRoundTrip() throws {
        let pidfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-pidtest-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidfile) }

        XCTAssertNil(SingleInstanceGuard.readRecordedPID(at: pidfile))

        SingleInstanceGuard.writePID(4242, to: pidfile)
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 4242)

        // Release NEVER unlinks the pidfile — unlinking opened a two-instance
        // hole (unlink racing a newcomer's open→flock leaves the newcomer
        // locking an unlinked inode; every later launch then wins a fresh
        // inode's lock). The flock, not the file, is the mutex; a leftover
        // file with a stale pid is free.
        SingleInstanceGuard.releaseLock(at: pidfile, myPID: 9999) // not ours
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 4242)

        SingleInstanceGuard.releaseLock(at: pidfile, myPID: 4242) // ours
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 4242,
                       "releaseLock must be close-only; the pidfile stays as a diagnostic")
    }

    func testGarbagePidfileReadsAsNil() throws {
        let pidfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-pidtest-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidfile) }

        try "not-a-number".write(to: pidfile, atomically: true, encoding: .utf8)
        XCTAssertNil(SingleInstanceGuard.readRecordedPID(at: pidfile))
    }

    func testPidIsAliveForSelf() {
        // The test process is, by definition, alive.
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(SingleInstanceGuard.pidIsAlive(me))
        // A pid that cannot exist is not alive.
        XCTAssertFalse(SingleInstanceGuard.pidIsAlive(0))
        XCTAssertFalse(SingleInstanceGuard.pidIsAlive(-1))
    }

    // MARK: - PID-reuse identity guard

    func testIdentityProbeRejectsLiveNonSupervisorPid() {
        // The test runner is a live process, but its executable is NOT named
        // "Supervisor". The identity-aware probe must therefore treat it as NOT
        // an incumbent — this is the PID-reuse fix: a stale pid the OS reused
        // for an unrelated binary must not make a legit launch bow out.
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(SingleInstanceGuard.pidIsAlive(me), "sanity: test process is alive")
        let path = SingleInstanceGuard.executablePath(for: me)
        XCTAssertNotNil(path, "proc_pidpath should resolve the running test binary")
        XCTAssertNotEqual((path! as NSString).lastPathComponent, "Supervisor")
        XCTAssertFalse(
            SingleInstanceGuard.pidIsAliveSupervisor(me),
            "a live process whose executable isn't Supervisor is not an incumbent"
        )
        // Dead pids are rejected outright.
        XCTAssertFalse(SingleInstanceGuard.pidIsAliveSupervisor(0))
        XCTAssertNil(SingleInstanceGuard.executablePath(for: -1))
    }

    // MARK: - Atomic claim — kernel flock mutual exclusion (no TOCTOU, no
    // reclaim race). Mutual exclusion is arbitrated by an exclusive flock the
    // kernel releases on the holder's death; there is no read-decide-write and
    // no delete-then-recreate, so neither of the two prior two-instance windows
    // (check-then-write, blind reclaim removeItem) can occur.

    private func tmpPidfile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-claimtest-\(UUID().uuidString).pid")
    }

    func testClaimOnFreshPidfileClaimsAndRecordsPid() {
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        let result = SingleInstanceGuard.claim(at: pidfile, myPID: 1000)
        XCTAssertEqual(result, .claimed)
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 1000)
    }

    func testSecondRealClaimLosesToLiveHolder() {
        // Real flock: the winner keeps its lock fd open for the process
        // lifetime. A second claim in the same process opens a DISTINCT fd; the
        // kernel refuses the exclusive lock (flock conflicts across open file
        // descriptions, even within one process), so the loser bows out. This
        // is the primary two-instance invariant enforced by the OS itself.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        let winner = SingleInstanceGuard.claim(at: pidfile, myPID: 2000)
        XCTAssertEqual(winner, .claimed)

        let loser = SingleInstanceGuard.claim(at: pidfile, myPID: 1000)
        XCTAssertEqual(loser, .incumbentAlive(pid: 2000))
        XCTAssertNotEqual(loser, .claimed, "two claim()s must never both win")
        // The loser must NOT have clobbered the holder's recorded pid.
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 2000)
    }

    func testClaimTakesOverStalePidfileWithNoLiveHolder() {
        // A crashed Supervisor left a pidfile with a stale pid but NO held lock
        // (the kernel released it on death). The newcomer's flock succeeds and
        // it takes over — crash recovery, no stale-file surgery required.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        SingleInstanceGuard.writePID(2000, to: pidfile)  // stale content, unlocked
        let result = SingleInstanceGuard.claim(at: pidfile, myPID: 1000)
        XCTAssertEqual(result, .claimed)
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 1000, "lock taken over")
    }

    func testCrashedHolderLockIsImmediatelyReclaimable() {
        // Liveness invariant: a holder that dies must never block relaunch.
        // Model the kernel's automatic flock release on process death by
        // dropping the held fd WITHOUT removing the (now stale) pidfile, then
        // assert the next launcher takes over.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        let first = SingleInstanceGuard.claim(at: pidfile, myPID: 2000)
        XCTAssertEqual(first, .claimed)
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 2000)

        // "Crash": the kernel releases the flock; the stale pidfile remains.
        SingleInstanceGuard.releaseHeldLockForCrashSimulation()

        let second = SingleInstanceGuard.claim(at: pidfile, myPID: 3000)
        XCTAssertEqual(second, .claimed, "a crashed holder's lock must be reclaimable")
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 3000, "lock taken over")
    }

    // MARK: - Deterministic interleaving via the acquire/readPID seams

    func testConcurrentAcquireYieldsExactlyOneClaimTheRestLose() {
        // Drive the exact A/B/…/N interleaving deterministically via the acquire
        // seam modelling the kernel flock: the FIRST caller wins the exclusive
        // lock; every later caller sees it held by the live winner. The hard
        // invariant: it MUST be impossible for two claim()s to both claim.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        var granted = false
        let acquire: (URL) -> SingleInstanceGuard.LockOutcome = { _ in
            if granted { return .heldByLiveOwner }
            granted = true
            return .acquired(fd: -1)   // fd -1: recordPID's writes no-op harmlessly
        }
        let winnerPID: Int32 = 2000
        let readPID: (URL) -> Int32? = { _ in winnerPID }

        var results: [SingleInstanceGuard.ClaimResult] = []
        for pid in [winnerPID, 1000, 3000, 4000, 5000] {
            results.append(SingleInstanceGuard.claim(
                at: pidfile, myPID: pid, acquire: acquire, readPID: readPID))
        }
        XCTAssertEqual(results.filter { $0 == .claimed }.count, 1,
                       "exactly one racer may win — two .claimed is the two-instance bug")
        XCTAssertEqual(results.filter { $0 == .incumbentAlive(pid: winnerPID) }.count, 4,
                       "every loser bows out to the winner")
    }

    func testLoserRetriesReadingIncumbentPidThenReportsIt() {
        // The winner grabbed the lock microseconds ago and hasn't written its
        // pid yet: the loser reads nil, retries briefly, then reports the pid
        // once it appears. The loss itself never depends on this read.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        var reads = 0
        let readPID: (URL) -> Int32? = { _ in
            reads += 1
            return reads <= 2 ? nil : 2000   // pid appears on the 3rd read
        }
        let result = SingleInstanceGuard.claim(
            at: pidfile, myPID: 1000,
            acquire: { _ in .heldByLiveOwner },
            readPID: readPID,
            incumbentReadRetries: 8)
        XCTAssertEqual(result, .incumbentAlive(pid: 2000))
    }

    func testLoserBowsOutEvenIfIncumbentPidNeverReadable() {
        // Even if the incumbent's pid is never readable, a loser must never
        // claim — it bows out with a sentinel pid. Bounded retries -> no hang.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        let result = SingleInstanceGuard.claim(
            at: pidfile, myPID: 1000,
            acquire: { _ in .heldByLiveOwner },
            readPID: { _ in nil },            // pid never becomes readable
            incumbentReadRetries: 3)
        XCTAssertEqual(result, .incumbentAlive(pid: 0),
                       "a loser must never claim, even if it can't read the incumbent's pid")
        XCTAssertNotEqual(result, .claimed)
    }

    func testUnavailableLockFallsBackToRun() {
        // A filesystem quirk that makes the lock unusable must not block launch:
        // fall back to running (best-effort), matching the prior posture.
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        let result = SingleInstanceGuard.claim(
            at: pidfile, myPID: 1000, acquire: { _ in .unavailable })
        XCTAssertEqual(result, .claimed, "a filesystem quirk must not block launch")
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 1000)
    }
}
