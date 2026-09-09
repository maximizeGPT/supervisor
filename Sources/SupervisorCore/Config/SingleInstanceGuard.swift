// SingleInstanceGuard.swift
//
// Deterministic single-instance arbitration. Mutual exclusion is enforced
// by a kernel-held exclusive `flock` on a lockfile under appSupportDir; the
// pidfile CONTENT records the holder's pid for the trace/notification only.
//
// Why this exists: the old guard killed every sibling with a different
// pid on launch. Two app bundles sharing one bundle id (the known
// collision) then ping-ponged: instance A launched and terminated B; a
// relauncher/login-item started B again, which terminated A, back and
// forth. The fix flips the rule. If an instance is already alive, the
// NEWCOMER quits instead of killing the incumbent. A relaunched
// duplicate therefore bows out rather than starting a kill war.
//
// How arbitration works now: a launching instance takes a non-blocking
// exclusive `flock` (LOCK_EX | LOCK_NB) on the pidfile. Exactly one racer
// can hold it, so two instances can never both "claim" — this is what makes
// the arbitration race-free. The lock is released by the kernel when the
// holder's fd closes, INCLUDING on crash / kill, so a dead holder never
// blocks relaunch and there is no stale-file reclamation, no pid-liveness
// guessing, and no delete-then-recreate TOCTOU. The holding fd is kept open
// for the process lifetime and closed on normal termination (releaseLock).
//
// `decide` and the pid-liveness probes below remain as pure, unit-tested
// helpers (used to report an incumbent's identity), but they are no longer
// on the critical mutual-exclusion path — the `flock` is.

import Darwin
import Foundation

public enum SingleInstanceGuard {

    /// The main app's executable name (the binary inside
    /// Supervisor.app/Contents/MacOS/, and the SPM product name in dev runs).
    /// Used to verify a recorded pid is actually a Supervisor before treating
    /// it as an incumbent — PIDs get reused, executable identity does not.
    public static let expectedExecutableName = "Supervisor"

    /// The decision a launching instance should take after inspecting
    /// the pidfile.
    public enum Decision: Equatable {
        /// No live incumbent: this instance may run and should claim the
        /// lock (write its pid).
        case run
        /// A live incumbent owns the lock: this duplicate must quit so
        /// only one Supervisor watches. Carries the incumbent pid for
        /// the trace/notification.
        case quit(incumbentPID: Int32)
    }

    /// Pure decision function.
    ///
    /// - `recordedPID`: the pid read from the pidfile, or nil if the
    ///   file is absent/empty/garbage.
    /// - `myPID`: this process's pid.
    /// - `isAlive`: liveness probe for a pid (production: `kill(pid, 0)`;
    ///   tests inject a stub). Should return true only for a live
    ///   process the launcher would consider an incumbent Supervisor.
    ///
    /// Rules:
    ///   - no recorded pid                 -> run (claim the lock)
    ///   - recorded pid is my own pid      -> run (re-claim; not a rival)
    ///   - recorded pid is alive (a rival) -> quit (newcomer bows out)
    ///   - recorded pid is dead (stale)    -> run (take over the lock)
    public static func decide(
        recordedPID: Int32?,
        myPID: Int32,
        isAlive: (Int32) -> Bool
    ) -> Decision {
        guard let recordedPID else { return .run }
        if recordedPID == myPID { return .run }
        if isAlive(recordedPID) { return .quit(incumbentPID: recordedPID) }
        return .run
    }

    // MARK: - Production helpers (thin, not unit tested directly)

    /// Default liveness probe: `kill(pid, 0)` returns 0 if the process
    /// exists and we may signal it. ESRCH means no such process (dead /
    /// stale). EPERM means it exists but is owned by another user — treat
    /// as alive to stay conservative (don't stomp a real instance).
    public static func pidIsAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The executable path of a live pid, via `proc_pidpath`, or nil if the
    /// pid is dead / not readable. Mirrors LiveProcessLocator.execPath — the
    /// `4 * MAXPATHLEN` buffer is `PROC_PIDPATHINFO_MAXSIZE` (Swift's macro
    /// importer rejects the constant, so the literal is used directly).
    public static func executablePath(for pid: Int32) -> String? {
        if pid <= 0 { return nil }
        let cap = 4 * Int(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: cap)
        let ret = proc_pidpath(pid, &buf, UInt32(cap))
        if ret <= 0 { return nil }
        return String(cString: buf)
    }

