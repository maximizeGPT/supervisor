// InterventionRouter.swift — v0.3.0.
//
// Single dispatch point for every triage decision. Reads
// `decision.candidate.action` (Haiku's recommended_action) and routes
// to one of four executors:
//
//   .notify → Notifier.post (banner only; existing v0.1.2 path)
//   .inject → ProcessLocator + Injector(CGEventPost). v0.3.0+. Used
//             primarily for engineering-classified user questions
//             where Supervisor answers from PRINCIPLES.md. Degrades
//             to notify with the intended text in the banner so the
//             user can paste it manually.
//   .pause  → ProcessLocator + SignalSender(SIGSTOP). Degrades to notify
//             on any failure (locator nil, cwd missing, signal failed).
//   .kill   → ProcessLocator + SignalSender(SIGTERM). Same degradation
//             pattern as .pause. SIGKILL escalation deferred to a
//             follow-up — v0.1.4 ships SIGTERM only.
//
// Every degradation path emits a discriminating trace tag so the
// `intervention.<op>.degraded` line carries the precise reason — useful
// for diagnosis when a user reports "Supervisor said it injected but
// nothing happened."

import Darwin
import Foundation

@MainActor
public final class InterventionRouter {

    private let notifier: any Notifying
    private let locator: any ProcessLocator
    private let signalSender: any SignalSender
    private let injector: any Injector
    private let recoveryDocWriter: RecoveryDocWriter?
    private let trace: TraceLog

    public init(
        notifier: any Notifying,
        locator: any ProcessLocator,
        signalSender: any SignalSender = DarwinSignalSender(),
        injector: any Injector,
        recoveryDocWriter: RecoveryDocWriter? = nil,
        trace: TraceLog = .shared
    ) {
        self.notifier = notifier
        self.locator = locator
        self.signalSender = signalSender
        self.injector = injector
        self.recoveryDocWriter = recoveryDocWriter
        self.trace = trace
    }

