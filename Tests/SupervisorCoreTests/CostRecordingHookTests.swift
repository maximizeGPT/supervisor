import XCTest
@testable import SupervisorCore

/// The write side of the cost store used to be two `try?` call sites in
/// SupervisorApp, which discarded a thrown write with no trace. That is the
/// hardened read side's failure wearing the other face, and the more dangerous
/// direction: reads keep succeeding, today's total stops moving, and the daily
/// cap can never trip again.
final class CostRecordingHookTests: XCTestCase {

    private struct WriteFailed: Error {}

    private final class SpyStore: CostRecording, @unchecked Sendable {
        var failing = false
        private(set) var writes = 0
        private let lock = NSLock()

        func recordHaiku(inputTokens: Int, outputTokens: Int, costUSD: Double, on date: Date) throws {
            lock.lock()
            let shouldFail = failing
            writes += 1
            lock.unlock()
            if shouldFail { throw WriteFailed() }
        }
    }

    private final class HealthSpy: @unchecked Sendable {
        private(set) var edges: [Bool] = []
        private let lock = NSLock()
        func record(_ failing: Bool) {
            lock.lock(); edges.append(failing); lock.unlock()
        }
    }

    private func tempTrace() -> (TraceLog, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-hook-\(UUID()).log")
        return (TraceLog(path: path), path)
    }

    private let usage = AnthropicUsage(input_tokens: 1000, output_tokens: 100)

    func testASuccessfulWriteReportsNothing() {
        let store = SpyStore()
        let health = HealthSpy()
        let (trace, _) = tempTrace()
        let hook = CostRecordingHook(store: store, trace: trace,
                                     onWriteHealthChanged: { health.record($0) })

        hook.record(model: "claude-haiku-4-5", usage: usage)
        XCTAssertEqual(store.writes, 1)
        XCTAssertTrue(health.edges.isEmpty, "a working ledger is not news")
    }

    /// The defect itself: a thrown write must not vanish.
    func testAFailedWriteIsTracedInsteadOfSwallowed() throws {
        let store = SpyStore()
        store.failing = true
        let (trace, path) = tempTrace()
        let hook = CostRecordingHook(store: store, trace: trace)

        hook.record(model: "claude-haiku-4-5", usage: usage)
        trace.sync()

        let log = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(log.contains("cost_store_unwritable"), log)
        XCTAssertTrue(log.contains("cap"), "the trace has to say what the consequence is, not just that a write failed")
    }

    /// One page per streak. A read-only disk breaks every write, and one page
    /// per triage tick is how the owner learns to mute the channel.
    func testAPersistentFailurePagesOnceNotPerCall() {
        let store = SpyStore()
        store.failing = true
        let health = HealthSpy()
        let (trace, _) = tempTrace()
        let hook = CostRecordingHook(store: store, trace: trace,
                                     onWriteHealthChanged: { health.record($0) })

        for _ in 0..<10 { hook.record(model: "claude-haiku-4-5", usage: usage) }
        XCTAssertEqual(health.edges, [true], "ten failed writes are one incident")
    }

    /// Recovery closes the streak, so a later break is a NEW edge and reports
    /// again rather than being swallowed by the first one.
    func testRecoveryClosesTheStreakSoALaterBreakReportsAgain() {
        let store = SpyStore()
        let health = HealthSpy()
        let (trace, _) = tempTrace()
        let hook = CostRecordingHook(store: store, trace: trace,
                                     onWriteHealthChanged: { health.record($0) })

        store.failing = true
        hook.record(model: "m", usage: usage)
        hook.record(model: "m", usage: usage)
        store.failing = false
        hook.record(model: "m", usage: usage)
        store.failing = true
        hook.record(model: "m", usage: usage)

        XCTAssertEqual(health.edges, [true, false, true])
    }

    /// The write failure is its own reason with its own dedupe key, so it can
    /// never be swallowed by a standing unreadable-store incident. They are
    /// different failures with different consequences.
    func testUnwritableIsADistinctIncidentFromUnreadable() {
        let unwritable = SystemEscalationEvent.triageDegraded(reason: .costStoreUnwritable)
        let unreadable = SystemEscalationEvent.triageDegraded(reason: .costStoreUnreadable)
        XCTAssertNotEqual(unwritable.kind, unreadable.kind)
        XCTAssertNotEqual(unwritable.body, unreadable.body)
    }

    /// The copy has to name the consequence that makes this the worse of the
    /// two: nothing pauses, so Supervisor keeps spending against a frozen
    /// total. Same house rules as every other page: no em dashes, no paths.
    func testUnwritableCopySaysSpendingContinues() {
        let body = SystemEscalationEvent.triageDegraded(reason: .costStoreUnwritable).body
        XCTAssertTrue(body.lowercased().contains("spending"), body)
        XCTAssertFalse(body.contains("\u{2014}"), "no em dashes: \(body)")
        XCTAssertFalse(body.contains("/Users"), "nothing path-shaped: \(body)")
    }
}