    /// Identity-aware liveness probe. A crashed Supervisor leaves a stale
    /// pidfile; the OS may later reuse that pid for an unrelated process, which
    /// `kill(pid, 0)` reports as "alive" — so the old probe would let a legit
    /// launch quit silently as a duplicate of a stranger. This verifies the
    /// recorded pid's executable is actually a Supervisor before treating it as
    /// an incumbent. Returns true only when the pid is live AND its executable
    /// basename matches `expectedExecutableName`. If the path can't be read
    /// (EPERM on another user's process), fall back to the plain liveness
    /// result — conservative, so we never stomp a real instance we can't
    /// introspect. A pure diagnostic probe (mutual exclusion is via `flock`).
    public static func pidIsAliveSupervisor(_ pid: Int32) -> Bool {
        guard pidIsAlive(pid) else { return false }
        guard let path = executablePath(for: pid) else {
            // Live (or EPERM) but path unreadable: don't risk stomping a real
            // instance we simply can't introspect.
            return true
        }
        return (path as NSString).lastPathComponent == expectedExecutableName
    }

    /// What the pidfile records about the instance that held the lock before
    /// us: its pid, and the identity of the home it ran against.
    ///
    /// `homeToken` is nil for a pidfile written by a build that predates the
    /// token — an upgrade in place, where the old app is still running as the
    /// new one launches. Nil is not "matches anything": it is unverifiable
    /// identity, and the sweep resolves that the way it resolves an unreadable
    /// executable path, by not signalling.
    public struct PredecessorRecord: Equatable, Sendable {
        public let pid: Int32
        public let homeToken: String?

        public init(pid: Int32, homeToken: String?) {
            self.pid = pid
            self.homeToken = homeToken
        }
    }

