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

    // MARK: - Stale predecessor sweep (the lingering hover band)

    // A macOS window belongs to its process's WindowServer connection, so a
    // Supervisor that DIES takes its hover band with it — the takeover path
    // (SIGTERM the hung incumbent, reclaim the flock) cannot orphan a band, and
    // neither can a crash. What CAN leave a band painted on the owner's screen
    // is a predecessor that is still RUNNING while no longer holding the lock:
    // the flock came back `.unavailable` so the incumbent ran lockless by
    // design, or the incumbent was SIGSTOPped (a frozen process keeps its
    // windows and can never run cleanup of its own). These pin who the winner
    // may signal on the way in — and, just as important, who it may not.

    private let predecessorPath = "/Applications/Supervisor.app/Contents/MacOS/Supervisor"
    /// A `ConfigPaths.homeIdentityHash` shape: 12 hex chars. The literal value
    /// is irrelevant; what matters is same-vs-different.
    private let homeToken = "a1b2c3d4e5f6"
    private let otherHomeToken = "0f0e0d0c0b0a"

    func testStalePredecessorIsReportedWhenAliveAndTheSameBinary() {
        let stale = SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { $0 == 2000 },
            executablePath: { _ in self.predecessorPath }
        )
        XCTAssertEqual(stale, 2000,
                       "a live previous instance of this same binary is what leaves a band on screen")
    }

    func testDeadPredecessorIsNotSignalled() {
        let stale = SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in false },
            executablePath: { _ in XCTFail("a dead pid must not be introspected"); return nil }
        )
        XCTAssertNil(stale, "a dead predecessor already took its window with it")
    }

    func testOwnPidIsNeverAStalePredecessor() {
        let stale = SingleInstanceGuard.stalePredecessor(
            recordedPID: myPID,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in XCTFail("our own pid must not be probed"); return true },
            executablePath: { _ in nil }
        )
        XCTAssertNil(stale, "a relaunch that re-reads its own recorded pid must not SIGTERM itself")
    }

    func testNoRecordedPidMeansNoSweep() {
        XCTAssertNil(SingleInstanceGuard.stalePredecessor(
            recordedPID: nil,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in XCTFail("nothing to probe"); return true },
            executablePath: { _ in nil }
        ))
    }

    /// The one that protects the owner. Under the E2E harness the test binary
    /// is ALSO called "Supervisor", so a basename check would let a harness
    /// instance SIGTERM the owner's installed app the moment a pid got reused.
    /// Identity is the full executable path.
    func testDifferentExecutablePathIsNeverSignalled() {
        let stale = SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: "/tmp/supervisor-e2e/build/Supervisor",
            myHomeToken: homeToken,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath }   // the owner's installed app
        )
        XCTAssertNil(stale,
                     "a test instance must never signal the owner's installed Supervisor on a reused pid")
    }

    /// Unreadable path means unverifiable identity. `pidIsAliveSupervisor`
    /// resolves that ambiguity toward "assume it is ours" because its cost is a
    /// silent duplicate exit; here the cost is a signal to a stranger, so it
    /// has to resolve the other way.
    func testUnreadableExecutablePathIsNeverSignalled() {
        XCTAssertNil(SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in true },
            executablePath: { _ in nil }
        ))
    }

    func testUnknownOwnExecutablePathDisablesTheSweep() {
        XCTAssertNil(SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: homeToken,
            myPID: myPID,
            myExecutablePath: nil,
            myHomeToken: homeToken,
            isAlive: { _ in XCTFail("with no identity of our own there is nothing to compare"); return true },
            executablePath: { _ in nil }
        ))
    }

    func testNonPositiveRecordedPidIsNeverSignalled() {
        for bogus: Int32 in [0, -1] {
            XCTAssertNil(SingleInstanceGuard.stalePredecessor(
                recordedPID: bogus,
                recordedHomeToken: homeToken,
                myPID: myPID,
                myExecutablePath: predecessorPath,
                myHomeToken: homeToken,
                isAlive: { _ in true },
                executablePath: { _ in self.predecessorPath }
            ), "pid \(bogus) must never be signalled — kill(0, SIGTERM) hits the whole process group")
        }
    }

    // MARK: - Lock-holding is distinguishable from the fallback

    /// `.claimed` has two sources: a real kernel lock, and the best-effort
    /// fallback for a filesystem that cannot do advisory locks. Anything that
    /// goes on to SIGNAL another process has to tell them apart, so the
    /// distinction is readable rather than implied.
    func testARealClaimHoldsTheExclusiveLock() {
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        XCTAssertEqual(SingleInstanceGuard.claim(at: pidfile, myPID: 1000), .claimed)
        XCTAssertTrue(SingleInstanceGuard.holdsExclusiveLock,
                      "a winning claim must report that it holds the lock")
    }

    /// The fallback runs, but it holds nothing — so the predecessor sweep that
    /// depends on this must stay its hand. Without the lock there is no proof
    /// the other live instance is a leftover rather than a healthy incumbent,
    /// and killing a healthy incumbent is how the pre-flock kill wars started.
    func testUnavailableLockClaimsWithoutHoldingTheLock() {
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        XCTAssertEqual(
            SingleInstanceGuard.claim(at: pidfile, myPID: 1000, acquire: { _ in .unavailable }),
            .claimed
        )
        XCTAssertFalse(SingleInstanceGuard.holdsExclusiveLock,
                       "the filesystem fallback must never claim to hold the lock")
    }

    // MARK: - The pidfile carries WHOSE instance recorded the pid

    // The executable path alone says "same binary", and two concurrent E2E runs
    // share one .build/debug/Supervisor. On a reused pid that made each run a
    // candidate to sweep the other, which would kill a scenario mid-drive and
    // read as a mystery failure. The home token is the second axis: the same
    // seam the flock and the UserDefaults suite are namespaced by, so "may I
    // signal it" now answers the same way as "do we share a world".

    func testClaimRecordsTheHomeTokenBesideThePid() {
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        XCTAssertEqual(SingleInstanceGuard.claim(at: pidfile, myPID: 1000, homeToken: homeToken), .claimed)
        let record = SingleInstanceGuard.readPredecessorRecord(at: pidfile)
        XCTAssertEqual(record?.pid, 1000)
        XCTAssertEqual(record?.homeToken, homeToken,
                       "the next launcher can only check the home axis if the claim wrote it")
    }

    /// Backward compatibility, and it is not hypothetical: the pidfile a
    /// launching app reads was written by the version it is REPLACING. An
    /// upgrade in place always reads one of these once.
    func testAPidfileWithoutATokenStillReadsItsPid() throws {
        let pidfile = tmpPidfile()
        defer { try? FileManager.default.removeItem(at: pidfile) }

        try "4242\n".write(to: pidfile, atomically: true, encoding: .utf8)
        XCTAssertEqual(SingleInstanceGuard.readRecordedPID(at: pidfile), 4242,
                       "an old-format pidfile must still identify its incumbent, or the duplicate guard degrades into two live instances")
        let record = SingleInstanceGuard.readPredecessorRecord(at: pidfile)
        XCTAssertEqual(record?.pid, 4242)
        XCTAssertNil(record?.homeToken, "absent must read as absent, never as a match")
    }

    /// The same old pidfile, on the sweep side. An absent token is
    /// unverifiable identity, and the sweep's mistake costs a signal to a
    /// process that may not be ours — so absence resolves to "do not signal".
    func testAPidfileWithoutATokenIsNeverSwept() {
        XCTAssertNil(SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: nil,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath }
        ), "a pidfile with no home token cannot prove the predecessor shares our world")
    }

    /// The residual this closes. Two concurrent E2E runs, one binary path, a
    /// reused pid: without the home axis each run would sweep the other.
    func testAPredecessorFromAnotherHomeIsNeverSignalled() {
        XCTAssertNil(SingleInstanceGuard.stalePredecessor(
            recordedPID: 2000,
            recordedHomeToken: otherHomeToken,
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath }
        ), "two isolated runs share .build/debug/Supervisor; the same path is not the same instance")
    }

    // MARK: - The sweep itself (who gets signalled, and did it work)

    // The call site used to be a private method on the app delegate: no test
    // could reach it, so "we hold no lock" and "the signal landed" were both
    // taken on faith. The whole sequence now lives here behind an injected
    // signal sender, so these assert on the signals themselves.

    private struct SignalRecorder {
        private(set) var sent: [(pid: Int32, sig: Int32)] = []
        mutating func record(_ pid: Int32, _ sig: Int32) { sent.append((pid, sig)) }
        var signals: [Int32] { sent.map(\.sig) }
    }

    func testSweepWithoutTheExclusiveLockSendsNoSignal() {
        var recorder = SignalRecorder()
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: homeToken),
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            holdsLock: false,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath },
            sendSignal: { pid, sig in recorder.record(pid, sig); return 0 }
        )
        XCTAssertEqual(outcome, .skippedWithoutExclusiveLock(pid: 2000))
        XCTAssertTrue(recorder.sent.isEmpty,
                      "under the lockless fallback a live sibling is as likely to be a HEALTHY incumbent; killing it restarts the pre-flock kill wars")
    }

    func testSweepDoesNotSignalADifferentExecutablePath() {
        var recorder = SignalRecorder()
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: homeToken),
            myPID: myPID,
            myExecutablePath: "/tmp/supervisor-e2e/build/Supervisor",
            myHomeToken: homeToken,
            holdsLock: true,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath },   // the owner's installed app
            sendSignal: { pid, sig in recorder.record(pid, sig); return 0 }
        )
        XCTAssertEqual(outcome, .nothingToRetire)
        XCTAssertTrue(recorder.sent.isEmpty,
                      "a harness instance must never SIGTERM the owner's installed Supervisor on a reused pid")
    }

    func testSweepDoesNotSignalAPredecessorFromAnotherHome() {
        var recorder = SignalRecorder()
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: otherHomeToken),
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            holdsLock: true,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath },
            sendSignal: { pid, sig in recorder.record(pid, sig); return 0 }
        )
        XCTAssertEqual(outcome, .nothingToRetire)
        XCTAssertTrue(recorder.sent.isEmpty, "same binary, different world: not ours to kill")
    }

    func testSweepSendsContThenTermToAFullMatch() {
        var recorder = SignalRecorder()
        var alive = true
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: homeToken),
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            holdsLock: true,
            isAlive: { _ in alive },
            executablePath: { _ in self.predecessorPath },
            sendSignal: { pid, sig in
                recorder.record(pid, sig)
                if sig == SIGTERM { alive = false }
                return 0
            },
            deathChecks: 3,
            deathCheckInterval: 0,
            wait: { _ in }
        )
        XCTAssertEqual(outcome, .retired(pid: 2000))
        XCTAssertEqual(recorder.sent.map(\.pid), [2000, 2000])
        XCTAssertEqual(recorder.signals, [SIGCONT, SIGTERM],
                       "CONT first: SIGTERM alone is only queued for a STOPPED process, and a SIGSTOPped instance keeping its band painted is the case this exists for")
    }

    /// The sweep's own failure mode. SIGTERM is a request, and a predecessor
    /// that ignores it keeps its WindowServer connection and its band. Before
    /// this the hung case logged exactly like the successful one.
    func testSweepReportsAPredecessorThatSurvivedTermination() {
        var recorder = SignalRecorder()
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: homeToken),
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            holdsLock: true,
            isAlive: { _ in true },          // never dies
            executablePath: { _ in self.predecessorPath },
            sendSignal: { pid, sig in recorder.record(pid, sig); return 0 },
            deathChecks: 3,
            deathCheckInterval: 0,
            wait: { _ in }
        )
        XCTAssertEqual(outcome, .survivedTermination(pid: 2000),
                       "a sweep that signalled and did not get its process must not report the same outcome as one that did")
        XCTAssertEqual(recorder.signals, [SIGCONT, SIGTERM])
    }

    func testSweepReportsAFailedSignal() {
        let outcome = SingleInstanceGuard.retirePredecessor(
            recorded: .init(pid: 2000, homeToken: homeToken),
            myPID: myPID,
            myExecutablePath: predecessorPath,
            myHomeToken: homeToken,
            holdsLock: true,
            isAlive: { _ in true },
            executablePath: { _ in self.predecessorPath },
            sendSignal: { _, sig in sig == SIGTERM ? -1 : 0 },
            deathChecks: 3,
            deathCheckInterval: 0,
            wait: { _ in }
        )
        guard case .signalFailed(let pid, _) = outcome else {
            return XCTFail("a failed SIGTERM must be reported as such, not as a retirement: \(outcome)")
        }
        XCTAssertEqual(pid, 2000)
    }
}
