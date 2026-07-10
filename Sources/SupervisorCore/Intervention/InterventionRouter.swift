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

import AppKit
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
    private let trace: TraceLog
    /// Injectable clock (mirrors LoopController) so tests can drive the delivery
    /// dedup window deterministically instead of waiting on wall-clock time.
    private let now: () -> Date
    /// Fix #12 (re-injection spam): after this many NON-landed attempts of the
    /// SAME text in a session within the dedup window, stop re-attempting. The
    /// threshold-crossing attempt already degraded to a banner, so later ticks
    /// suppress silently rather than re-typing (and re-stealing focus).
    private let maxDeliveryAttempts: Int
    /// Fix #12: within this window a CONFIRMED-delivered identical text is never
    /// re-sent (the live failure: an identical launch-readiness dispatch re-sent
    /// after the operator had already received it). Also the window over which
    /// attempt counts accumulate, and the age past which ledger entries are
    /// pruned so the map stays bounded.
    private let deliveryDedupWindow: TimeInterval

    /// Per-session, per-text record of how a specific injection has been
    /// delivered. Keyed by sessionId + normalized text (so a DIFFERENT proposal
    /// for the same session is never suppressed). This is what lets the router
    /// tell "already delivered, do not re-send" apart from "attempted but never
    /// landed, may retry boundedly" — the distinction the InjectionLedger can't
    /// make (it records at inject time regardless of landing). @MainActor, so a
    /// plain dictionary is safe.
    private struct DeliveryState {
        var attempts: Int
        var delivered: Bool
        var lastAttempt: Date
    }
    private var deliveryLedger: [String: DeliveryState] = [:]

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
        now: @escaping () -> Date = { Date() },
        maxDeliveryAttempts: Int = 2,
        deliveryDedupWindow: TimeInterval = 1800,
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
        self.now = now
        self.maxDeliveryAttempts = maxDeliveryAttempts
        self.deliveryDedupWindow = deliveryDedupWindow
        self.trace = trace
    }

    // MARK: - Delivery dedup (Fix #12)

    /// The delivery-ledger key for a (session, text) pair. Reuses the
    /// InjectionLedger's normalizer so a paste round-trip that reflows
    /// whitespace still maps to the same key.
    private func deliveryKey(sessionId: String, text: String) -> String {
        sessionId + "\u{1}" + InjectionLedger.normalize(text)
    }

    /// Prune delivery-ledger entries older than the dedup window so the map
    /// stays bounded. Called on every access.
    private func pruneDeliveryLedger() {
        let cutoff = now().addingTimeInterval(-deliveryDedupWindow)
        deliveryLedger = deliveryLedger.filter { $0.value.lastAttempt >= cutoff }
    }

    /// What the dedup gate decided for this (session, text).
    private enum DeliveryGate {
        /// Identical text already CONFIRM-landed within the window: skip silently.
        case alreadyDelivered
        /// The retry budget is spent within the window: stop re-attempting.
        case retryExhausted(attempts: Int)
        /// New / distinct / window-elapsed: proceed to deliver.
        case proceed
    }

    /// Consult (and prune) the delivery ledger BEFORE typing. Does NOT mutate
    /// the attempt count — that happens at `recordDeliveryAttempt`, right where
    /// we are actually about to type, so the human-active QUEUE short-circuit
    /// (which never types) can't consume the retry budget.
    private func deliveryGate(sessionId: String, text: String) -> DeliveryGate {
        pruneDeliveryLedger()
        let key = deliveryKey(sessionId: sessionId, text: text)
        guard let state = deliveryLedger[key] else { return .proceed }
        let withinWindow = now().timeIntervalSince(state.lastAttempt) < deliveryDedupWindow
        if state.delivered, withinWindow {
            return .alreadyDelivered
        }
        if state.attempts >= maxDeliveryAttempts, withinWindow {
            return .retryExhausted(attempts: state.attempts)
        }
        return .proceed
    }

    /// Increment the attempt count for this (session, text) at the point we are
    /// actually about to type. Call right where InjectionLedger.record is.
    private func recordDeliveryAttempt(sessionId: String, text: String) {
        let key = deliveryKey(sessionId: sessionId, text: text)
        var state = deliveryLedger[key] ?? DeliveryState(attempts: 0, delivered: false, lastAttempt: now())
        state.attempts += 1
        state.lastAttempt = now()
        deliveryLedger[key] = state
    }

    /// Mark this (session, text) as CONFIRM-delivered after injectLanded == true.
    private func markDelivered(sessionId: String, text: String) {
        let key = deliveryKey(sessionId: sessionId, text: text)
        guard var state = deliveryLedger[key] else { return }
        state.delivered = true
        state.lastAttempt = now()
        deliveryLedger[key] = state
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

    /// Injection harm screen (audit E1/E2): the single chokepoint every router
    /// typing path crosses BEFORE synthesizing keystrokes. The text Supervisor
    /// injects is model-generated by a cheap triage/answer/dispatch model whose
    /// context is attacker-influenceable (a malicious repo's build output, an
    /// echoed planted instruction, a stranger's GitHub issue body feeding the
    /// dispatch prompt), so it could be steered into `curl … | sh`, a force-push
    /// to main, `rm -rf ~`, or secret exfiltration — which we would otherwise
    /// type verbatim as an OWNER-provenance turn. Run the text through the
    /// deterministic `InjectionSafetyScreen` here; on `.block` return the reason
    /// (the caller does NOT type — it degrades to a notify banner surfacing the
    /// withheld suggestion for the human to judge by hand) and trace
    /// `injection_screen_blocked op=… reason=…`. On `.allow` return nil.
    private func injectionBlockReason(_ text: String, op: String, session: String) -> String? {
        switch InjectionSafetyScreen.screen(text) {
        case .allow:
            return nil
        case .block(let reason):
            trace.emit("router", "injection_screen_blocked op=\(op) reason=\(reason) session=\(session)")
            return reason
        }
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

    /// The single source of truth for "this handle is the shared Claude.app
    /// desktop host" — the Electron app that multiplexes ALL conversations and
    /// the app UI into one process. Both the inject path (which defers desktop
    /// delivery to the screenshot/OCR injector) and the signal path (which must
    /// NEVER SIGSTOP/SIGTERM this shared host: signal 17 to it froze the whole
    /// app and every session in it, 2026-06-19) test the SAME predicate here so
    /// the `execPath.contains(...)` string lives in exactly one place.
    private func isClaudeDesktopHost(_ handle: ProcessHandle) -> Bool {
        handle.execPath.contains("Claude.app/Contents/MacOS/Claude")
    }

    /// Resolve the target process for a decision. Prefer an exact **session-id**
    /// match (a CONFIRMED target: safe to act on even with concurrent sessions,
    /// because the id pins WHICH one); fall back to the cwd walk, which the
    /// caller still gates with the multi-session check since cwd can't confirm
    /// the session (the `claude` proc cwd is usually the home dir, not the
    /// project). `cwd` may be nil/empty: then ONLY the session-id path can
    /// resolve, which is exactly what keeps a no-cwd pause from silently
    /// degrading. Returns nil when neither resolves. Shared by the inject path
    /// and the signal (pause/kill) path so the resolution lives in one place.
    private func resolveTarget(_ decision: TriageDecision, cwd: String?, op: String) -> (handle: ProcessHandle, sessionConfirmed: Bool)? {
        if !decision.sessionId.isEmpty,
           let byId = locator.locate(bySessionId: decision.sessionId) {
            trace.emit("router", "intervention.\(op).target_by_session_id pid=\(byId.pid) session=\(decision.sessionId) exec=\(byId.execPath)")
            return (byId, true)
        }
        if let cwd = cwd, !cwd.isEmpty, let byCwd = locator.locate(targetCwd: cwd) {
            // The cwd fallback can't confirm WHICH session this is, so it is
            // marked unconfirmed and the caller applies its multi-session gate.
            return (byCwd, false)
        }
        return nil
    }

    /// Inject-path target resolution. Same precedence as `resolveTarget`, but
    /// the inject path treats the Claude.app desktop host as a CONFIRMED target:
    /// the injector now picks the right CONVERSATION by screenshot+OCR with
    /// confident-match-or-notify, so a desktop host BYPASSES the cwd-era
    /// multi-session gate and defers targeting to the injector, instead of
    /// pre-degrading here (which is what blocked desktop answers entirely). The
    /// signal path must NOT do this (it can't target a conversation inside
    /// Electron and SIGSTOP would freeze the whole app), so it uses the plain
    /// `resolveTarget` and lets `signalOrDegrade` degrade the desktop host.
    private func resolveInjectTarget(_ decision: TriageDecision, cwd: String, op: String) -> (handle: ProcessHandle, sessionConfirmed: Bool)? {
        guard let target = resolveTarget(decision, cwd: cwd, op: op) else { return nil }
        if !target.sessionConfirmed, isClaudeDesktopHost(target.handle) {
            trace.emit("router", "intervention.\(op).desktop_host_deferred_to_injector pid=\(target.handle.pid)")
            return (target.handle, true)
        }
        return target
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
        // Harm screen (audit E1/E2): withhold an unsafe model-generated answer
        // BEFORE any target resolution or typing. On a block we never inject —
        // degrade to a notify surfacing the withheld text so the human decides.
        if let blockReason = injectionBlockReason(text, op: "inject", session: decision.sessionId) {
            await postInjectDegraded(decision, intendedText: text, reason: "injection_screen_blocked_\(blockReason)")
            return
        }
        // Fix #12 dedup gate, OPT-IN: only consult the delivery ledger when the
        // candidate asked for it (the dispatcher's unbounded auto-dispatch). Most
        // injections self-govern repetition (watchdog nudgeCount, orchestrator
        // step attempts) or carry distinct text, so they bypass the gate entirely
        // and never populate the ledger. When opted in, the gate runs BEFORE
        // resolving a target or recording to the InjectionLedger: an identical
        // text that already landed must not be re-sent (the re-injection-spam +
        // focus-steal failure); a spent retry budget must stop re-attempting; a
        // DISTINCT text always proceeds.
        if decision.candidate.dedupDelivery {
            switch deliveryGate(sessionId: decision.sessionId, text: text) {
            case .alreadyDelivered:
                // It landed once already within the window — re-delivery is silent
                // (no inject, no banner). Do not touch the InjectionLedger.
                trace.emit("router", "intervention.inject.suppressed reason=already_delivered session=\(decision.sessionId)")
                return
            case .retryExhausted(let attempts):
                // The threshold-crossing attempt already degraded to a banner, so
                // later ticks suppress silently (trace only) — no re-banner-spam,
                // no repeated focus-stealing.
                trace.emit("router", "intervention.inject.suppressed reason=retry_budget_exhausted attempts=\(attempts) session=\(decision.sessionId)")
                return
            case .proceed:
                break
            }
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
        do {
            // Record BEFORE typing (the self-authorization gap): the resulting
            // user turn can land in the JSONL and be triaged before any
            // delivery confirmation finishes, so the ledger must be ready
            // first. An injection that never lands never correlates — harmless.
            // This is what lets the triage label this turn [supervisor-injected]
            // instead of reading it back as owner authorization. Per the
            // no-stamp decision the injection carries NO in-text banner; the
            // ledger is the sole provenance channel. Pass the body through
            // `wrap` (a clean passthrough that also strips any legacy banner)
            // and record exactly that, so the ledger correlates on the precise
            // text that lands in the JSONL.
            let markedText = SupervisorInjectionMarker.wrap(text)
            // Fix #12: for opt-in decisions only, count this as a delivery ATTEMPT
            // now (right where we type), not in the dedup gate — so the
            // human-active queue short-circuit above (which never types) doesn't
            // consume the retry budget. Keyed on the un-marked `text` so it
            // matches the gate's key on later ticks. Non-opt-in decisions never
            // populate the delivery ledger.
            if decision.candidate.dedupDelivery {
                recordDeliveryAttempt(sessionId: decision.sessionId, text: text)
            }
            injectionLedger?.record(sessionId: decision.sessionId, text: markedText)
            let preSize = transcriptSize(sessionId: decision.sessionId)
            let bytes = try await injector.inject(text: markedText, claudeCodePID: handle.pid, targetWindowTitle: DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId) ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId) ?? decision.branch)
            // The injector returns keystroke bytes POSTED, not proof of delivery:
            // a paste into an unfocused composer vanishes and still returns a
            // count. Confirm a real turn actually appended to the transcript
            // before claiming success; otherwise degrade to an honest banner.
            if await injectLanded(sessionId: decision.sessionId, sincePreSize: preSize) {
                // Fix #12: a CONFIRMED landing — for opt-in decisions, record it
                // so an identical re-send within the window is suppressed.
                if decision.candidate.dedupDelivery {
                    markDelivered(sessionId: decision.sessionId, text: text)
                }
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

    /// Fix #4a: the reason string the desktop injector raises when Screen
    /// Recording is off (InjectError.targetUnresolvable(reason:
    /// "screen_recording_denied") -> mapped to this by the catch blocks). When
    /// a degrade carries this reason, the surfaced banner must be SPECIFIC and
    /// ACTIONABLE (name the permission + where to grant it) rather than the
    /// generic "couldn't type the answer" copy, so a stalled plan does not look
    /// dead. Kept as one constant so the inject and continue paths agree.
    private static let screenRecordingDeniedReason = "target_unresolvable_screen_recording_denied"

    /// Put degraded-delivery text on the CLIPBOARD so the owner can just paste
    /// it (Cmd-V). Returns whether the write ACTUALLY succeeded —
    /// `NSPasteboard.setString` can return false (pasteboard-server hiccups,
    /// another writer racing the clearContents change count), and the outcome
    /// banner must only claim "it's on your clipboard" when it is. Empty text
    /// never touches (or clobbers) the clipboard and reports false. (Router is
    /// @MainActor, so NSPasteboard access is on the main thread.)
    private func copyDegradedTextToClipboard(_ text: String, op: String, reason: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        let copied = pb.setString(text, forType: .string)
        if copied {
            trace.emit("router", "\(op) degraded — copied \(text.count)-char text to clipboard for paste (reason=\(reason))")
        } else {
            trace.emit("router", "\(op) degraded — clipboard write FAILED (setString returned false); banner will embed the text instead (reason=\(reason))")
        }
        return copied
    }

    private func postInjectDegraded(_ decision: TriageDecision, intendedText: String, reason: String) async {
        // The answer couldn't be typed into the session. Clipboard-first: the old
        // fallback embedded the answer in the notification body, which macOS
        // truncates and does NOT make selectable — so a real answer was either
        // cut off or uncopyable. The clipboard carries the full text with zero
        // selection needed. `copied` keeps the banner honest when even the
        // clipboard write fails.
        let copied = copyDegradedTextToClipboard(intendedText, op: "inject", reason: reason)
        // Fix #4a: when the desktop inject degraded specifically because Screen
        // Recording is off, surface the actionable screen-recording banner
        // instead of the generic paste-fallback. This only fires when a step is
        // actually (re)injected (the drive path returns .none "no_ground_truth_yet"
        // on later ticks), so it surfaces once per stall, not every tick.
        let outcome: InterventionOutcome = (reason == Self.screenRecordingDeniedReason)
            ? .screenRecordingDenied(intendedText: intendedText, copiedToClipboard: copied)
            : .injectDegraded(intendedText: intendedText, reason: reason, copiedToClipboard: copied)
        _ = await notifier.postInterventionResult(decision: decision, outcome: outcome)
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
            // A genuine medium proposal never touches the clipboard: nothing
            // failed to deliver, so clobbering whatever the owner had copied
            // would be a cost with no delivery win. Only the HIGH-confidence
            // degrade path (continueDegradeToMedium) copies.
            _ = await notifier.postInterventionResult(
                decision: decision,
                outcome: .continueProposedMedium(
                    proposal: proposal,
                    justification: justification,
                    copiedToClipboard: false
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

        // Harm screen (audit E1/E2): the dispatch next_task_proposal is the
        // sharpest attacker-influenceable path (a stranger's GitHub issue body
        // can feed the dispatch prompt). Withhold an unsafe proposal BEFORE
        // typing — degrade to the propose-and-wait banner so the human sees the
        // suggestion and can act on it deliberately rather than it auto-firing.
        if injectionBlockReason(proposal, op: "continue", session: decision.sessionId) != nil {
            // Withheld-as-unsafe, NOT a delivery failure: do not plant an
            // attacker-influenceable proposal on the owner's clipboard where one
            // reflexive Cmd-V fires it. The banner still shows it for a
            // deliberate copy.
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification, copyToClipboard: false)
            return
        }

        // Fix #12 dedup gate, OPT-IN (see injectOrDegrade): only the dispatcher's
        // HIGH-confidence auto-dispatch sets dedupDelivery=true, so this is the
        // one path that actually deduplicates. An identical proposal that already
        // landed must not be re-dispatched into the same session (the live failure
        // was a re-sent launch-readiness dispatch), and a spent retry budget must
        // stop re-attempting. A DISTINCT proposal proceeds.
        if decision.candidate.dedupDelivery {
            switch deliveryGate(sessionId: decision.sessionId, text: proposal) {
            case .alreadyDelivered:
                trace.emit("router", "intervention.continue.suppressed reason=already_delivered session=\(decision.sessionId)")
                return
            case .retryExhausted(let attempts):
                trace.emit("router", "intervention.continue.suppressed reason=retry_budget_exhausted attempts=\(attempts) session=\(decision.sessionId)")
                return
            case .proceed:
                break
            }
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
            // No-stamp decision: the proposal carries NO in-text banner; the
            // ledger is the sole provenance channel. `wrap` is a clean
            // passthrough, so record + inject the identical text for correlation.
            let markedText = SupervisorInjectionMarker.wrap(proposal)
            // Fix #12: for opt-in decisions only, count the attempt at type time
            // (see injectOrDegrade), so the human-active queue short-circuit
            // doesn't burn the retry budget.
            if decision.candidate.dedupDelivery {
                recordDeliveryAttempt(sessionId: decision.sessionId, text: proposal)
            }
            injectionLedger?.record(sessionId: decision.sessionId, text: markedText)
            let preSize = transcriptSize(sessionId: decision.sessionId)
            let bytes = try await injector.inject(text: markedText, claudeCodePID: handle.pid, targetWindowTitle: DesktopConversationTargeter.readDesktopTitle(sessionId: decision.sessionId) ?? DesktopConversationTargeter.readAiTitle(sessionId: decision.sessionId) ?? decision.branch)
            // Confirm the proposal actually landed as a turn (see inject path).
            if await injectLanded(sessionId: decision.sessionId, sincePreSize: preSize) {
                // Fix #12: confirmed landing — for opt-in decisions, suppress
                // identical re-sends.
                if decision.candidate.dedupDelivery {
                    markDelivered(sessionId: decision.sessionId, text: proposal)
                }
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
            // Fix #4a: a continue-dispatch that degraded because Screen Recording
            // is off surfaces the SAME actionable banner the inject path uses
            // (name the permission + where to grant it), so the operator sees the
            // plan stalled on one toggle rather than reading a generic "wants your
            // approval" propose-and-wait. The proposal text rides along so it can
            // still be pasted by hand.
            if reason == Self.screenRecordingDeniedReason {
                // The banner tells the owner the answer is on the clipboard, so
                // actually PUT it there (this path previously claimed a clipboard
                // it never wrote) — and report the real write result.
                let copied = copyDegradedTextToClipboard(proposal, op: "continue", reason: reason)
                _ = await notifier.postInterventionResult(
                    decision: decision,
                    outcome: .screenRecordingDenied(intendedText: proposal, copiedToClipboard: copied)
                )
            } else {
                await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
            }
        } catch {
            trace.emit("router", "intervention.continue.degraded reason=unexpected_throw=\(error) pid=\(handle.pid) cwd=\(cwd)")
            await continueDegradeToMedium(decision, proposal: proposal, justification: justification)
        }
    }

    /// Inject failed but we still have the proposal — degrade to the
    /// medium-confidence banner so the user can paste manually. Delivery
    /// failures also put the proposal on the CLIPBOARD (same rationale as
    /// postInjectDegraded: a banner truncates and isn't selectable), and the
    /// outcome carries the REAL clipboard-write result so the banner never
    /// claims a paste that isn't there. `copyToClipboard: false` is for the
    /// harm-screen path, where the proposal is withheld as unsafe rather than
    /// undeliverable.
    private func continueDegradeToMedium(
        _ decision: TriageDecision,
        proposal: String,
        justification: String,
        copyToClipboard: Bool = true
    ) async {
        let copied = copyToClipboard
            ? copyDegradedTextToClipboard(proposal, op: "continue", reason: "degrade_to_medium")
            : false
        _ = await notifier.postInterventionResult(
            decision: decision,
            outcome: .continueProposedMedium(
                proposal: proposal,
                justification: justification,
                copiedToClipboard: copied
            )
        )
    }

    private func signalOrDegrade(_ decision: TriageDecision, signal: Int32, opName: String) async {
        let cwd = decision.cwd
        // Resolve the target like the inject path: prefer the session id (a
        // CONFIRMED single process, safe to signal a real CLI proc) and fall
        // back to the cwd walk only when a cwd is present. A pause with no cwd
        // but a resolvable session now FIRES instead of silently no-op-degrading
        // to notify (the "no_cwd_on_decision" regression). Only when NEITHER the
        // session id NOR a cwd can pin a process do we degrade, with a reason
        // that names what was actually missing, not a misleading bare "no cwd."
        guard let target = resolveTarget(decision, cwd: cwd, op: opName) else {
            // Locator already logged its own discriminating tag
            // (locator.not_found / locator.ambiguous / locator.sysctl_failed).
            // The router's degraded line gives the operational layer; the reason
            // distinguishes "couldn't resolve anything" (no session AND no cwd)
            // from "had inputs but the locator found nothing."
            let hasSession = !decision.sessionId.isEmpty
            let hasCwd = !(cwd?.isEmpty ?? true)
            let reason = (!hasSession && !hasCwd) ? "unresolvable_no_session_no_cwd" : "locator_nil"
            trace.emit("router", "intervention.\(opName).degraded reason=\(reason) session=\(decision.sessionId) cwd=\(cwd ?? "")")
            await postNotify(decision)
            return
        }
        let handle = target.handle
        // 2026-06-19 freeze fix: NEVER signal the shared Claude.app desktop host.
        // A SIGSTOP to that Electron process (the locator's claude_app_fallback)
        // froze the entire app and every conversation in it. Unlike the inject
        // path, the signal path cannot target a single conversation inside
        // Electron, so the desktop host is a hard DEGRADE: notify so the human
        // sees the (already-persisted) flag and acts manually. No recovery doc
        // and no pause/kill claim, because nothing was signaled. This guard runs
        // regardless of HOW the target resolved (session id or cwd): a session
        // id that points at the host still degrades, never signals it.
        if isClaudeDesktopHost(handle) {
            trace.emit("router", "intervention.\(opName).degraded reason=desktop_host_no_signal pid=\(handle.pid) cwd=\(cwd ?? "")")
            await postNotify(decision)
            return
        }
        // Same multi-session spirit as the inject path: a session-id match
        // CONFIRMS which session this is, so it bypasses the gate. The cwd
        // fallback can't confirm the session: when the locator fell back to a
        // host it could not pin to THIS session (handle.cwd != the target cwd)
        // and more than one session is live, signaling could hit the WRONG
        // session's process. Degrade to notify rather than risk it.
        if !target.sessionConfirmed, let cwd = cwd, !cwd.isEmpty {
            let sessionCount = activeSessionCount()
            if targetUnconfirmedAcrossSessions(handle, targetCwd: cwd, sessionCount: sessionCount) {
                trace.emit("router", "intervention.\(opName).degraded reason=multi_session_unconfirmed_target sessions=\(sessionCount) cwd=\(cwd) handle_cwd=\(handle.cwd)")
                await postNotify(decision)
                return
            }
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
            trace.emit("router", "intervention.\(opName).fired pid=\(handle.pid) signal=\(signal) cwd=\(cwd ?? "") recoveryDoc=\(recoveryDocPath?.path ?? "nil")")
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
            trace.emit("router", "intervention.\(opName).degraded reason=\(reason) pid=\(handle.pid) cwd=\(cwd ?? "")")
            await postNotify(decision)
        } catch {
            trace.emit("router", "intervention.\(opName).degraded reason=unexpected_throw=\(error) pid=\(handle.pid) cwd=\(cwd ?? "")")
            await postNotify(decision)
        }
    }
}