    /// The pid of a PREVIOUS instance of this exact binary that is still alive
    /// after we won the lock, or nil when there is none to worry about.
    ///
    /// Why a winner has to look at all. A macOS window belongs to its process's
    /// WindowServer connection, so a Supervisor that dies takes its hover band
    /// with it — the takeover path (SIGTERM the hung incumbent, reclaim the
    /// flock) therefore cannot orphan a band, and neither can a crash. The one
    /// shape that CAN leave a band on screen is a predecessor that is still
    /// RUNNING while no longer holding the lock:
    ///
    ///   - the `flock` came back `.unavailable` for the incumbent (open failed,
    ///     a filesystem that does not honor advisory locks) so it ran lockless
    ///     by design, and the newcomer's own `flock` then succeeds — two live
    ///     instances, two bands, and the incumbent is the one nobody can find;
    ///   - the incumbent released the lock and is still finishing teardown;
    ///   - the incumbent was SIGSTOPped. A frozen process keeps its windows on
    ///     screen and cannot run any cleanup of its own, which is exactly the
    ///     stacked-pill screenshot the owner sent.
    ///
    /// The pidfile lives under THIS instance's home, so its recorded pid is by
    /// construction a previous instance of our own world. Identity is checked
    /// on two axes, and both have to match:
    ///
    ///   - our own executable PATH, not just the basename: under the E2E
    ///     harness the test binary is also called "Supervisor", and a reused
    ///     pid must never let a test instance signal the owner's installed app;
    ///   - the home token the predecessor recorded. Two concurrent E2E runs
    ///     share one `.build/debug/Supervisor`, so the path axis alone says
    ///     "same binary" about two instances that are deliberately isolated
    ///     from each other. On a reused pid one run would then sweep the
    ///     other's app and the scenario would fail as a mystery. The token is
    ///     `ConfigPaths.homeIdentityHash`, the same seam the flock and the
    ///     UserDefaults suite are namespaced by, so "may I signal it" now
    ///     answers the same way as "do we share a world".
    ///
    /// Pure, with injected probes, so every branch is unit-tested without
    /// signalling anything.
    ///
    /// - Parameters:
    ///   - recordedPID: the pid read from the pidfile BEFORE this instance
    ///     overwrote it with its own.
    ///   - recordedHomeToken: the token stored beside that pid; nil for a
    ///     pidfile written before the token existed, which disables the sweep.
    ///   - myExecutablePath: this process's executable path; nil disables the
    ///     sweep (unknown identity is never grounds to signal).
    ///   - myHomeToken: this instance's `ConfigPaths.homeIdentityHash`.
    public static func stalePredecessor(
        recordedPID: Int32?,
        recordedHomeToken: String?,
        myPID: Int32,
        myExecutablePath: String?,
        myHomeToken: String,
        isAlive: (Int32) -> Bool = pidIsAlive,
        executablePath: (Int32) -> String? = executablePath
    ) -> Int32? {
        guard let recordedPID, recordedPID > 0, recordedPID != myPID else { return nil }
        guard let mine = myExecutablePath, !mine.isEmpty else { return nil }
        // An absent token is the old on-disk format, and an old pidfile is
        // exactly the case where the running predecessor may not be ours at
        // all. Unverifiable identity is never grounds to signal.
        guard let theirToken = recordedHomeToken, !theirToken.isEmpty,
              !myHomeToken.isEmpty, theirToken == myHomeToken else { return nil }
        guard isAlive(recordedPID) else { return nil }
        // Unreadable path means unverifiable identity. `pidIsAliveSupervisor`
        // treats that as "assume it is one of ours" because the cost there is a
        // silent duplicate exit; here the cost is a signal to a stranger, so
        // the same ambiguity has to resolve the other way.
        guard let theirs = executablePath(recordedPID), theirs == mine else { return nil }
        return recordedPID
    }

    /// Outcome of the predecessor sweep, so the caller can log a HUNG sweep
    /// differently from a clean one. A sweep that signalled and then watched
    /// the process keep running is the one worth being loud about: the band it
    /// exists to remove is still on screen, and nothing else will retry.
    public enum PredecessorSweep: Equatable {
        /// No predecessor, or one this instance is not allowed to signal.
        case nothingToRetire
        /// A predecessor was recorded, but we run under the lockless fallback
        /// and may not signal it. Carries the pid for the trace.
        case skippedWithoutExclusiveLock(pid: Int32)
        /// Signalled, and the process was gone before the deadline.
        case retired(pid: Int32)
        /// The SIGTERM itself failed. Carries errno as reported by the sender.
        case signalFailed(pid: Int32, code: Int32)
        /// Signalled, and the process was STILL alive at the deadline.
        case survivedTermination(pid: Int32)
    }

