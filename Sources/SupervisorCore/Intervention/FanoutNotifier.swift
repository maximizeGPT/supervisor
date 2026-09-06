// FanoutNotifier.swift. Composite over `Notifying`.
//
// One primary channel plus zero or more secondaries, so remote delivery ADDS
// to the local banner instead of replacing it.
//
// Two invariants, and they are the whole reason this type exists rather than
// a second call inside `InterventionRouter`:
//
//   1. The primary always runs first and its outcome is the outcome the
//      router sees. Whatever a secondary does, the local banner is what "did
//      the user get told" means. The router's existing
//      `intervention.*.posted outcome=` lines keep meaning exactly what they
//      meant before.
//   2. A secondary can never prevent the primary. Secondaries run after, in
//      order, and their outcomes go to the trace log and nowhere else.
//
// The router is untouched by this file. It keeps taking `any Notifying` and
// keeps not knowing how many channels are behind it.

import Foundation

public final class FanoutNotifier: Notifying, @unchecked Sendable {

    private let primary: any Notifying
    private let secondaries: [any Notifying]
    private let trace: TraceLog

    public init(
        primary: any Notifying,
        secondaries: [any Notifying],
        trace: TraceLog = .shared
    ) {
        self.primary = primary
        self.secondaries = secondaries
        self.trace = trace
    }

    @discardableResult
    public func post(decision: TriageDecision) async -> Notifier.Outcome {
        let result = await primary.post(decision: decision)
        for secondary in secondaries {
            let outcome = await secondary.post(decision: decision)
            traceSecondary(outcome, kind: "notify")
        }
        return result
    }

    @discardableResult
    public func postInterventionResult(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) async -> Notifier.Outcome {
        let result = await primary.postInterventionResult(decision: decision, outcome: outcome)
        for secondary in secondaries {
            let secondaryOutcome = await secondary.postInterventionResult(
                decision: decision,
                outcome: outcome
            )
            traceSecondary(secondaryOutcome, kind: RemoteNotifyPolicy.outcomeKind(outcome))
        }
        return result
    }

    /// Only failures are worth a line here. Success and gate-skips are
    /// already traced by the secondary itself with far more detail, and
    /// duplicating them doubles the log for no diagnostic gain.
    private func traceSecondary(_ outcome: Notifier.Outcome, kind: String) {
        if case .failed(let reason) = outcome {
            trace.emit("notifier", "fanout.secondary_failed kind=\(kind) reason=\(reason)")
        }
    }
}
