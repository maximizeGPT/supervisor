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
// Signal-target safety (2026-07-02): pause/kill resolve THIS session's
// process by session-id first (the same primitive inject trusts), signal
// its PROCESS GROUP (so an already-forked `bash -c` child stops too), and
// NEVER send a POSIX signal to the shared Claude Desktop PID — desktop
// sessions get the per-conversation Stop-click, or degrade to notify.
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
    /// How many Claude Code sessions Supervisor currently considers live.
    /// Used to gate inject delivery: when >1 session is active AND the locator
    /// could not pin THIS session's own process (it fell back to the shared
    /// Claude desktop host, whose single window multiplexes sessions as tabs),
    /// a paste-to-frontmost could land in the WRONG session. Defaults to a
    /// single-session world `{ 1 }`, which disables the gate for tests and
    /// single-session users (no behavior change).
    private let activeSessionCount: () -> Int
    /// Owner policy (2026-06-13): never type into — or queue behind — a composer
    /// the human is actively using. The probe answers "how long since the human
    /// pressed a key"; if that's under `humanActiveThresholdSeconds`, the typing
    /// paths defer (the engine re-fires on the next idle tick, so nothing is lost).
    private let humanActivity: any HumanActivityProbe
    private let humanActiveThresholdSeconds: TimeInterval
    /// The record of what Supervisor itself typed into a session. Every inject
    /// and continue-dispatch is recorded here at type time so the triage can
    /// later tell its own injected turns apart from the owner's (the
    /// self-authorization gap). Optional: nil disables recording (older wiring
    /// and tests that don't exercise the gap) with no behavior change.
    private let injectionLedger: InjectionLedger?
    /// Proposal dedup (audit H5, 2026-07-02): a dispatcher that stabilizes at
    /// medium re-fires every idle tick, and without dedup each fire posts a
    /// fresh "Supervisor proposes …" banner — a suggestion every ~60s
    /// indefinitely. The router remembers which proposal texts (by normalized
    /// fingerprint) it surfaced per session and suppresses repeats inside this
    /// window; after it expires the same proposal may banner again (a
    /// reminder after 30 quiet minutes, not spam).
    private let proposalDedupWindowSeconds: TimeInterval
    /// Per-session record of recently surfaced medium/low continue banners:
    /// proposal fingerprint → when it was first posted. Pruned on every check.
    private var recentProposalBanners: [String: [UInt64: Date]] = [:]
    /// Injected clock for the dedup window; production uses Date(). Same
    /// pattern as TriageEngine's clock so tests drive time deterministically.
    private let now: @MainActor () -> Date
    private let trace: TraceLog

    public init(
        notifier: any Notifying,
        locator: any ProcessLocator,
        signalSender: any SignalSender = DarwinSignalSender(),
        injector: any Injector,
        recoveryDocWriter: RecoveryDocWriter? = nil,
        activeSessionCount: @escaping () -> Int = { 1 },
        humanActivity: any HumanActivityProbe = CGHumanActivityProbe(),
        humanActiveThresholdSeconds: TimeInterval = 2.0,
        injectionLedger: InjectionLedger? = nil,
        proposalDedupWindowSeconds: TimeInterval = 30 * 60,
        now: @escaping @MainActor () -> Date = { Date() },
        trace: TraceLog = .shared
    ) {
        self.notifier = notifier
        self.locator = locator
        self.signalSender = signalSender
        self.injector = injector
        self.recoveryDocWriter = recoveryDocWriter
        self.activeSessionCount = activeSessionCount
        self.humanActivity = humanActivity
        self.humanActiveThresholdSeconds = humanActiveThresholdSeconds
        self.injectionLedger = injectionLedger
        self.proposalDedupWindowSeconds = proposalDedupWindowSeconds
        self.now = now
        self.trace = trace
    }

    /// True when a real keystroke landed within the guard window — the human is
    /// at the keyboard right now. Both typing paths (inject + high-confidence
    /// continue) consult this and defer rather than steal focus or clobber a
    /// draft. The same instinct as wrong_trajectory's "back off within 30s of a
    /// user message": active human input IS the human steering.
    private func humanIsActivelyTyping(op: String, session: String) -> Bool {
        let idle = humanActivity.secondsSinceLastKeystroke()
        guard idle < humanActiveThresholdSeconds else { return false }
        trace.emit("router", "intervention.\(op).deferred reason=human_active idle=\(String(format: "%.1f", idle))s threshold=\(String(format: "%.1f", humanActiveThresholdSeconds))s session=\(session)")
        return true
    }

    /// The 2026-06-04 misroute guard. True when delivering into the resolved
    /// target risks the WRONG session: the locator fell back to a shared host
    /// (`handle.cwd != targetCwd` — a precise CLI match sets cwd == targetCwd,
    /// the Claude.app fallback sets cwd "/") AND more than one session is live.
    /// In that case paste-to-frontmost cannot be trusted to hit the session the
    /// dispatch is FOR — a landing-page dispatch once landed in the supervisor
    /// repo session. The caller degrades to a notify banner instead.
    private func targetUnconfirmedAcrossSessions(_ handle: ProcessHandle, targetCwd: String, sessionCount: Int) -> Bool {
        sessionCount > 1 && handle.cwd != targetCwd
    }

    /// Resolve the process to deliver into. Prefer an exact **session-id**
    /// match (a CONFIRMED target — safe to inject even with concurrent
    /// sessions, because the id pins WHICH one); fall back to the cwd walk,
    /// which the caller still gates with the multi-session check since cwd
    /// can't confirm the session (the `claude` proc cwd is usually the home
    /// dir, not the project). Returns nil when neither resolves. This is what
    /// turns "degrade because I can't tell which of your sessions this is for"
    /// into "inject into the right one."
    private func resolveInjectTarget(_ decision: TriageDecision, cwd: String, op: String) -> (handle: ProcessHandle, sessionConfirmed: Bool)? {
        if !decision.sessionId.isEmpty,
           let byId = locator.locate(bySessionId: decision.sessionId) {
            trace.emit("router", "intervention.\(op).target_by_session_id pid=\(byId.pid) session=\(decision.sessionId) exec=\(byId.execPath)")
            return (byId, true)
        }
        if let byCwd = locator.locate(targetCwd: cwd) {
            // The Claude.app desktop host can't be cwd-confirmed (one Electron
            // window multiplexing conversations), but the injector now targets
            // the right CONVERSATION by screenshot+OCR with confident-match-or-
            // notify. So a desktop host BYPASSES the cwd-era multi-session gate
            // and defers targeting to the injector, instead of pre-degrading
            // here (which is what blocked desktop answers entirely).
            let isDesktopHost = byCwd.execPath.contains("Claude.app/Contents/MacOS/Claude")
            if isDesktopHost {
                trace.emit("router", "intervention.\(op).desktop_host_deferred_to_injector pid=\(byCwd.pid)")
            }
            return (byCwd, isDesktopHost)
        }
        return nil
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
        guard let target = resolveInjectTarget(decision, cwd: cwd, op: "inject") else {
            trace.emit("router", "intervention.inject.degraded reason=locator_nil cwd=\(cwd)")
            await postInjectDegraded(decision, intendedText: text, reason: "locator_nil")
            return
        }
        let handle = target.handle
        // A session-id match IS the confirmation of WHICH session we're hitting,
        // so it bypasses the cwd-era multi-session gate. The cwd fallback can't
        // confirm the session, so it stays gated to avoid a cross-session paste.
        if !target.sessionConfirmed {
            let sessionCount = activeSessionCount()
            if targetUnconfirmedAcrossSessions(handle, targetCwd: cwd, sessionCount: sessionCount) {
                trace.emit("router", "intervention.inject.degraded reason=multi_session_unconfirmed_target sessions=\(sessionCount) cwd=\(cwd) handle_cwd=\(handle.cwd)")
                await postInjectDegraded(decision, intendedText: text, reason: "multi_session_unconfirmed_target")
                return
            }
        }
        // Human-active gate: about to synthesize keystrokes. If the human is
        // typing right now, don't steal focus or clobber their draft. Record the
        // dispatch as QUEUED (Piece 3) — a distinct "will send when Claude Code
        // is ready" state, not a failure and not silence. The loop re-fires on
        // the next idle tick and delivers once they pause.
        if humanIsActivelyTyping(op: "inject", session: decision.sessionId) {
            await postQueued(decision, head: text)
            return
        }
        // DESKTOP MCQ: an answer aimed at a Claude Desktop pane that's showing an
        // AskUserQuestion widget can't be delivered by composer paste — the widget
        // intercepts the input. Operate it directly (Other → type → Submit). Returns
        // true when it fully handled the answer (answered or degraded); false for a
        // non-MCQ / non-desktop target, so we fall through to the normal paste.
        if await attemptDesktopMCQ(decision, handle: handle, text: text) {
            return
        }
        do {
            // Record BEFORE typing (the self-authorization gap): the resulting
            // user turn can land in the JSONL and be triaged before any
            // delivery confirmation finishes, so the ledger must be ready
            // first. An injection that never lands never correlates — harmless.
            // This is what lets the triage label this turn [supervisor-injected]
            // instead of reading it back as owner authorization.
            // Provenance marker (2026-06-15): the driven agent — and any human
            // reading the transcript — must never mistake a Supervisor injection
            // for the operator. Record + inject the MARKED text so the ledger
            // correlates on exactly what lands in the JSONL.
            let markedText = SupervisorInjectionMarker.wrap(text)
            injectionLedger?.record(sessionId: decision.sessionId, text: markedText)
            let preSize = transcriptSize(sessionId: decision.sessionId)
            let bytes = try await injector.inject(text: markedText, claudeCodePID: handle.pid, targetWindowTitle: DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId) ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId) ?? decision.branch)
            // The injector returns keystroke bytes POSTED, not proof of delivery:
            // a paste into an unfocused composer vanishes and still returns a
            // count. Confirm a real turn actually appended to the transcript
            // before claiming success; otherwise degrade to an honest banner.
            if await injectLanded(sessionId: decision.sessionId, sincePreSize: preSize) {
                trace.emit("router", "intervention.inject.fired pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd) delivery=confirmed")
                _ = await notifier.postInterventionResult(
                    decision: decision,
                    outcome: .injectSucceeded(pid: handle.pid, bytes: bytes)
                )
            } else {
                trace.emit("router", "intervention.inject.degraded reason=paste_no_turn_landed pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd)")
                await postInjectDegraded(decision, intendedText: text, reason: "paste_no_turn_landed")
            }
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

    /// Desktop MCQ answer path. Returns true when it fully handled the answer —
    /// either operated the AskUserQuestion widget (Other → type → re-OCR Submit)
    /// or degraded to a notify because it's an MCQ it couldn't place. Returns false
    /// for a non-desktop host or a free-text question (no widget), so the caller
    /// falls through to the normal composer paste. Runs the OCR + clicks off-main.
    private func attemptDesktopMCQ(_ decision: TriageDecision, handle: ProcessHandle, text: String) async -> Bool {
        guard handle.execPath.contains("Claude.app/Contents/MacOS/Claude") else { return false }
        let title = DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId)
            ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId)
            ?? decision.branch
        guard let title, !title.isEmpty else { return false }
        let traceRef = trace
        let answer = text
        let preSize = transcriptSize(sessionId: decision.sessionId)
        // Record BEFORE operating the widget (the self-authorization gap): the
        // answer turn can land and be triaged before injectLanded returns, so the
        // ledger must already hold it or triage would read it back as owner input.
        // Harmless if the widget turns out non-operable — an unmatched ledger entry.
        injectionLedger?.record(sessionId: decision.sessionId, text: text)
        let outcome: MCQAnswerOutcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: DesktopConversationTargeter(trace: traceRef).answerMCQ(targetTitle: title, answer: answer))
            }
        }
        switch outcome {
        case .answered(let matched):
            // The Submit click can miss — confirm a real turn actually landed before
            // claiming success (the v0.9.0 "never claim an action you didn't take"
            // rule). Otherwise degrade to an honest banner so the owner can submit it.
            if await injectLanded(sessionId: decision.sessionId, sincePreSize: preSize) {
                trace.emit("router", "intervention.inject.fired method=desktop_mcq_click matched=\"\(matched.prefix(40))\" delivery=confirmed")
                _ = await notifier.postInterventionResult(decision: decision, outcome: .injectSucceeded(pid: handle.pid, bytes: text.utf8.count))
            } else {
                trace.emit("router", "intervention.inject.degraded reason=mcq_no_turn_landed matched=\"\(matched.prefix(40))\"")
                await postInjectDegraded(decision, intendedText: text, reason: "mcq_no_turn_landed")
            }
            return true
        case .unplaceable(let reason):
            trace.emit("router", "intervention.inject.degraded reason=desktop_mcq_unplaceable detail=\(reason)")
            await postInjectDegraded(decision, intendedText: text, reason: "mcq_unplaceable_\(reason)")
            return true
        case .notMCQ, .targetingFailed, .screenRecordingDenied:
            return false  // free-text / non-desktop / can't see → normal composer paste
        }
    }

    private func postInjectDegraded(_ decision: TriageDecision, intendedText: String, reason: String) async {
        _ = await notifier.postInterventionResult(
            decision: decision,
            outcome: .injectDegraded(intendedText: intendedText, reason: reason)
        )
    }

    /// Piece 3 (queued-as-delivered): the human is typing, so the router held
    /// the dispatch rather than delivering. Post the queued outcome — the hover
    /// shows a distinct "Queued — will send when Claude Code is ready" indicator
    /// instead of a misleading failure banner or silence. The loop re-fires on
    /// the next idle tick and records a separate fired/answered entry when it
    /// actually lands.
    private func postQueued(_ decision: TriageDecision, head: String) async {
        _ = await notifier.postInterventionResult(
            decision: decision,
            outcome: .queued(promptHead: String(head.prefix(80)))
        )
    }

    /// Byte size of the session transcript now, or 0 if not found. The baseline
    /// for confirming an inject actually produced a turn.
    private func transcriptSize(sessionId: String) -> UInt64 {
        guard let url = DesktopConversationTargeter.transcriptURL(sessionId: sessionId),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return UInt64(size)
    }

    /// Confirm an injected message became a REAL turn: a submit appends to the
    /// JSONL transcript, growing it past `preSize`. Polls ~3.6s. Returns false
    /// if nothing appended -- the keystrokes posted but no message landed (the
    /// all-day false-success bug: a paste into an unfocused composer). A missing
    /// transcript (preSize 0, size stays 0) also returns false -> honest degrade.
    private func injectLanded(sessionId: String, sincePreSize preSize: UInt64) async -> Bool {
        // No transcript to watch (a real Claude Code session always has its JSONL,
        // so this is a test session or an unexpected layout): we can't DISconfirm,
        // so don't punish a delivery we can't observe. The degrade path only fires
        // when a transcript exists and stays flat -- the real false-success case.
        guard DesktopConversationTargeter.transcriptURL(sessionId: sessionId) != nil else { return true }
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if transcriptSize(sessionId: sessionId) > preSize { return true }
        }
        return false
    }

    /// Proposal dedup (audit H5): true when this session already surfaced the
    /// same (normalized) proposal text within the dedup window — the caller
    /// suppresses the banner instead of re-posting it on every idle re-fire.
    /// The fingerprint is LoopController.proposalFingerprint (trimmed,
    /// lowercased, whitespace-collapsed — mirrors InjectionLedger.normalize),
    /// so cosmetic reflows still dedupe. The timestamp is recorded at FIRST
    /// posting and not refreshed on suppression, so the window measures
    /// "since the user last SAW this" and an expired entry re-arms.
    private func shouldSuppressDuplicateProposal(_ text: String, sessionId: String, op: String) -> Bool {
        guard !text.isEmpty else { return false }
        let nowTs = now()
        let fingerprint = LoopController.proposalFingerprint(text)
        // Prune expired entries so the per-session map stays bounded.
        var bySession = (recentProposalBanners[sessionId] ?? [:]).filter {
            nowTs.timeIntervalSince($0.value) < proposalDedupWindowSeconds
        }
        if let lastPosted = bySession[fingerprint] {
            recentProposalBanners[sessionId] = bySession
            trace.emit("router", "proposal_deduped op=\(op) session=\(sessionId) age=\(Int(nowTs.timeIntervalSince(lastPosted)))s window=\(Int(proposalDedupWindowSeconds))s")
            return true
        }
        bySession[fingerprint] = nowTs
        recentProposalBanners[sessionId] = bySession
        return false
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
            //
            // Dedup (audit H5): a dispatcher stuck at medium re-fires the
            // same proposal every idle tick — the first banner already told
            // the user; repeats within the window are suppressed.
            if shouldSuppressDuplicateProposal(proposal, sessionId: decision.sessionId, op: "continue.medium") {
                return
            }
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
            //
            // Dedup (audit H5): the low banner's body IS the justification;
            // a repeating one is the same spam shape as a repeated medium.
            if shouldSuppressDuplicateProposal(justification, sessionId: decision.sessionId, op: "continue.low") {
                return
            }
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
        guard let target = resolveInjectTarget(decision, cwd: cwd, op: "continue") else {
            trace.emit("router", "intervention.continue.degraded reason=locator_nil cwd=\(cwd)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
            return
        }
        let handle = target.handle
        // session-id match confirms the target → bypass the cwd-era gate.
        if !target.sessionConfirmed {
            let sessionCount = activeSessionCount()
            if targetUnconfirmedAcrossSessions(handle, targetCwd: cwd, sessionCount: sessionCount) {
                trace.emit("router", "intervention.continue.degraded reason=multi_session_unconfirmed_target sessions=\(sessionCount) cwd=\(cwd) handle_cwd=\(handle.cwd)")
                await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
                return
            }
        }
        // Human-active gate (see injectOrDegrade): defer typing while the human
        // is at the keyboard. Record the dispatch as QUEUED (Piece 3) so the
        // hover shows "will send when Claude Code is ready" rather than silently
        // holding it; the loop re-fires and delivers once they pause.
        if humanIsActivelyTyping(op: "continue", session: decision.sessionId) {
            await postQueued(decision, head: proposal)
            return
        }
        do {
            // Record BEFORE typing (the self-authorization gap): a dispatched
            // task prompt is a Supervisor-authored user turn; the ledger lets
            // the triage tell it apart from owner direction. See injectOrDegrade.
            // Provenance marker (2026-06-15): same as injectOrDegrade — a drive
            // proposal is Supervisor-authored, so mark it unmistakably and record
            // the marked form for ledger correlation.
            let markedText = SupervisorInjectionMarker.wrap(proposal)
            injectionLedger?.record(sessionId: decision.sessionId, text: markedText)
            let preSize = transcriptSize(sessionId: decision.sessionId)
            let bytes = try await injector.inject(text: markedText, claudeCodePID: handle.pid, targetWindowTitle: DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId) ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId) ?? decision.branch)
            // Confirm the proposal actually landed as a turn (see inject path).
            if await injectLanded(sessionId: decision.sessionId, sincePreSize: preSize) {
                trace.emit("router", "intervention.continue.fired pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd) delivery=confirmed")
                let head = String(proposal.prefix(80))
                _ = await notifier.postInterventionResult(
                    decision: decision,
                    outcome: .continueFired(pid: handle.pid, bytes: bytes, promptHead: head)
                )
            } else {
                trace.emit("router", "intervention.continue.degraded reason=paste_no_turn_landed pid=\(handle.pid) bytes=\(bytes) cwd=\(cwd)")
                await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
            }
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

    /// True when the handle is the SHARED Claude Desktop (Electron) process —
    /// the host every desktop conversation multiplexes into. Injection may
    /// target it (delivery goes through keystrokes), but a POSIX signal to it
    /// would freeze/quit the user's entire desktop app, so the signal paths
    /// must never use it.
    private func isDesktopHost(_ handle: ProcessHandle) -> Bool {
        handle.execPath.contains("Claude.app/Contents/MacOS/Claude")
    }

    private func signalOrDegrade(_ decision: TriageDecision, signal: Int32, opName: String) async {
        guard let cwd = decision.cwd, !cwd.isEmpty else {
            trace.emit("router", "intervention.\(opName).degraded reason=no_cwd_on_decision session=\(decision.sessionId)")
            await postNotify(decision)
            return
        }
        // TARGETING (2026-07-02 fix): resolve THIS session's process with the
        // session-id argv match — the same primitive the inject path trusts —
        // and signal THAT handle. The old code resolved it, used it only to
        // sniff the desktop host, threw it away, then re-ran the bare cwd
        // walk, whose 0-match branch falls back to Claude Desktop's shared
        // PID. A CLI `claude` process reports cwd=$HOME, so that walk missed
        // whenever the desktop app was running — and the SIGSTOP/SIGTERM
        // landed on Claude Desktop, freezing/quitting every conversation.
        let sessionTarget: ProcessHandle?
        if !decision.sessionId.isEmpty,
           let byId = locator.locate(bySessionId: decision.sessionId) {
            trace.emit("router", "intervention.\(opName).target_by_session_id pid=\(byId.pid) session=\(decision.sessionId) exec=\(byId.execPath)")
            sessionTarget = byId
        } else {
            sessionTarget = nil
        }
        // Signal target: the session-id-confirmed handle wins. Only when it's
        // absent fall back to the cwd walk — with the Claude.app fallback OFF,
        // because a locate result destined for kill(2) must never be the
        // shared desktop PID.
        let resolved = sessionTarget ?? locator.locate(targetCwd: cwd, allowDesktopFallback: false)

        // DESKTOP: Claude Desktop multiplexes every conversation into ONE
        // Electron process, so a real SIGSTOP/SIGTERM would freeze/kill ALL of
        // them. pause/kill there is a UI interrupt instead — click the TARGET
        // conversation's Stop button (per-conversation, click-only so it can't
        // bleed text). NEVER a POSIX signal.
        if let desktop = resolved, isDesktopHost(desktop) {
            await interruptDesktopOrDegrade(decision, handle: desktop, opName: opName)
            return
        }
        guard let handle = resolved else {
            // No signalable CLI process. If the session is desktop-hosted, the
            // plain cwd walk (fallback ON) resolves Claude.app → interrupt it
            // via the signal-free Stop-click.
            if let fallback = locator.locate(targetCwd: cwd) {
                if isDesktopHost(fallback) {
                    await interruptDesktopOrDegrade(decision, handle: fallback, opName: opName)
                    return
                }
                // A candidate the strict walk refused (defensive — production
                // suppression only ever withholds the desktop PID). Surface
                // the candidate PID, never signal it.
                trace.emit("router", "intervention.\(opName).degraded reason=unsignalable_candidate candidate_pids=\(fallback.pid) cwd=\(cwd)")
                await postNotify(decision)
                return
            }
            // Locator already logged its own discriminating tag
            // (locator.not_found / locator.ambiguous — which carries the
            // candidate pids — / locator.sysctl_failed /
            // locator.desktop_fallback_suppressed). The router's degraded
            // line gives the operational layer.
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
            // GROUP send (2026-07-02): SIGSTOP to the `claude` process alone
            // does not stop an already-forked child (`bash -c 'rm -rf …'`
            // keeps running). Signal the whole process group; the sender
            // falls back to the single pid when the group can't be resolved.
            try signalSender.sendToGroup(signal, of: handle.pid)
            trace.emit("router", "intervention.\(opName).fired pid=\(handle.pid) signal=\(signal) target=process_group cwd=\(cwd) recoveryDoc=\(recoveryDocPath?.path ?? "nil")")
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

    /// Desktop pause/kill: interrupt the TARGET conversation by clicking its Stop
    /// button — Claude Desktop can't be per-conversation signalled (one shared
    /// process). Resolves the conversation title the same way the inject path
    /// does, runs the OCR + click off-main (it blocks ~1.5s), then posts the same
    /// pause/kill-succeeded banner the signal path would, or degrades to a notify.
    private func interruptDesktopOrDegrade(_ decision: TriageDecision, handle: ProcessHandle, opName: String) async {
        let title = DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId)
            ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId)
            ?? decision.branch
        guard let title, !title.isEmpty else {
            trace.emit("router", "intervention.\(opName).degraded reason=desktop_no_target_title session=\(decision.sessionId) candidate_pids=\(handle.pid)")
            await postNotify(decision)
            return
        }
        let traceRef = trace
        let outcome: DesktopTargetingOutcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: DesktopConversationTargeter(trace: traceRef).interruptPane(targetTitle: title))
            }
        }
        switch outcome {
        case .focused(let matched):
            // Same recovery-doc + outcome-banner path as the signal route. pid is
            // the shared Claude.app pid here (informational — the interrupt was the
            // Stop-click, not a signal to that pid).
            let recoveryAction: RecoveryAction = (opName == "pause") ? .pause : .kill
            let recoveryDocPath = await recoveryDocWriter?.write(decision: decision, action: recoveryAction, pid: handle.pid)
            trace.emit("router", "intervention.\(opName).fired method=desktop_stop_click pid=\(handle.pid) matched=\"\(matched.prefix(40))\" recoveryDoc=\(recoveryDocPath?.path ?? "nil")")
            let outcomeMsg: InterventionOutcome = (opName == "pause")
                ? .pauseSucceeded(pid: handle.pid, recoveryDocPath: recoveryDocPath)
                : .killSucceeded(recoveryDocPath: recoveryDocPath)
            _ = await notifier.postInterventionResult(decision: decision, outcome: outcomeMsg)
        case .targetingFailed(let reason):
            trace.emit("router", "intervention.\(opName).degraded reason=desktop_interrupt_failed detail=\(reason)")
            await postNotify(decision)
        case .screenRecordingDenied:
            trace.emit("router", "intervention.\(opName).degraded reason=desktop_screen_recording_denied")
            await postNotify(decision)
        }
    }
}