    /// The whole sweep: the lock gate, the identity checks, the signal, and the
    /// confirmation that the signal actually took.
    ///
    /// Why the pidfile read is a parameter rather than a step inside: a winning
    /// `claim` overwrites the file with our own pid, so the predecessor's
    /// record only exists before the claim runs. The caller reads it first (via
    /// `readPredecessorRecord`) and hands it in — the read cannot move in here
    /// without also moving the claim.
    ///
    /// Verifying death, rather than assuming it: SIGTERM is a request. A
    /// predecessor with a handler that hangs, or one stopped in the kernel in a
    /// way SIGCONT did not clear, keeps its WindowServer connection and keeps
    /// its band. Before this the two outcomes logged identically, so a sweep
    /// that did nothing looked exactly like one that worked.
    ///
    /// `sendSignal` is injected so tests can assert the signals (and their
    /// ORDER) without a real process to kill.
    ///
    /// - Parameters:
    ///   - holdsLock: whether we hold the kernel `flock`. `claim` also returns
    ///     `.claimed` for the filesystem fallback, and there a live sibling is
    ///     as likely to be a HEALTHY incumbent as a leftover; killing that is
    ///     how the pre-flock kill wars started.
    ///   - deathChecks / deathCheckInterval: the confirmation poll, ~2s by
    ///     default. Bounded, because this runs on the launch path.
    public static func retirePredecessor(
        recorded: PredecessorRecord?,
        myPID: Int32,
        myExecutablePath: String?,
        myHomeToken: String,
        holdsLock: Bool,
        isAlive: (Int32) -> Bool = pidIsAlive,
        executablePath: (Int32) -> String? = executablePath,
        sendSignal: (Int32, Int32) -> Int32 = { kill($0, $1) },
        deathChecks: Int = 20,
        deathCheckInterval: TimeInterval = 0.1,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> PredecessorSweep {
        guard holdsLock else {
            if let recorded, recorded.pid > 0, recorded.pid != myPID {
                return .skippedWithoutExclusiveLock(pid: recorded.pid)
            }
            return .nothingToRetire
        }
        guard let stale = stalePredecessor(
            recordedPID: recorded?.pid,
            recordedHomeToken: recorded?.homeToken,
            myPID: myPID,
            myExecutablePath: myExecutablePath,
            myHomeToken: myHomeToken,
            isAlive: isAlive,
            executablePath: executablePath
        ) else { return .nothingToRetire }

        // CONT first: SIGTERM alone is delivered to a stopped process, but
        // waking it makes the termination immediate and observable rather than
        // dependent on scheduler details.
        _ = sendSignal(stale, SIGCONT)
        if sendSignal(stale, SIGTERM) != 0 {
            return .signalFailed(pid: stale, code: errno)
        }
        for _ in 0..<max(deathChecks, 0) {
            if !isAlive(stale) { return .retired(pid: stale) }
            wait(deathCheckInterval)
        }
        return isAlive(stale) ? .survivedTermination(pid: stale) : .retired(pid: stale)
    }

    /// Result of an atomic lock claim.
    public enum ClaimResult: Equatable {
        /// This instance won the lock (its pid is now recorded) and may run.
        case claimed
        /// A live incumbent already owns the lock; this duplicate must quit.
        case incumbentAlive(pid: Int32)
    }

    /// Outcome of trying to grab the OS-level exclusive lock on the pidfile.
    public enum LockOutcome: Equatable {
        /// We now hold the exclusive `flock`. Carries the open fd, which the
        /// caller must keep alive for the process lifetime — the kernel drops
        /// the lock only when this fd is closed or the process dies.
        case acquired(fd: Int32)
        /// Another *live* process already holds the exclusive lock. (A dead
        /// holder cannot: the kernel released its lock when it exited/crashed.)
        case heldByLiveOwner
        /// The lock could not be used at all (open failed, a non-local FS that
        /// doesn't honor `flock`, permissions). The caller falls back to
        /// running rather than blocking launch on a filesystem quirk.
        case unavailable
    }

    /// Production lock primitive: open the pidfile and take a non-blocking
    /// exclusive `flock`. This is the whole mutual-exclusion mechanism — it is
    /// race-free and deadlock-free because the *kernel* owns the lock's
    /// lifetime:
    ///   - Exactly one open file description can hold `LOCK_EX` at a time, so
    ///     two racers can never both acquire it → never two `.claimed`.
    ///   - `LOCK_NB` never blocks, so a launch can never hang on the lock.
    ///   - The lock is released automatically when the holding fd is closed,
    ///     including on crash / `_exit` / SIGKILL — so a dead holder is always
    ///     reclaimable immediately, with no stale-file detection, no pid
    ///     liveness probing, and no delete-then-recreate TOCTOU.
    ///
    /// `flock` advisory locks require a local filesystem; Application Support
    /// (where the pidfile lives) is local, so this holds in production.
    public static func acquireExclusiveLock(at pidfile: URL) -> LockOutcome {
        // O_CLOEXEC: the lock fd must never be inherited by a spawned child
        // (heartbeat / status-bar). Today's Foundation.Process spawns with
        // close-on-exec-by-default, but setting it atomically at open() makes the
        // guard robust if a future refactor uses raw posix_spawn/fork+exec — an
        // inherited fd would keep the flock held by a surviving child after the
        // parent crashes, permanently blocking relaunch.
        let fd = open(pidfile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if fd < 0 { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(fd: fd)
        }
        // Capture errno before close() can overwrite it.
        let err = errno
        close(fd)
        if err == EWOULDBLOCK { return .heldByLiveOwner }
        return .unavailable
    }

    /// The fd of the exclusive lock this process holds, kept open for the
    /// process lifetime so the kernel releases the `flock` on exit *and* on
    /// crash — that automatic release is what makes a dead holder always
    /// reclaimable. `-1` when this process holds no lock.
    private static var heldLockFD: Int32 = -1

    /// Whether this process actually holds the kernel exclusive lock, as
    /// opposed to having been waved through by the `.unavailable` fallback.
    /// The two both produce `.claimed`, and callers that go on to SIGNAL
    /// another process need to tell them apart: without the lock there is no
    /// proof the other instance is a leftover rather than a healthy incumbent,
    /// and killing a healthy incumbent is how the pre-flock guard's kill wars
    /// started.
    public static var holdsExclusiveLock: Bool { heldLockFD >= 0 }

    /// The single on-disk spelling of a pidfile line: `"<pid> <homeToken>\n"`.
    /// One function so the writer and `readPredecessorRecord` can never drift.
    static func pidfileLine(pid: Int32, homeToken: String) -> String {
        homeToken.isEmpty ? "\(pid)\n" : "\(pid) \(homeToken)\n"
    }

    /// Overwrite the open, locked fd with `pid` (diagnostic + so a future
    /// loser can report which pid is the incumbent). Truncate first so a
    /// takeover of a stale file leaves no trailing bytes of the old pid.
    ///
    /// The home token rides along because the pid alone does not say WHOSE
    /// instance recorded it, and the predecessor sweep signals on that answer.
    private static func recordPID(_ pid: Int32, homeToken: String, toOpenFD fd: Int32) {
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let bytes = Array(pidfileLine(pid: pid, homeToken: homeToken).utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        _ = fsync(fd)
    }

    /// Claim the single-instance lock via an OS-level exclusive `flock`.
    ///
    /// This closes BOTH two-instance windows of the previous pidfile scheme:
    /// the check-then-write TOCTOU (two racers both see "no incumbent") AND the
    /// reclaim race (two racers both classify a stale file reclaimable, and one
    /// deletes the other's freshly-written live lock). Neither can occur here
    /// because there is no read-decide-write and no delete-then-recreate: a
    /// single kernel-arbitrated `flock` decides the winner, and the kernel
    /// releases it on the holder's death.
    ///
    ///   - Lock acquired → this instance won; record its pid, keep the fd for
    ///     the process lifetime, return `.claimed`.
    ///   - Lock held by a live owner → return `.incumbentAlive`; the newcomer
    ///     quits. (A crashed owner's lock is already released by the kernel, so
    ///     this branch never fires for a dead holder — crash recovery is
    ///     automatic and immediate.)
    ///   - Lock unusable (fs quirk) → best-effort run, matching prior posture.
    ///
    /// `acquire` and `readPID` are injectable seams (defaulted to production
    /// implementations) so tests can drive the racer interleaving
    /// deterministically. `incumbentReadRetries` bounds a brief re-read of the
    /// incumbent's pid when the winner grabbed the lock microseconds ago and
    /// has not yet written it — this read affects the *reported pid only*,
    /// never the win/lose outcome.
    public static func claim(
        at pidfile: URL,
        myPID: Int32,
        homeToken: String = ConfigPaths.homeIdentityHash,
        acquire: (URL) -> LockOutcome = acquireExclusiveLock,
        readPID: (URL) -> Int32? = readRecordedPID,
        incumbentReadRetries: Int = 32
    ) -> ClaimResult {
        try? FileManager.default.createDirectory(
            at: pidfile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch acquire(pidfile) {
        case .acquired(let fd):
            // Won the kernel-exclusive lock. Keep the fd open for the process
            // lifetime (the kernel releases it on exit/crash) and record our
            // pid for the trace and for future losers to report.
            heldLockFD = fd
            recordPID(myPID, homeToken: homeToken, toOpenFD: fd)
            return .claimed

        case .heldByLiveOwner:
            // A live incumbent owns the lock: bow out. Read its pid for the
            // trace, retrying briefly if it won the lock but has not yet
            // recorded its pid. The outcome is already decided (we lost); only
            // the reported pid depends on this read.
            var pid = readPID(pidfile)
            var tries = 0
            while pid == nil && tries < incumbentReadRetries {
                tries += 1
                var ts = timespec(tv_sec: 0, tv_nsec: 500_000)  // ~0.5 ms
                nanosleep(&ts, nil)
                pid = readPID(pidfile)
            }
            return .incumbentAlive(pid: pid ?? 0)

        case .unavailable:
            // Could not use the lock (open failed, non-local FS, permissions).
            // Fall back to letting this instance run rather than block launch
            // on a filesystem quirk — the same best-effort posture as the prior
            // implementation. Record our pid best-effort for diagnostics.
            writePID(myPID, homeToken: homeToken, to: pidfile)
            return .claimed
        }
    }

    /// Test seam: release ONLY the OS lock — exactly as the kernel does when a
    /// holder process dies — WITHOUT touching the pidfile on disk. Lets a unit
    /// test prove a crashed holder's lock is immediately reclaimable by the
    /// next launcher (liveness) even though its stale pidfile still exists.
    internal static func releaseHeldLockForCrashSimulation() {
        if heldLockFD >= 0 {
            close(heldLockFD)
            heldLockFD = -1
        }
    }

    /// Read the recorded pid from `pidfile`, or nil if the file is
    /// absent, empty, or not an integer.
    ///
    /// Parses the FIRST whitespace-separated field, so it reads both the
    /// current `"<pid> <homeToken>"` form and the bare `"<pid>"` a build
    /// before the token wrote. A pidfile is read by a newly launched app
    /// against a file the previous version left behind, so the old form has to
    /// keep parsing rather than degrade to "no incumbent" — that would be a
    /// second full instance, not a cosmetic miss.
    public static func readRecordedPID(at pidfile: URL) -> Int32? {
        readPredecessorRecord(at: pidfile)?.pid
    }

    /// Read the full pidfile record: the pid, plus the home token beside it
    /// when the file was written by a build that records one.
    public static func readPredecessorRecord(at pidfile: URL) -> PredecessorRecord? {
        guard let text = try? String(contentsOf: pidfile, encoding: .utf8) else {
            return nil
        }
        let fields = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let first = fields.first, let pid = Int32(first) else { return nil }
        let token = fields.count > 1 ? String(fields[1]) : nil
        return PredecessorRecord(pid: pid, homeToken: token)
    }

    /// Write `myPID` to `pidfile`, claiming the lock. Best-effort: a
    /// failure to write does not stop the app from running.
    public static func writePID(
        _ pid: Int32,
        homeToken: String = ConfigPaths.homeIdentityHash,
        to pidfile: URL
    ) {
        try? pidfileLine(pid: pid, homeToken: homeToken)
            .write(to: pidfile, atomically: true, encoding: .utf8)
    }

    /// Release the single-instance lock on normal termination by closing the
    /// held fd. The pidfile itself is NEVER unlinked: its content is purely
    /// diagnostic, and unlinking opens a real two-instance hole — if the
    /// unlink lands between a launching newcomer's open(O_CREAT) and its
    /// flock(), the newcomer holds an exclusive lock on an inode no path
    /// points to, and every later launch creates a fresh inode, flocks it,
    /// and also "wins": two full instances, indefinitely. A stale pidfile
    /// with no flock on it costs nothing (the flock, not the file, is the
    /// mutex), so the safe release is close-only.
    public static func releaseLock(at pidfile: URL, myPID: Int32) {
        if heldLockFD >= 0 {
            close(heldLockFD)
            heldLockFD = -1
        }
    }
}
