// DogfoodDestructivePauseTests.swift
//
// Wave 4 headless dogfood — Scenario 1 (the highest-value one).
//
// USER STORY: I stepped away. Claude Code, mid-task, decides to run
// `rm -rf ~/Documents`. Supervisor must catch it and freeze the session
// BEFORE the command runs — with NO API key, NO Accessibility, NO display,
// and (critically) NO model call at all. This is the deterministic catch
// path, the one protection that must work even when the network is dead
// and the key is expired.
//
// This drives the REAL pipeline end to end, offline:
//
//   JSONL written (fresh ts)
//     → real SessionDiscovery → real SessionTail (kqueue)
//       → real EventParser → real EventBus
//         → real TriageEngine  (DeterministicCatch fires BEFORE any client call)
//           → onDecision
//             → real FlagStore (real SQLite)            [flag row persisted]
//             → real InterventionRouter
//                 → CapturingSignalSender               [SIGSTOP to the GROUP]
//                 → real RecoveryDocWriter (temp dir)   [handoff doc written]
//             → real HoverViewModel                     [.flagged(.high, .pause)]
//
// The LLMClient is wired with a request-COUNTING URLProtocol that always
// fails; the assertion `modelCallCount == 0` is the proof the catch fired
// with zero model spend. EndToEndPipelineTests covers the mocked-MODEL
// path (chmod -R, which is not on the catch list); this covers the
// deterministic path which needs no key at all.

import XCTest
import Combine
import Darwin
@testable import SupervisorCore

@MainActor
final class DogfoodDestructivePauseTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-dogfood-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CountingFailURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testDestructiveRmRfPausesTheSessionOfflineWithNoModelCall() async throws {
        // -- Build the world (offline: no key, no AX, no display) ---------

        let projectsDir = tempDir.appendingPathComponent("projects")
        let projectHashDir = projectsDir.appendingPathComponent("-Users-test")
        try FileManager.default.createDirectory(at: projectHashDir, withIntermediateDirectories: true)

        let recoveryDir = tempDir.appendingPathComponent("recovery")

        let db = try SupervisorDatabase(path: tempDir.appendingPathComponent("supervisor.sqlite"))
        let sessionStore = SessionStore(database: db)
        let flagStore = FlagStore(database: db)

        let trace = TraceLog(path: tempDir.appendingPathComponent("trace.log"))
        let bus = EventBus(trace: trace)

        // A client whose transport COUNTS every request and always fails.
        // The deterministic catch must fire before this is ever touched, so
        // the count stays 0 — the offline proof.
        let client = LLMClient(
            provider: .anthropic,
            apiKey: "no-key-needed-for-the-catch",
            redactor: DefaultRedactor(),
            baseURL: URL(string: "https://mock.anthropic.test")!,
            session: countingSession(),
            traceLog: trace
        )

