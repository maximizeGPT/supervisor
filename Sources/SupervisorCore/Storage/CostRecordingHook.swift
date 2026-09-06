// CostRecordingHook.swift — the one place a model call's spend is written,
// and the one place a failed write is noticed.
//
// The read side of the cost store was hardened to fail closed this release: a
// throw from `todayTotalUSD()` reports spend AT the cap rather than zero, and
// pages the owner that the ledger is unreadable.
//
// The WRITE side was two `try? hookCostStore.recordHaiku(...)` call sites in
// SupervisorApp, which discarded a thrown write with no trace at all. That is
// the same failure wearing the other face: a read-only database, a full disk,
// a locked file, and spend silently stops being counted. Today's total then
// stays frozen at whatever it reached before the failure, so the daily cap
// NEVER trips, and Supervisor keeps buying model calls against a number that
// stopped moving. The gate that exists to bound spend fails open, quietly, at
// exactly the moment the machine is already unhealthy.
//
// So writes go through here: traced distinctly, and escalated once per failure
// streak as `.triageDegraded(.costStoreUnwritable)`. Once per streak, not once
// per call, because a broken disk breaks every call and the owner needs one
// page, not one per triage tick.

import Foundation

/// The subset of `CostStore` this hook writes through. A protocol so the
/// failure behavior can be tested without a database.
public protocol CostRecording: Sendable {
    func recordHaiku(inputTokens: Int, outputTokens: Int, costUSD: Double, on date: Date) throws
}

extension CostStore: CostRecording {}

public final class CostRecordingHook: @unchecked Sendable {

    /// Whether the last write attempt failed. Guarded by `lock`; the recorder
    /// is called from whatever thread finished a model call.
    private var failing = false
    private let lock = NSLock()

    private let store: CostRecording
    private let trace: TraceLog
    /// Called on the EDGE into a failure streak and on the edge back out.
    /// `true` = writes are failing and spend is no longer being counted.
    private let onWriteHealthChanged: (@Sendable (_ failing: Bool) -> Void)?

    public init(
        store: CostRecording,
        trace: TraceLog = .shared,
        onWriteHealthChanged: (@Sendable (_ failing: Bool) -> Void)? = nil
    ) {
        self.store = store
        self.trace = trace
        self.onWriteHealthChanged = onWriteHealthChanged
    }

    /// Record one call's spend. Never throws: a model call that already
    /// happened must not be failed retroactively by a bookkeeping problem.
    /// The failure is surfaced instead of swallowed.
    public func record(model: String, usage: AnthropicUsage) {
        do {
            try store.recordHaiku(
                inputTokens: usage.input_tokens,
                outputTokens: usage.output_tokens,
                costUSD: TokenAccounting.costUSD(model: model, usage: usage),
                on: Date()
            )
            guard edge(to: false) else { return }
            trace.emit("cost", "cost store writable again; spend is being counted")
            onWriteHealthChanged?(false)
        } catch {
            // The error is never logged: a GRDB error can quote row contents,
            // and this line goes to a file the owner may paste into an issue.
            // Same rule as DailyCapGate's fail-closed trace.
            guard edge(to: true) else { return }
            trace.emit(
                "cost",
                "cap.degraded reason=cost_store_unwritable — a spend write FAILED; today's total has stopped moving, so the daily cap can no longer trip"
            )
            onWriteHealthChanged?(true)
        }
    }

    /// True when this call changed the failure state, so callers page on the
    /// edges only. A broken disk breaks every write; the owner needs one page,
    /// not one per triage tick.
    private func edge(to newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failing != newValue else { return false }
        failing = newValue
        return true
    }

    /// A `@Sendable` closure of the shape `LLMClient.costRecorder` expects.
    public var asCostRecorder: @Sendable (String, AnthropicUsage) -> Void {
        { [self] model, usage in record(model: model, usage: usage) }
    }
}