    /// Dispatch a triage decision through the right executor. Always
    /// async-completes — never throws, never crashes on a failed signal.
    public func dispatch(decision: TriageDecision) async {
        switch decision.candidate.action {
        case .notify:
            await postNotify(decision)
        case .inject:
            await injectOrDegrade(decision)
        case .continue:
            // v0.4.0 Part B: the dispatch path. The TriageEngine has
            // already run the second-stage Dispatcher call and written
            // its results into the candidate (nextTaskProposal +
            // confidence + asymmetryNote). The router branches on
            // confidence:
            //   high   → inject the next_task_proposal into Claude Code
            //   medium → notify with the proposal text (propose-and-wait)
            //   low    → notify with the reasoning (supervisor can't pick)
            await routeContinue(decision)
        case .selfExtend:
            // v0.5.0: SelfExtender is primarily hook-driven. In-app, degrade
            // to notify — the hook handles the actual self-extension logic.
            trace.emit("router", "intervention.selfExtend.degrade_to_notify reason=in_app_not_implemented")
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

    /// v0.3.0: inject path. Requires (a) a non-empty suggestedInjectText
    /// on the candidate, (b) a resolvable PID from the locator, and
    /// (c) a supported hosting terminal. Any missing piece degrades to
    /// a notify-with-intended-text banner so the user can paste manually.
    private func injectOrDegrade(_ decision: TriageDecision) async {
        guard let text = decision.candidate.suggestedInjectText, !text.isEmpty else {
            trace.emit("router", "intervention.inject.degraded reason=no_inject_text session=\(decision.sessionId)")
            // No text means no banner-fallback either — fall through to
            // the plain notify path since there's nothing to surface.
            await postNotify(decision)
            return
        }
        guard let cwd = decision.cwd, !cwd.isEmpty else {
            trace.emit("router", "intervention.inject.degraded reason=no_cwd_on_decision session=\(decision.sessionId)")
            await postInjectDegraded(decision, intendedText: text, reason: "no_cwd_on_decision")
            return
        }
        guard let handle = locator.locate(targetCwd: cwd) else {
            trace.emit("router", "intervention.inject.degraded reason=locator_nil cwd=\(cwd)")
            await postInjectDegraded(decision, intendedText: text, reason: "locator_nil")
            return
        }
        do {
            let bytes = try await injector.inject(text: text, claudeCodePID: handle.pid, targetWindowTitle: decision.branch)
            trace.emit("router", "intervention.inject.fired pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd)")
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .injectSucceeded(pid: handle.pid, bytes: bytes)
            )
        } catch let err as InjectError {
            let reason: String
            switch err {
            case .noHostingApp:               reason = "no_hosting_app"
            case .unsupportedHost(let b):     reason = "unsupported_host_\(b)"
            case .activationFailed(let b):    reason = "activation_failed_\(b)"
            case .eventCreationFailed:        reason = "event_creation_failed"
            case .targetUnresolvable(let r):  reason = "target_unresolvable_\(r)"
            }
            trace.emit("router", "intervention.inject.degraded reason=\(reason) pid=\(handle.pid) cwd=\(cwd)")
            await postInjectDegraded(decision, intendedText: text, reason: reason)
        } catch {
            trace.emit("router", "intervention.inject.degraded reason=unexpected_throw=\(error) pid=\(handle.pid) cwd=\(cwd)")
            await postInjectDegraded(decision, intendedText: text, reason: "unexpected_throw")
        }
    }

    private func postInjectDegraded(_ decision: TriageDecision, intendedText: String, reason: String) async {
        _ = await notifier.postInterventionResult(
            decision: decision,
            outcome: .injectDegraded(intendedText: intendedText, reason: reason)
        )
    }

    /// v0.4.0 Part B: dispatch a worker_idle_post_completion flag. The
    /// engine has already populated `nextTaskProposal` (the prompt to
    /// inject) and `confidence` (which decides whether to inject vs.
    /// surface). asymmetryNote carries the dispatcher's justification —
    /// it lands in the low/medium banner so the user sees WHY supervisor
    /// went quiet or proposed this specific task.
    private func routeContinue(_ decision: TriageDecision) async {
        let confidence = decision.candidate.confidence ?? "low"
        let proposal = decision.candidate.nextTaskProposal ?? ""
        let justification = decision.candidate.asymmetryNote ?? "(no justification)"

        switch confidence {
        case "high":
            await continueHighInjectOrDegrade(
                decision: decision,
                proposal: proposal,
                justification: justification
            )
        case "medium":
            // Propose-and-wait. Even if a high-confidence dispatch could
            // theoretically happen, medium means we DON'T inject — we
            // surface and let the user decide. Same path the spec calls
            // out as "propose and wait" from Part A.
            trace.emit("router", "intervention.continue.proposed_medium_confidence session=\(decision.sessionId) proposal_bytes=\(proposal.utf8.count)")
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .continueProposedMedium(
                    proposal: proposal,
                    justification: justification
                )
            )
        default:
            // .low (and anything else — defensive fallback). Surface the
            // dispatcher's reasoning so the user understands why
            // supervisor went quiet rather than just hanging.
            trace.emit("router", "intervention.continue.degraded_low_confidence session=\(decision.sessionId) reason=\"\(justification.prefix(120))\"")
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .continueLowConfidence(reasoning: justification)
            )
        }
    }

    /// High-confidence dispatch — actually CGEventPost the next prompt
    /// into Claude Code. On any locator/injector failure, degrade to
    /// the medium-confidence propose-and-wait banner so the user can
    /// paste the proposal themselves. Per the v0.4.0 Part B spec:
    /// "If locator fails: degrade to medium-confidence behavior."
    private func continueHighInjectOrDegrade(
        decision: TriageDecision,
        proposal: String,
        justification: String
    ) async {
        guard !proposal.isEmpty else {
            // No proposal text means there's nothing to inject. This
            // shouldn't happen with confidence=high (Dispatcher
            // guarantees a proposal on high), but defend against it
            // anyway: degrade to a low-confidence banner with a
            // diagnostic justification.
            trace.emit("router", "intervention.continue.degraded reason=no_proposal_text_on_high_confidence session=\(decision.sessionId)")
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .continueLowConfidence(
                    reasoning: "Dispatcher returned high confidence with no proposal text. Falling back to user pick."
                )
            )
            return
        }

        guard let cwd = decision.cwd, !cwd.isEmpty else {
            trace.emit("router", "intervention.continue.degraded reason=no_cwd_on_decision session=\(decision.sessionId)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
            return
        }
        guard let handle = locator.locate(targetCwd: cwd) else {
            trace.emit("router", "intervention.continue.degraded reason=locator_nil cwd=\(cwd)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
            return
        }
        do {
            let bytes = try await injector.inject(text: proposal, claudeCodePID: handle.pid, targetWindowTitle: decision.branch)
            trace.emit("router", "intervention.continue.fired pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd)")
            let head = String(proposal.prefix(80))
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .continueFired(pid: handle.pid, bytes: bytes, promptHead: head)
            )
        } catch let err as InjectError {
            let reason: String
            switch err {
            case .noHostingApp:               reason = "no_hosting_app"
            case .unsupportedHost(let b):     reason = "unsupported_host_\(b)"
            case .activationFailed(let b):    reason = "activation_failed_\(b)"
            case .eventCreationFailed:        reason = "event_creation_failed"
            case .targetUnresolvable(let r):  reason = "target_unresolvable_\(r)"
            }
            trace.emit("router", "intervention.continue.degraded reason=\(reason) pid=\(handle.pid) cwd=\(cwd)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
        } catch {
            trace.emit("router", "intervention.continue.degraded reason=unexpected_throw=\(error) pid=\(handle.pid) cwd=\(cwd)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
        }
    }

    /// Inject failed but we still have the proposal — degrade to the
    /// medium-confidence banner so the user can paste manually.
    private func continueDegradeToMedium(
        _ decision: TriageDecision,
        proposal: String,
        justification: String
    ) async {
        _ = await notifier.postInterventionResult(
            decision: decision,
            outcome: .continueProposedMedium(
                proposal: proposal,
                justification: justification
            )
        )
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
        // v0.1.6: write the recovery doc BEFORE the signal lands. For
        // kill especially, the assistant process is gone post-SIGTERM
        // and we'd lose the ability to surface state. Write first; signal
        // second. The doc reads "Supervisor fired <action>" past-tense
        // because at the user's read-time, the signal has landed.
        let recoveryAction: RecoveryAction = (signal == SIGSTOP) ? .pause : .kill
        let recoveryDocPath = await recoveryDocWriter?.write(
            decision: decision,
            action: recoveryAction,
            pid: handle.pid
        )
        do {
            try signalSender.send(signal, to: handle.pid)
            trace.emit("router", "intervention.\(opName).fired pid=\(handle.pid) signal=\(signal) cwd=\(cwd) recoveryDoc=\(recoveryDocPath?.path ?? "nil")")
            // v0.1.4 Gap 1+2+3 + v0.1.6: post the outcome-aware banner
            // with the recovery doc path so the user has a visible
            // signal + a pointer to the handoff.
            let outcome: InterventionOutcome = (signal == SIGSTOP)
                ? .pauseSucceeded(pid: handle.pid, recoveryDocPath: recoveryDocPath)
                : .killSucceeded(recoveryDocPath: recoveryDocPath)
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