        // Long ack-debounce so the auto-acknowledge timer can't flip the
        // flagged state back to idle mid-assertion.
        let hoverVM = HoverViewModel(bus: bus, trace: trace, acknowledgeDebounceDuration: 3600)

        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: "claude-haiku-4-5-20251001",
            windowSize: 30,
            trace: trace
        )

        // The router as wired in production for the signal path — with a
        // capturing sender (so we assert the SIGSTOP without touching a real
        // process) and a real RecoveryDocWriter aimed at a temp dir.
        let sender = CapturingSignalSender()
        let notifier = CapturingNotifier()
        let recoveryWriter = RecoveryDocWriter(directory: recoveryDir, trace: trace)
        let router = InterventionRouter(
            notifier: notifier,
            // session-id match resolves THIS session's CLI process (cwd=$HOME
            // shape, non-desktop) so the signal targets it, never Claude Desktop.
            locator: StubLocator(sessionHandle: ProcessHandle(
                pid: 4242, execPath: "/usr/local/bin/claude", cwd: "/Users/test")),
            signalSender: sender,
            injector: MockInjector(),
            recoveryDocWriter: recoveryWriter,
            humanActivity: StubHumanActivityProbe(idleSeconds: 999),
            trace: trace
        )

        // The exact wire from SupervisorApp's running state: flag → SQLite +
        // hover + router.
        let recorder = FlagRecorder()
        engine.onActivityChange = { activity in
            if case .flagged(let sev, let action, let plain) = activity {
                hoverVM.flagRaised(severity: sev, action: action, reasoningPlain: plain)
            }
        }
        engine.onDecision = { decision in
            let flag = StoredFlag(
                sessionId: decision.sessionId,
                category: decision.candidate.category,
                severity: decision.candidate.severity,
                action: decision.candidate.action,
                reasoningPlain: decision.candidate.reasoningPlain,
                reasoningTechnical: decision.candidate.reasoningTechnical,
                asymmetryNote: decision.candidate.asymmetryNote,
                evidenceUuids: [decision.triggeringEvent.toolUseId]
            )
            do {
                // Discovery already upserted the session row when it started the
                // tail, but the cwd is "<resolving>" until sessionStart lands;
                // upsert the resolved one so the FK + recovery doc read cleanly.
                try sessionStore.upsert(StoredSession(
                    id: decision.sessionId,
                    projectHash: "-Users-test",
                    cwd: decision.cwd ?? "/Users/test",
                    startedAt: Date(),
                    lastSeenAt: Date(),
                    jsonlPath: "\(projectHashDir.path)/\(decision.sessionId).jsonl"
                ))
                try flagStore.insert(flag)
                recorder.record(flag)
            } catch {
                recorder.recordError("\(error)")
            }
            // Fire the real intervention router (SIGSTOP + recovery doc).
            // Same MainActor hop the production onDecision wiring uses.
            Task { @MainActor in await router.dispatch(decision: decision) }
        }
        engine.start()
        defer { engine.stop() }

        let discovery = SessionDiscovery(
            claudeProjectsDir: projectsDir,
            bus: bus,
            sessionStore: sessionStore,
            trace: trace
        )
        discovery.start()
        defer { discovery.stop() }

        // -- Drive the wire: Claude Code appends an rm -rf ~/Documents ----

        let sessionId = "dogfood-pause-1"
        let iso = ISO8601DateFormatter()
        // FRESH timestamps: the engine's stale-event gate skips historical
        // events by design (see Scenario 2); a live destructive command must
        // carry a current timestamp.
        let t0 = iso.string(from: Date())
        let t1 = iso.string(from: Date().addingTimeInterval(0.5))
        let t2 = iso.string(from: Date().addingTimeInterval(1.0))
        let bashCommand = "rm -rf ~/Documents"
        let lines = [
            #"{"type":"queue-operation","timestamp":"\#(t0)","sessionId":"\#(sessionId)","cwd":"/Users/test","gitBranch":"main"}"#,
            #"{"type":"user","timestamp":"\#(t1)","sessionId":"\#(sessionId)","uuid":"u1","message":{"role":"user","content":"tidy up the scratch files please"}}"#,
            #"{"type":"assistant","timestamp":"\#(t2)","sessionId":"\#(sessionId)","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"\#(bashCommand)"}}]}}"#,
        ]
        let jsonl = projectHashDir.appendingPathComponent("\(sessionId).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: jsonl)
        discovery.probeNow()

        // -- Assert every offline protection landed ----------------------

        try await waitUntil(within: 5.0, "flag never persisted (errors: \(recorder.errors))") {
            recorder.flags.count == 1
        }

        // 1. Flag persisted to SQLite with the right category + pause action.
        let persisted = try flagStore.recent(sessionId: sessionId).first
        XCTAssertNotNil(persisted, "the destructive catch must persist a flag row")
        XCTAssertEqual(persisted?.category, "destructive_action_pending")
        XCTAssertEqual(persisted?.severity, .high)
        XCTAssertEqual(persisted?.action, .pause,
                       "an rm -rf of a home path must pause the session")
        XCTAssertTrue(persisted?.reasoningPlain.contains(bashCommand) ?? false,
                      "the plain reasoning must name the exact command; got: \(persisted?.reasoningPlain ?? "(nil)")")

        // 2. SIGSTOP recorded on the mock sender, to the PROCESS GROUP
        //    (Wave 3) and the session-id-confirmed PID (never the desktop).
        try await waitUntil(within: 3.0, "SIGSTOP never fired") { !sender.sent.isEmpty }
        XCTAssertEqual(sender.sent, [.init(signal: SIGSTOP, pid: 4242, group: true)],
                       "pause must SIGSTOP the process GROUP of the session-confirmed PID")

        // 3. A recovery doc was written to the temp dir before the signal.
        try await waitUntil(within: 3.0, "recovery doc never written") {
            (try? FileManager.default.contentsOfDirectory(at: recoveryDir, includingPropertiesForKeys: nil))?
                .contains { $0.pathExtension == "md" && $0.lastPathComponent.contains("pause") } ?? false
        }
        let recoveryDocs = try FileManager.default.contentsOfDirectory(at: recoveryDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(recoveryDocs.count, 1, "exactly one recovery doc should be written")
        let docBody = try String(contentsOf: recoveryDocs[0], encoding: .utf8)
        XCTAssertTrue(docBody.contains(bashCommand),
                      "the recovery doc must record the command that triggered the pause")
        XCTAssertTrue(docBody.contains("kill -CONT"),
                      "the recovery doc must give the user the resume command")

        // 4. HoverViewModel shows the flagged pause state — never a green
        //    "All clear" while the session is frozen.
        XCTAssertEqual(hoverVM.flagCount, 1)
        if case .flagged(let sev, let action, _) = hoverVM.activity {
            XCTAssertEqual(sev, .high)
            XCTAssertEqual(action, .pause)
        } else {
            XCTFail("hover activity should be .flagged(.high, .pause), got \(hoverVM.activity)")
        }

        // 5. THE offline proof: not one model call happened. The catch is
        //    100% deterministic and never spends a token or needs a key.
        XCTAssertEqual(CountingFailURLProtocol.requestCount, 0,
                       "the deterministic catch must fire with ZERO model calls")

        // 6. The banner outcome is a real pause with a recovery doc path —
        //    the moment-of-need surface points somewhere actionable.
        let pauseOutcomes = notifier.outcomes.compactMap { outcome -> URL?? in
            if case .pauseSucceeded(let pid, let doc) = outcome {
                XCTAssertEqual(pid, 4242)
                return doc
            }
            return nil
        }
        XCTAssertEqual(pauseOutcomes.count, 1, "one pause banner must be posted")
        XCTAssertNotNil(pauseOutcomes.first ?? nil, "the pause banner must carry the recovery doc path")
    }

    // MARK: - Offline transport (counts calls, always fails)

    private func countingSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CountingFailURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private final class CountingFailURLProtocol: URLProtocol {
        nonisolated(unsafe) private static var _count = 0
        private static let lock = NSLock()
        static var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        static func reset() {
            lock.lock(); _count = 0; lock.unlock()
        }
        override class func canInit(with request: URLRequest) -> Bool {
            lock.lock(); _count += 1; lock.unlock()
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // MARK: - Local test doubles

    /// Resolves a session by its id (the reliable primitive the signal path
    /// prefers) and mirrors LiveProcessLocator's desktop-fallback gate.
    private struct StubLocator: ProcessLocator {
        var handle: ProcessHandle? = nil
        var sessionHandle: ProcessHandle? = nil
        func locate(targetCwd: String) -> ProcessHandle? { handle }
        func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle? {
            if !allowDesktopFallback, let h = handle,
               h.execPath.contains("Claude.app/Contents/MacOS/Claude") { return nil }
            return handle
        }
        func locate(bySessionId sessionId: String) -> ProcessHandle? { sessionHandle }
    }

    private final class CapturingSignalSender: SignalSender, @unchecked Sendable {
        struct Sent: Equatable { let signal: Int32; let pid: pid_t; var group: Bool = false }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
        func send(_ signal: Int32, to pid: pid_t) throws {
            lock.lock(); _sent.append(Sent(signal: signal, pid: pid, group: false)); lock.unlock()
        }
        func sendToGroup(_ signal: Int32, of pid: pid_t) throws {
            lock.lock(); _sent.append(Sent(signal: signal, pid: pid, group: true)); lock.unlock()
        }
    }

    private final class CapturingNotifier: Notifying, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcomes: [InterventionOutcome] = []
        var outcomes: [InterventionOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
        func post(decision: TriageDecision) async -> Notifier.Outcome { .posted }
        func postInterventionResult(decision: TriageDecision, outcome: InterventionOutcome) async -> Notifier.Outcome {
            lock.lock(); _outcomes.append(outcome); lock.unlock()
            return .posted
        }
    }

    private final class FlagRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _flags: [StoredFlag] = []
        private var _errors: [String] = []
        var flags: [StoredFlag] { lock.lock(); defer { lock.unlock() }; return _flags }
        var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }
        func record(_ f: StoredFlag) { lock.lock(); _flags.append(f); lock.unlock() }
        func recordError(_ e: String) { lock.lock(); _errors.append(e); lock.unlock() }
    }

    private func waitUntil(within seconds: TimeInterval, _ message: String,
                           _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTFail(message)
    }
}
