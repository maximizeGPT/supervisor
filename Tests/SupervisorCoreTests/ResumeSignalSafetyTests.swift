// ResumeSignalSafetyTests.swift — audit item B2.
//
// The bug: the hover panel's Resume button resolved its target by cwd ONLY.
// When that walk fell through to the locator's documented Claude.app fallback
// it returned the SHARED desktop Electron pid, the handler sent SIGCONT to it,
// and the panel then reported a successful resume — while the session the owner
// actually paused stayed stopped.
//
// These tests pin the two halves of the fix:
//   1. ResumeResolver never signals a desktop-fallback target, whether the
//      fallback is reached through the cwd walk or handed to it directly.
//   2. The refusal reaches the OWNER: the paused state survives and the panel
//      gets a plain-voice reason, instead of a silent no-op that looks like
//      success.

import Darwin
import XCTest
@testable import SupervisorCore

@MainActor
final class ResumeSignalSafetyTests: XCTestCase {

    // MARK: - Doubles

    /// A locator that models the real fallback contract: the cwd walk finds a
    /// CLI process only when `cliHandle` is set, and otherwise produces the
    /// shared Claude.app handle — but only when the caller ALLOWS the fallback.
    /// `bySessionHandle` is answered independently, the way LiveProcessLocator's
    /// separate argv lookup is.
    struct FallbackLocator: ProcessLocator {
        var cliHandle: ProcessHandle?
        var desktopHandle: ProcessHandle?
        var bySessionHandle: ProcessHandle?

        func locate(targetCwd: String) -> ProcessHandle? {
            locate(targetCwd: targetCwd, allowDesktopFallback: true)
        }

        func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle? {
            if let cliHandle { return cliHandle }
            return allowDesktopFallback ? desktopHandle : nil
        }

        func locate(bySessionId sessionId: String) -> ProcessHandle? { bySessionHandle }
    }

    final class RecordingSignalSender: SignalSender, @unchecked Sendable {
        struct Sent: Equatable { let signal: Int32; let pid: pid_t }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var sent: [Sent] {
            lock.lock(); defer { lock.unlock() }
            return _sent
        }
        var throwOnNext: SignalError?
        func send(_ signal: Int32, to pid: pid_t) throws {
            lock.lock(); defer { lock.unlock() }
            if let err = throwOnNext {
                throwOnNext = nil
                throw err
            }
            _sent.append(Sent(signal: signal, pid: pid))
        }
    }

    // MARK: - Fixtures

    /// The shared Claude desktop host as the locator returns it: the Electron
    /// binary path, cwd "/" (never a session's directory).
    private let desktopHost = ProcessHandle(
        pid: 501,
        execPath: "/Applications/Claude.app/Contents/MacOS/Claude",
        cwd: "/"
    )

    private let cliProcess = ProcessHandle(
        pid: 9001,
        execPath: "/usr/local/bin/claude",
        cwd: "/Users/main/project"
    )

