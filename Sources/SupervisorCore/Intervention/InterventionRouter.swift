// InterventionRouter.swift — v0.1.4 Part A3.
//
// Single dispatch point for every triage decision. Reads
// `decision.candidate.action` (Haiku's recommended_action) and routes to
// one of three executors:
//
//   .notify → Notifier.post (banner only; existing v0.1.2 path)
//   .pause  → ProcessLocator + SignalSender(SIGSTOP). Degrades to notify
//             on any failure (locator nil, cwd missing, signal failed).
//   .kill   → ProcessLocator + SignalSender(SIGTERM). Same degradation
//             pattern as .pause. SIGKILL escalation deferred to a
//             follow-up — v0.1.4 ships SIGTERM only.
//
// `.inject` is in the FlagAction enum because it's the canonical next
// intervention type, but the inject executor is queued (see
// spikes/cgevent-bypass-ax-spike-README.md). For v0.1.4 the router
// routes `.inject` to the notify executor, preserving the user-visible
// flag while not yet doing the keystroke delivery.
//
// Every degradation path emits a discriminating trace tag so the
// `intervention.<op>.degraded` line carries the precise reason — useful
// for diagnosis when a user reports "Supervisor said it paused but
// nothing happened."

import Darwin
import Foundation

@MainActor
public final class InterventionRouter {

    private let notifier: any Notifying
    private let locator: any ProcessLocator
    private let signalSender: any SignalSender
    private let trace: TraceLog

    public init(
        notifier: any Notifying,
        locator: any ProcessLocator,
        signalSender: any SignalSender = DarwinSignalSender(),
        trace: TraceLog = .shared
    ) {
        self.notifier = notifier
        self.locator = locator
        self.signalSender = signalSender
        self.trace = trace
    }

    /// Dispatch a triage decision through the right executor. Always
    /// async-completes — never throws, never crashes on a failed signal.
    public func dispatch(decision: TriageDecision) async {
        switch decision.candidate.action {
        case .notify, .inject:
            // .inject deferred to follow-up; treat as notify until the
            // keystroke executor ships. The user sees the banner; the
            // flag.action column records the original Haiku recommendation.
            await postNotify(decision)
        case .pause:
            await signalOrDegrade(decision, signal: SIGSTOP, opName: "pause")
        case .kill:
            await signalOrDegrade(decision, signal: SIGTERM, opName: "kill")
        }
    }

    // MARK: - Executors

    private func postNotify(_ decision: TriageDecision) async {
        let outcome = await notifier.postInterventionResult(decision: decision, outcome: .notifyOnly)
        trace.emit("router", "intervention.notify.posted outcome=\(outcome)")
    }

    private func signalOrDegrade(_ decision: TriageDecision, signal: Int32, opName: String) async {
        guard let cwd = decision.cwd, !cwd.isEmpty else {
            trace.emit("router", "intervention.\(opName).degraded reason=no_cwd_on_decision session=\(decision.sessionId)")
            await postNotify(decision)
            return
        }
        guard let handle = locator.locate(targetCwd: cwd) else {
            // Locator already logged its own discriminating tag
            // (locator.not_found / locator.ambiguous / locator.sysctl_failed).
            // The router's degraded line gives the operational layer.
            trace.emit("router", "intervention.\(opName).degraded reason=locator_nil cwd=\(cwd)")
            await postNotify(decision)
            return
        }
        do {
            try signalSender.send(signal, to: handle.pid)
            trace.emit("router", "intervention.\(opName).fired pid=\(handle.pid) signal=\(signal) cwd=\(cwd)")
            // v0.1.4 Gap 1+2+3: post the outcome-aware banner so the
            // user has a visible signal of the successful intervention
            // and (for pause) the recovery instruction.
            let outcome: InterventionOutcome = (signal == SIGSTOP)
                ? .pauseSucceeded(pid: handle.pid)
                : .killSucceeded
            _ = await notifier.postInterventionResult(decision: decision, outcome: outcome)
        } catch let err as SignalError {
            let reason: String
            if err.isProcessGone {
                reason = "process_gone"
            } else if err.isPermissionDenied {
                reason = "permission_denied"
            } else {
                reason = "signal_failed_errno=\(err.errnoValue)"
            }
            trace.emit("router", "intervention.\(opName).degraded reason=\(reason) pid=\(handle.pid) cwd=\(cwd)")
            await postNotify(decision)
        } catch {
            trace.emit("router", "intervention.\(opName).degraded reason=unexpected_throw=\(error) pid=\(handle.pid) cwd=\(cwd)")
            await postNotify(decision)
        }
    }
}