    private func makeTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-safety-\(UUID()).log"))
    }

    // MARK: - The refusal

    /// The exact B2 shape: nothing resolves except the desktop fallback. The
    /// resolver asks for the walk WITHOUT the fallback, so it gets nothing, and
    /// no signal may be sent.
    func testDesktopFallbackOnlyTargetIsRefusedAndNothingIsSignalled() {
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: desktopHost, bySessionHandle: nil),
            signalSender: sender,
            trace: makeTrace()
        )

        let outcome = resolver.resume(sessionId: "S1", cwd: "/Users/main/project")

        XCTAssertEqual(outcome, .notResolved,
            "a target that only exists via the Claude.app fallback must not resolve for a signal")
        XCTAssertFalse(outcome.didResume)
        XCTAssertTrue(sender.sent.isEmpty,
            "no signal may reach the shared desktop host: SIGCONT there continues every conversation, not the paused session")
        XCTAssertNotNil(outcome.userFacingReason,
            "a refusal must carry something the panel can show")
    }

    /// Belt-and-braces: even if a lookup hands back the desktop host directly
    /// (the by-session path is a separate walk with its own rules), the handle
    /// itself is refused before any `kill(2)`.
    func testDesktopHostHandleIsRefusedEvenWhenALookupReturnsIt() {
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: nil, bySessionHandle: desktopHost),
            signalSender: sender,
            trace: makeTrace()
        )

        let outcome = resolver.resume(sessionId: "S1", cwd: "/Users/main/project")

        XCTAssertEqual(outcome, .refusedSharedDesktopHost(pid: 501))
        XCTAssertTrue(sender.sent.isEmpty, "the shared desktop host is never a signal target")
        XCTAssertEqual(outcome.userFacingReason?.isEmpty, false)
    }

    func testProcessHandleRecognizesTheSharedDesktopHost() {
        XCTAssertTrue(desktopHost.isSharedDesktopHost)
        XCTAssertFalse(cliProcess.isSharedDesktopHost)
    }

    // MARK: - The happy paths still work

    func testSessionIdResolutionSendsSIGCONTToThatProcess() {
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: desktopHost, bySessionHandle: cliProcess),
            signalSender: sender,
            trace: makeTrace()
        )

        let outcome = resolver.resume(sessionId: "S1", cwd: "/Users/main/project")

        XCTAssertEqual(outcome, .resumed(pid: 9001))
        XCTAssertEqual(sender.sent, [.init(signal: SIGCONT, pid: 9001)])
    }

    /// The session id wins over the cwd walk. With concurrent sessions the cwd
    /// walk cannot say WHICH session it found; the id can.
    func testSessionIdIsPreferredOverTheCwdWalk() {
        let otherSessionsCLI = ProcessHandle(pid: 7777, execPath: "/usr/local/bin/claude", cwd: "/Users/main/project")
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: otherSessionsCLI, desktopHandle: nil, bySessionHandle: cliProcess),
            signalSender: sender,
            trace: makeTrace()
        )

        _ = resolver.resume(sessionId: "S1", cwd: "/Users/main/project")

        XCTAssertEqual(sender.sent, [.init(signal: SIGCONT, pid: 9001)],
            "the id-pinned process must win; the cwd walk cannot tell two sessions in one directory apart")
    }

    /// An empty cwd no longer blocks the attempt: the id alone can pin the
    /// process, which is what a paused session usually has.
    func testEmptyCwdStillResumesWhenTheSessionIdResolves() {
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: nil, bySessionHandle: cliProcess),
            signalSender: sender,
            trace: makeTrace()
        )

        XCTAssertEqual(resolver.resume(sessionId: "S1", cwd: ""), .resumed(pid: 9001))
        XCTAssertEqual(sender.sent, [.init(signal: SIGCONT, pid: 9001)])
    }

    func testSignalFailureIsReportedNotSwallowed() {
        let sender = RecordingSignalSender()
        sender.throwOnNext = SignalError(errnoValue: ESRCH)
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: nil, bySessionHandle: cliProcess),
            signalSender: sender,
            trace: makeTrace()
        )

        let outcome = resolver.resume(sessionId: "S1", cwd: "/Users/main/project")

        XCTAssertEqual(outcome, .signalFailed(reason: "process_gone"))
        XCTAssertFalse(outcome.didResume)
    }

    // MARK: - The refusal reaches the owner

    /// End to end through the view model: the panel must NOT report a resume it
    /// did not get. The session stays paused and a plain-voice reason is set for
    /// the panel to render.
    func testRefusedResumeKeepsTheSessionPausedAndTellsTheOwner() async {
        let trace = makeTrace()
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace)
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: desktopHost, bySessionHandle: nil),
            signalSender: sender,
            trace: trace
        )
        vm.resumeHandler = { sessionId, cwd in resolver.resume(sessionId: sessionId, cwd: cwd) }

        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "Paused it.",
                      flaggedSessionId: "S1", flaggedSessionCwd: "/Users/main/project")
        XCTAssertTrue(vm.isPaused, "precondition: the session is paused")

        vm.resumePausedSession()
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(sender.sent.isEmpty, "nothing was signalled")
        XCTAssertTrue(vm.isPaused,
            "the session is still stopped, so the panel must still say paused")
        XCTAssertFalse(vm.isResuming)
        XCTAssertNotNil(vm.lastResumeFailure,
            "the owner must be told the resume did not happen, not left with a cleared pause")
        XCTAssertTrue(vm.lastResumeFailure?.contains("Could not resume") == true,
            "the reason must read as a failure; got: \(vm.lastResumeFailure ?? "nil")")
    }

    /// A successful resume clears the pause AND leaves no stale failure line.
    func testSuccessfulResumeClearsPauseAndAnyPriorFailureNotice() async {
        let trace = makeTrace()
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(bus: bus, trace: trace)
        let sender = RecordingSignalSender()
        let resolver = ResumeResolver(
            locator: FallbackLocator(cliHandle: nil, desktopHandle: nil, bySessionHandle: cliProcess),
            signalSender: sender,
            trace: trace
        )
        vm.resumeHandler = { sessionId, cwd in resolver.resume(sessionId: sessionId, cwd: cwd) }

        vm.flagRaised(severity: .high, action: .pause, reasoningPlain: "Paused it.",
                      flaggedSessionId: "S1", flaggedSessionCwd: "/Users/main/project")
        vm.resumePausedSession()
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(sender.sent, [.init(signal: SIGCONT, pid: 9001)])
        XCTAssertFalse(vm.isPaused)
        XCTAssertNil(vm.lastResumeFailure)
    }
}
