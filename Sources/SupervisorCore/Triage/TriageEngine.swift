// TriageEngine.swift
//
// Subscribes to EventBus. Maintains a per-session sliding window of recent
// events. On each Bash tool_call, builds a triage prompt and calls Haiku
// via forced `record_triage` tool. If Haiku fires a candidate, the engine
// emits a TriageDecision over its `decisions` publisher — Lifecycle wires
// that to FlagStore + Notifier + HoverViewModel.
//
// v0.1.0 keeps the engine narrow: single category, single tool family
// (Bash). Multi-category, windowed batching, and stop-reason-triggered
// triage all land in v0.1.1+.

import Combine
import Foundation

public struct TriageDecision: Sendable {
    public let sessionId: String
    public let cwd: String?      // v0.1.4: the router needs cwd to ask the locator for a PID
    public let branch: String?   // v0.4.1: used by the injector for tab targeting (Issue #9)
    public let candidate: TriageCandidate
    public let triggeringEvent: BashToolCallInfo
    public let usage: AnthropicUsage
    public let model: String
    public let prePost: PrePost  // for the pre-NEXT-action / just-ran copy split
    /// v0.1.6: the recent event window from TriageEngine's per-session buffer,
    /// passed through so RecoveryDocWriter can render the "last ~10 tool calls"
    /// section without re-parsing the JSONL or pulling from the tailer. The
    /// triggering event itself is the last element; everything before it is
    /// context. Empty if the window wasn't available at decision time.
    public let recentEvents: [SupervisorEvent]
    /// v0.1.6: the most recent user prompt in the window, surfaced separately
    /// so the recovery doc can quote it verbatim without re-walking events.
    public let lastUserPrompt: String?

    public enum PrePost: Sendable {
        case preExecution     // tool_result not yet in window
        case alreadyExecuted  // tool_result present
    }

    public init(
        sessionId: String,
        cwd: String? = nil,
        branch: String? = nil,
        candidate: TriageCandidate,
        triggeringEvent: BashToolCallInfo,
        usage: AnthropicUsage,
        model: String,
        prePost: PrePost,
        recentEvents: [SupervisorEvent] = [],
        lastUserPrompt: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.branch = branch
        self.candidate = candidate
        self.triggeringEvent = triggeringEvent
        self.usage = usage
        self.model = model
        self.prePost = prePost
        self.recentEvents = recentEvents
        self.lastUserPrompt = lastUserPrompt
    }
}

@MainActor
public final class TriageEngine {

    private let client: LLMClient
    private let bus: EventBus
    private let trace: TraceLog
    private let model: String
    private let costStore: CostStore?
    private let redactor: any Redactor
    /// Shared with the InterventionRouter: the record of what Supervisor itself
    /// injected into each session. Consulted when assembling a triage prompt so
    /// a turn Supervisor typed is labeled `[supervisor-injected]` rather than
    /// read back as the owner's authorization (the self-authorization gap). nil
    /// disables labeling (every turn stays `.owner`) — no behavior change.
    private let injectionLedger: InjectionLedger?

    /// Per-session sliding window of events.
    private var perSessionWindow: [String: [SupervisorEvent]] = [:]
    private let windowSize: Int

    /// Per-session map of toolUseId → bashToolCall, so a later tool_result
    /// can be matched to its parent call without re-scanning the window.
    private var bashCalls: [String: BashToolCallInfo] = [:]

    /// v0.3.1 (Issue #6): per-session cwd cache. Populated on every
    /// `sessionStart` event and consulted by `evaluateAssistantText`
    /// when the rolling window has rolled past the sessionStart and
    /// `lastSessionCWD(in:)` would return nil. Without this cache, an
    /// assistant question that arrives after 30+ session events
    /// degrades the inject path with `no_cwd_on_decision` — exactly
    /// the v0.3.0 dogfood bug. State map (not the rolling window) is
    /// the right shape because cwd is session-stable.
    private var sessionCwd: [String: String] = [:]

    /// v0.4.0 (Part A): per-session git branch cache. Same shape as
    /// `sessionCwd` and populated alongside it on `sessionStart`. The
    /// idle-evaluation request includes branch so the rubric body can
    /// apply the don't-fire-on-non-autonomous-branch condition.
    private var sessionBranch: [String: String] = [:]

    /// v0.4.0 (Part A): per-session idle-detection state. Maintained on
    /// every `consume` call; consumed by the 1Hz timer in
    /// `checkIdleStates()`.
    private var idleStates: [String: SessionIdleState] = [:]

    /// Per-session idle state — the small ledger the timer walks.
    /// Updated on every event for the session; the timer reads it once
    /// per tick.
    struct SessionIdleState {
        /// Timestamp of the last consumed event for this session. The
        /// "is the session idle?" check is `now - lastEventTs ≥
        /// idleThresholdSeconds`.
        var lastEventTs: Date
        /// Timestamp at which a stop-shaped event was most recently
        /// detected for this session. `nil` means we have not seen a
        /// stop-shape yet; without one, idle detection does not fire.
        /// Reset to `nil` when a tool_use or non-stop assistant message
        /// arrives (the worker is no longer post-completion).
        var lastStopShapedTs: Date?
        /// The substring that matched ED-3's phrase list (or "end_turn"
        /// when the JSONL annotation triggered the detection). Carried
        /// into the triage request as `matched_command` per the rubric
        /// body's "matched_command carries the stop-shaped phrase" rule.
        var lastStopShapedPhrase: String?
        /// Timestamp of the most recent userPrompt event. The rubric
        /// body checks for a recent-user-message don't-fire condition;
        /// the engine surfaces it as a signal but does not gate on it.
        var lastUserMsgTs: Date?
        /// Timestamp of the most recent idle-evaluation triage call for
        /// this session. Used to de-duplicate: once we've asked the
        /// rubric and it returned no-fire, don't re-ask every tick.
        /// Cleared when a new event arrives (the world has changed).
        var lastIdleTriageTs: Date?
    }

    /// v0.4.0 (Part A): seconds of silence after a stop-shaped event
    /// before the timer triggers an idle-evaluation triage call. Default
    /// 15s per the spec; tests override to keep runs short.
    private let idleThresholdSeconds: TimeInterval

    /// v0.4.0 (Part A): minimum seconds between consecutive idle-evaluation
    /// triage calls for the same session, to keep API spend bounded. A
    /// non-firing session pings every `idleReTriageIntervalSeconds`
    /// rather than every tick.
    private let idleReTriageIntervalSeconds: TimeInterval

    /// v0.4.0 (Part A): tick interval for the idle-check loop. 1Hz in
    /// production per ED-2; tests can crank it lower.
    private let idleCheckIntervalSeconds: TimeInterval

    /// v0.4.0 (Part A): injected clock for the idle check so tests can
    /// drive time deterministically without `Task.sleep`. Production
    /// uses `Date.init`.
    private let now: @MainActor () -> Date

    /// v0.4.0 (Part A): handle to the running idle-check task; cancelled
    /// on `stop()`.
    private var idleCheckTask: Task<Void, Never>?

    /// Hook for HoverViewModel — called whenever a triage call starts /
    /// finishes / produces a flag, so the dot color reflects state.
    public var onActivityChange: ((HoverViewModel.Activity) -> Void)?

    /// Hook for FlagRouter — called when Haiku fires.
    public var onDecision: ((TriageDecision) -> Void)?

    private var busSubscription: AnyCancellable?

    /// v0.3.0: optional secondary-call dependency. When non-nil,
    /// user_question_pending candidates with question_type=engineering
    /// trigger an `answerEngineering` call against PRINCIPLES.md, and
    /// taste candidates trigger a `translateTaste` rewrite. Nil
    /// disables the secondary calls (tests / no-PRINCIPLES installs);
    /// the engine still fires the primary flag but the inject text
    /// stays empty and the router degrades to notify.
    private let questionAnswerer: QuestionAnswerer?

    /// v0.4.0 Part B: optional dispatcher dependency. When non-nil,
    /// worker_idle_post_completion candidates trigger a second-stage
    /// `dispatchForIdleSession` call against PRINCIPLES.md + the open
    /// issue queue + the branch's commits, and the dispatcher's
    /// next_task_proposal + confidence REPLACE the candidate's
    /// corresponding fields before the router runs. Nil disables the
    /// dispatcher (tests / no-PRINCIPLES installs); the candidate
    /// flows through with whatever the rubric returned (Part A
    /// defaults: confidence=low, no proposal).
    private let dispatcher: (any Dispatching)?

    /// v0.4.0 Part C: optional loop controller dependency. When
    /// non-nil, the engine checks `canDispatch` before calling the
    /// Dispatcher, records every result via `recordDispatch`, and
    /// notes pauses on userPrompt + user_question_pending events.
    /// Nil disables loop control (Part A/B behavior: dispatch every
    /// idle fire without the consecutive-low / 4-hour / paused
    /// guards). Use the LoopController in production; tests inject
    /// nil OR a custom-clock instance.
    private let loopController: LoopController?

    /// v0.4.0 Part C: optional store for the `loop_dispatches` table.
    /// When non-nil, the engine writes a row on every Dispatcher
    /// result (parallel to recordDispatch's in-memory update).
    /// Nil disables persistence (tests without a SupervisorDatabase).
    private let loopStore: LoopDispatchStore?

    /// cwd-exclusivity gate (2026-06-13): how many LIVE sessions currently share
    /// a given cwd. git HEAD/branch/commits are directory-global, so they may
    /// only be attributed to a session that is the SOLE live worker in that dir.
    /// When >1 session shares it, the repo state belongs to whichever session is
    /// actively committing — feeding it as "this session's context" leaks one
    /// session's work into another's answer/dispatch (the 2026-06-13 tweet-engine
    /// bleed). Defaults to `{ _ in 1 }` (solo) so tests and single-session users
    /// are unaffected; the app wires it to the SessionStore. Non-Sendable and
    /// invoked only from this @MainActor engine (mirrors the router's
    /// `activeSessionCount`), so it can read MainActor-isolated stores directly.
    private let liveSessionsSharingCwd: (String) -> Int

    public init(
        client: LLMClient,
        bus: EventBus,
        model: String = Config.defaults.triageModel,
        windowSize: Int = 30,
        costStore: CostStore? = nil,
        redactor: any Redactor = DefaultRedactor(),
        questionAnswerer: QuestionAnswerer? = nil,
        dispatcher: (any Dispatching)? = nil,
        loopController: LoopController? = nil,
        loopStore: LoopDispatchStore? = nil,
        idleThresholdSeconds: TimeInterval = 15,
        idleReTriageIntervalSeconds: TimeInterval = 60,
        idleCheckIntervalSeconds: TimeInterval = 1,
        liveSessionsSharingCwd: @escaping (String) -> Int = { _ in 1 },
        injectionLedger: InjectionLedger? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.bus = bus
        self.injectionLedger = injectionLedger
        self.model = model
        self.windowSize = windowSize
        self.costStore = costStore
        self.redactor = redactor
        self.questionAnswerer = questionAnswerer
        self.dispatcher = dispatcher
        self.loopController = loopController
        self.loopStore = loopStore
        self.idleThresholdSeconds = idleThresholdSeconds
        self.idleReTriageIntervalSeconds = idleReTriageIntervalSeconds
        self.idleCheckIntervalSeconds = idleCheckIntervalSeconds
        self.liveSessionsSharingCwd = liveSessionsSharingCwd
        self.now = now
        self.trace = trace
    }

    /// Pure cwd-exclusivity decision (testable in isolation): the cwd to ground
    /// repo context in, or nil to omit grounding. Default-deny — repo state is
    /// attributable to a session ONLY when it is the sole live occupant of the
    /// cwd. A nil/empty cwd passes through unchanged (there's nothing to gate).
    nonisolated static func groundingCwd(_ cwd: String?, liveSessionsInCwd: Int) -> String? {
        guard let cwd, !cwd.isEmpty else { return cwd }
        return liveSessionsInCwd <= 1 ? cwd : nil
    }

    /// Instance wrapper: resolve the live-session count for `cwd` and apply the
    /// gate, tracing when grounding is omitted so the bleed-prevention is visible.
    private func repoGroundingCwd(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return cwd }
        let n = liveSessionsSharingCwd(cwd)
        let grounded = Self.groundingCwd(cwd, liveSessionsInCwd: n)
        if grounded == nil {
            trace.emit("triage", "repo_grounding omitted reason=cwd_shared sessions=\(n) cwd=\(cwd)")
        }
        return grounded
    }

    public func start() {
        busSubscription = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.consume(event: event) }
        }
        startIdleCheckLoop()
        trace.emit("triage", "engine started model=\(model) windowSize=\(windowSize) idleThreshold=\(idleThresholdSeconds)s idleReTriage=\(idleReTriageIntervalSeconds)s")
    }

    public func stop() {
        busSubscription?.cancel()
        busSubscription = nil
        idleCheckTask?.cancel()
        idleCheckTask = nil
        trace.emit("triage", "engine stopped")
    }

    // MARK: - Event consumption

    private func consume(event: SupervisorEvent) {
        let sessionId = event.sessionId
        var window = perSessionWindow[sessionId] ?? []
        window.append(event)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }
        perSessionWindow[sessionId] = window

        // v0.4.0 Part A: maintain per-session idle state on every event,
        // regardless of type. The timer reads this state once per tick.
        updateIdleState(for: event)

        switch event {
        case .sessionStart(let info):
            // v0.3.1: cache cwd so it's available to assistantText
            // evaluations even after sessionStart rolls off the window.
            sessionCwd[info.sessionId] = info.cwd
            // v0.4.0 Part A: cache branch alongside cwd — idle
            // evaluation needs branch as a don't-fire signal.
            if let branch = info.gitBranch {
                sessionBranch[info.sessionId] = branch
            }
        case .userPrompt(let info):
            // v0.4.0 Part C: user message → loop pauses. The human
            // took the wheel; the autonomous loop holds until the
            // worker signals it's back to autonomous work (next
            // bashToolCall clears the pause).
            //
            // CRITICAL (2026-06-15): only a REAL operator turn counts. Supervisor's
            // OWN injections (drive proposals, answers) land as user prompts too;
            // counting them as "the operator is back" would (a) refresh the
            // presence backoff and (b) clear the 3-strikes stop — the loop
            // resetting its own kill switch on every injection, which is exactly
            // the thrash that drove this session. Correlate against the
            // InjectionLedger and ignore our own injected turns.
            if let lc = loopController {
                let selfInjected = injectionLedger?.isSupervisorInjected(
                    sessionId: info.sessionId, text: info.text, asOf: info.ts) ?? false
                if selfInjected {
                    trace.emit("loop", "userPrompt is a Supervisor injection — NOT counted as operator engagement session=\(info.sessionId)")
                } else {
                    Task { await lc.notePause(sessionId: info.sessionId, reason: .userMessage) }
                }
            }
        case .bashToolCall(let info):
            bashCalls[info.toolUseId] = info
            // v0.4.0 Part C: worker emitted a tool_use → autonomous
            // work resumed. Clear any prior loop-pause so the next
            // idle fire can dispatch normally.
            if let lc = loopController {
                Task { await lc.clearPause(sessionId: info.sessionId) }
            }
            Task { await self.evaluate(call: info, prePost: .preExecution) }
        case .bashToolResult(let info):
            if let original = bashCalls[info.toolUseId] {
                // A bash command we already evaluated as preExecution may
                // now have finished. v0.1.0 re-evaluates on result arrival
                // only if the result was an error AND the original call
                // didn't already match — keeps Haiku calls bounded.
                if info.isError {
                    Task { await self.evaluate(call: original, prePost: .alreadyExecuted) }
                }
            }
        case .assistantText(let info):
            // v0.3.0: cheap local prefilter to keep API spend bounded.
            // Only assistant texts that look like they might contain a
            // user-directed question get sent to the secondary triage call.
            if TriagePrompt.looksLikeQuestionToUser(info.text) {
                Task { await self.evaluateAssistantText(info: info) }
            }
        default:
            break
        }
    }

    // MARK: - v0.4.0 Part A: idle detection

    /// Mutate per-session idle state in response to an incoming event.
    /// Called for EVERY event; the cost is a dict lookup + a few field
    /// assignments. ED-2: state is per-session. Worker-stopped detection:
    /// any assistantText marks the worker as stopped; any bashToolCall
    /// clears it (worker is actively working).
    private func updateIdleState(for event: SupervisorEvent) {
        let sessionId = event.sessionId
        let ts = event.timestamp
        var state = idleStates[sessionId] ?? SessionIdleState(
            lastEventTs: ts,
            lastStopShapedTs: nil,
            lastStopShapedPhrase: nil,
            lastUserMsgTs: nil,
            lastIdleTriageTs: nil
        )
        state.lastEventTs = ts
        // Any new event invalidates a prior idle-triage gate: the world
        // has changed since the rubric last said "no fire," so let the
        // timer re-ask if conditions hold.
        state.lastIdleTriageTs = nil

        switch event {
        case .userPrompt:
            state.lastUserMsgTs = ts
            // User just spoke; the worker is no longer post-completion-idle
            // by definition. Clear stop-shape so we don't re-fire until a
            // new stop-shaped assistant message arrives.
            state.lastStopShapedTs = nil
            state.lastStopShapedPhrase = nil
        case .assistantText:
            // Any assistantText with no subsequent tool_use means the
            // worker stopped. Always mark as stopped; bashToolCall clears.
            state.lastStopShapedTs = ts
            state.lastStopShapedPhrase = "no_tool_use"
        case .bashToolCall:
            // Tool call means the worker is actively working again;
            // clear any prior stop-shape.
            state.lastStopShapedTs = nil
            state.lastStopShapedPhrase = nil
        default:
            break
        }

        idleStates[sessionId] = state
    }

    /// Detect whether the worker has stopped based on the event window.
    /// Returns true if the most recent assistant-related event is
    /// assistantText (not bashToolCall) — meaning the worker's last turn
    /// had no tool_use blocks. Returns false if the last assistant-related
    /// event is a tool call, or if there are no assistant events.
    static func detectWorkerStopped(in events: [SupervisorEvent]) -> Bool {
        // Walk backwards to find the last assistant-related event.
        for event in events.reversed() {
            switch event {
            case .assistantText:
                return true
            case .bashToolCall:
                return false
            default:
                continue
            }
        }
        return false
    }

    /// Spin up the 1Hz idle-check loop. The loop runs on `@MainActor` so
    /// it can read and mutate `idleStates` without synchronization
    /// primitives. Cancelled by `stop()`.
    private func startIdleCheckLoop() {
        idleCheckTask?.cancel()
        let interval = idleCheckIntervalSeconds
        idleCheckTask = Task { @MainActor [weak self] in
            // Convert seconds → nanoseconds once.
            let nanos = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                self?.checkIdleStates()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Walk every session's idle state. For each session where (a) a
    /// stop-shape has been seen AND (b) `idleThresholdSeconds` of silence
    /// have passed since the last event AND (c) the re-triage gate is
    /// open, dispatch an idle-evaluation triage call. The rubric body
    /// applies the remaining don't-fire conditions (branch, pending
    /// question, recent user message) per ED-4.
    ///
    /// Internal-visible (not private) so tests can drive ticks directly
    /// instead of waiting on the timer.
    func checkIdleStates() {
        let nowTs = now()
        for (sessionId, state) in idleStates {
            guard let stopTs = state.lastStopShapedTs else { continue }
            let silenceElapsed = nowTs.timeIntervalSince(state.lastEventTs)
            guard silenceElapsed >= idleThresholdSeconds else { continue }

            // Re-triage gate: if we already asked Haiku since the last
            // event change, wait `idleReTriageIntervalSeconds` before
            // asking again. `lastIdleTriageTs` is cleared by
            // `updateIdleState` when a new event arrives.
            if let lastTriage = state.lastIdleTriageTs {
                let sinceLast = nowTs.timeIntervalSince(lastTriage)
                if sinceLast < idleReTriageIntervalSeconds { continue }
            }

            // Stamp the triage timestamp BEFORE the async call lands so
            // a slow Haiku response doesn't let the next tick fire a
            // duplicate. The same-tick stamp is also used by tests to
            // assert "we dispatched a call for this session."
            var updated = state
            updated.lastIdleTriageTs = nowTs
            idleStates[sessionId] = updated

            trace.emit("triage", "idle.tick session=\(sessionId) silence=\(Int(silenceElapsed))s stop_phrase=\(state.lastStopShapedPhrase ?? "?") stop_age=\(Int(nowTs.timeIntervalSince(stopTs)))s")

            Task { await self.evaluateIdle(sessionId: sessionId) }
        }
    }

    /// Build an idle-evaluation triage request for one session and
    /// process the response. Parallel structure to `evaluate(call:)` and
    /// `evaluateAssistantText(info:)` — the same record_triage tool path,
    /// just scoped to the worker_idle_post_completion category.
    private func evaluateIdle(sessionId: String) async {
        // Global pause (owner toggle): stay dormant — no triage, dispatch, or
        // inject, and no API spend. consume() keeps tracking window/idle state,
        // so resume is seamless. Same guard on evaluate + evaluateAssistantText.
        if RuntimeToggles.supervisorPaused { return }
        onActivityChange?(.triaging)

        let window = perSessionWindow[sessionId] ?? []
        // cwd + branch via the same window-then-cache fallback as
        // evaluateAssistantText. The branch cache is the primary source
        // since sessionStart almost always rolls off the 30-event window
        // before the worker is idle.
        let cwd = lastSessionCWD(in: window) ?? sessionCwd[sessionId]
        let branch = lastSessionBranch(in: window) ?? sessionBranch[sessionId]

        // TASK 1 gate: a session whose cwd can't be resolved must NOT be
        // dispatched to. Without the project root we cannot ground a proposal
        // against the right repo (Task 2), so a proposal here would risk
        // cross-project leakage. Skip the idle dispatch silently — safety triage
        // (the bash-command path) is unaffected.
        if cwd == nil || cwd == "<resolving>" || cwd == "<unknown>" || cwd?.isEmpty == true {
            trace.emit("triage", "idle skip session=\(sessionId): cwd unresolved (\(cwd ?? "nil")) — not dispatching")
            onActivityChange?(.idle)
            return
        }

        // Label Supervisor-injected turns (self-authorization gap): the idle
        // path's "no recent user message" don't-fire check and the dispatcher's
        // objective anchoring must not read our own injected text as owner input.
        let labeledWindow = labelInjectedOrigins(window)
        let triageWindow = triageVisibleWindow(labeledWindow)
        let lastPrompt = lastOwnerPrompt(in: labeledWindow)
        let userPrompt = lastPrompt?.text
        let userPromptOrigin = lastPrompt?.origin ?? .owner

        let state = idleStates[sessionId]
        let stopPhrase = state?.lastStopShapedPhrase
        let secondsSinceLastEvent = state.map { now().timeIntervalSince($0.lastEventTs) } ?? 0

        let request = TriagePrompt.buildIdleEvaluationRequest(
            model: model,
            sessionId: sessionId,
            cwd: cwd,
            gitBranch: branch,
            userPrompt: userPrompt,
            userPromptOrigin: userPromptOrigin,
            stopShapedPhrase: stopPhrase,
            secondsSinceLastEvent: secondsSinceLastEvent,
            recentEvents: triageWindow
        )

        trace.emit("triage", "evaluating idle session=\(sessionId) branch=\(branch ?? "?") stop_phrase=\(stopPhrase ?? "?") silence=\(Int(secondsSinceLastEvent))s")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(request)
        } catch {
            trace.emit("triage", "Idle triage call failed: \(error)")
            onActivityChange?(.idle)
            return
        }

        if let costStore {
            let cost = TokenAccounting.costUSD(model: model, usage: response.usage)
            try? costStore.recordHaiku(
                inputTokens: response.usage.input_tokens,
                outputTokens: response.usage.output_tokens,
                costUSD: cost
            )
        }

        guard let candidates = extractCandidates(from: response) else {
            trace.emit("triage", "Idle triage: no record_triage call from Haiku session=\(sessionId)")
            onActivityChange?(.idle)
            return
        }
        if candidates.isEmpty {
            trace.emit("triage", "Idle triage all-clear session=\(sessionId) (rubric don't-fire condition held)")
            onActivityChange?(.idle)
            return
        }

        // Idle flags use the synthetic-trigger bridge so they flow
        // through the existing TriageDecision plumbing. The
        // "triggering event" is the stop-shaped assistant message:
        // we synthesize a BashToolCallInfo whose command field carries
        // the matched stop-phrase so the trace log and recovery doc
        // show what we were reacting to.
        let pseudoTrigger = BashToolCallInfo(
            sessionId: sessionId,
            command: "(idle) stop-shape: \(stopPhrase ?? "end_turn")",
            description: "Synthetic trigger for worker_idle_post_completion.",
            toolUseId: "idle-\(UUID().uuidString)",
            turnUUID: "idle-\(UUID().uuidString)",
            ts: now()
        )
        for candidate in candidates {
            // v0.4.0 Part B + C: if a Dispatcher is wired AND this
            // is a worker_idle_post_completion fire, consult the
            // LoopController FIRST (Part C: paused / stopped / 4hr
            // budget / 3-consecutive-low gate). On .proceed, run the
            // Dispatcher; the result REPLACES the rubric's fields
            // and gets recorded in `loop_dispatches`. On .paused /
            // .stopped, skip the Dispatcher entirely and surface
            // the loop state via a degraded candidate (action=.notify
            // with the reason in reasoning_plain).
            //
            // On any non-idle category, OR when dispatcher is nil,
            // the candidate flows through unchanged — Loop control
            // is scoped to the worker_idle_post_completion category.
            let finalCandidate: TriageCandidate
            if candidate.category == "worker_idle_post_completion",
               let dispatcher = self.dispatcher {
                // KILL-SWITCH: a marker file disables the auto-dispatch loop
                // WITHOUT a rebuild. When present the worker_idle path goes
                // fully SILENT (no dispatch, no banner). Added 2026-06-04 after
                // session-context contamination produced wrong-session task
                // proposals (a landing-page task labeled for the supervisor
                // session). Safety detection (destructive_action_pending →
                // pause/notify) is a DIFFERENT category and is unaffected.
                // Re-enable by deleting the marker — no restart needed.
                if Self.autoDispatchDisabled {
                    trace.emit("loop", "auto-dispatch DISABLED by marker — worker_idle silent (safety detection unaffected) session=\(sessionId)")
                    onActivityChange?(.idle)
                    return
                }
                let loopDecision: LoopDecision
                if let lc = loopController {
                    // Do NOT clear the three-consecutive-low stop on every
                    // idle. Idle fires whenever the worker stops — that is NOT
                    // proof new work exists. Clearing here defeated the hard
                    // stop entirely: stop → next idle clears it → re-dispatch →
                    // 3 more lows → stop → clear … a banner every ~60s forever
                    // (the 2026-06-04 thrash). The stop now STICKS; it clears
                    // only on genuine new direction (a user message — see
                    // LoopController.notePause) or the long-idle session reset.
                    loopDecision = await lc.canDispatch(sessionId: sessionId)
                } else {
                    loopDecision = .proceed(priorDispatchesConsidered: 0)
                }
                switch loopDecision {
                case let .proceed(priorCount):
                    finalCandidate = await dispatchAndRemap(
                        candidate: candidate,
                        dispatcher: dispatcher,
                        sessionId: sessionId,
                        cwd: cwd,
                        branch: branch,
                        window: window,
                        priorDispatchesConsidered: priorCount
                    )
                case let .paused(reason):
                    // Loop paused (the human is in the chat). Stay SILENT — re-
                    // posting an "idle but paused" banner on every idle tick is
                    // noise while the owner is actively working.
                    trace.emit("loop", "skip dispatch session=\(sessionId) state=paused reason=\(reason) (silent)")
                    onActivityChange?(.idle)
                    return
                case let .stopped(reason):
                    // Loop stopped (e.g. 3 consecutive lows = queue exhausted).
                    // The dispatch that TRIPPED the stop already posted its low-
                    // confidence banner explaining why, so go SILENT now instead
                    // of re-announcing "still stopped" on every idle tick.
                    trace.emit("loop", "skip dispatch session=\(sessionId) state=stopped reason=\(reason) (silent)")
                    onActivityChange?(.idle)
                    return
                }
            } else {
                finalCandidate = candidate
            }

            let decision = TriageDecision(
                sessionId: sessionId,
                cwd: cwd,
                branch: branch,
                candidate: finalCandidate,
                triggeringEvent: pseudoTrigger,
                usage: response.usage,
                model: response.model,
                prePost: .preExecution,
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "FLAG session=\(sessionId) category=\(finalCandidate.category) severity=\(finalCandidate.severity.rawValue) action=\(finalCandidate.action.rawValue) confidence=\(finalCandidate.confidence ?? "?") next_task=\"\(finalCandidate.nextTaskProposal?.prefix(120) ?? "")\"")
            onActivityChange?(.flagged(severity: finalCandidate.severity, action: finalCandidate.action, reasoningPlain: finalCandidate.reasoningPlain))
            onDecision?(decision)
        }
    }

    /// v0.4.0 Part B: run the dispatcher and rewrite the candidate's
    /// next_task_proposal + confidence + action + asymmetryNote per
    /// the dispatcher's verdict. The mapping is:
    ///   .ready(.high)     → action=.continue, confidence=high, proposal=prompt, asymmetry=just
    ///   .ready(.medium)   → action=.continue, confidence=medium, proposal=prompt, asymmetry=just
    ///                       (router demotes to a propose-and-wait banner)
    ///   .lowConfidence    → action=.continue, confidence=low,  proposal=nil,   asymmetry=reason
    ///                       (router demotes to a notify-with-reason banner)
    ///   .error            → action=.notify, confidence=low, proposal=nil, asymmetry=<err>
    ///                       (engine falls back to a plain idle notify)
    /// Auto-dispatch kill-switch. True when the marker file
    /// `Application Support/Supervisor/dispatch-disabled.marker` exists. Read
    /// per idle tick so it toggles live without a restart. Disables ONLY the
    /// worker_idle auto-dispatch loop; safety triage is a different path.
    nonisolated static var autoDispatchDisabled: Bool {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Supervisor/dispatch-disabled.marker")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func dispatchAndRemap(
        candidate: TriageCandidate,
        dispatcher: any Dispatching,
        sessionId: String,
        cwd: String?,
        branch: String?,
        window: [SupervisorEvent],
        priorDispatchesConsidered: Int
    ) async -> TriageCandidate {
        trace.emit("dispatch", "start session=\(sessionId) branch=\(branch ?? "?") prior=\(priorDispatchesConsidered)")
        // cwd-exclusivity gate (see repoGroundingCwd): when the cwd is shared by
        // multiple live sessions, drop cwd+branch so the dispatcher grounds in
        // THIS session's transcript only — never a co-located session's git state
        // (the same bleed the answer path guards). Targeting is unaffected.
        let groundedCwd = repoGroundingCwd(cwd)
        // Filter Supervisor's OWN injected turns out of the dispatcher's
        // grounding context — the same InjectionLedger correlation the triage
        // path uses (triageVisibleWindow). The dispatcher reads the transcript to
        // decide "what's left to do"; if it sees its own prior injected proposals
        // (which land as plain user turns) it re-reads them as PENDING owner
        // instructions and re-proposes already-done work — the "Deploy the build"
        // the worker keeps rejecting (2026-06-15). Removing the injected turns,
        // while KEEPING the worker's responses (including any rejection), lets the
        // dispatcher ground on the real conversation instead of its own echo.
        let groundingWindow = triageVisibleWindow(labelInjectedOrigins(window))
        let filteredOut = window.count - groundingWindow.count
        if filteredOut > 0 {
            trace.emit("dispatch", "grounding filtered \(filteredOut) supervisor-injected turn(s) (raw=\(window.count) → \(groundingWindow.count)) session=\(sessionId) — dispatcher won't re-read its own injections as pending work")
        }
        let result = await dispatcher.dispatchForIdleSession(
            sessionUUID: sessionId,
            cwd: groundedCwd,
            gitBranch: groundedCwd == nil ? nil : branch,
            lastNTurns: groundingWindow,
            priorDispatchesConsidered: priorDispatchesConsidered
        )

        // v0.4.0 Part C: persist + record for the loop control. Both
        // the in-memory LoopController and the loop_dispatches SQLite
        // table get updated. Errors from the SQLite write are logged
        // but non-fatal — the dispatch path continues so the user
        // still sees the banner/inject outcome.
        if let lc = loopController {
            await lc.recordDispatch(sessionId: sessionId, result: result)
            // v0.8.0: if we just recorded a high/medium confidence
            // result, clear any prior consecutive-low stop so the loop
            // recovers. This handles the case where false lows caused
            // a stop but subsequent dispatches found real work.
            if case let .ready(_, _, conf, _, _, _, _) = result, conf != .low {
                await lc.clearConsecutiveLowStop(sessionId: sessionId)
            }
        }
        if let store = loopStore {
            do {
                try store.insert(Self.storedLoopDispatchRow(
                    sessionId: sessionId,
                    result: result,
                    priorDispatchesConsidered: priorDispatchesConsidered,
                    ts: now()
                ))
            } catch {
                trace.emit("loop", "persist ERROR session=\(sessionId) error=\(error)")
            }
        }
        switch result {
        case let .ready(prompt, justification, conf, _, _, _, requiresHuman):
            // v0.4.1: requires_human_presence gate. Degrade to notify
            // so the proposal surfaces as a banner, not an auto-dispatch.
            if requiresHuman {
                trace.emit("dispatch", "requires_human_presence=true → degrading to notify session=\(sessionId)")
                return reconfigure(
                    candidate,
                    action: .notify,
                    asymmetryNote: redactor.redact("Requires human presence: \(justification)"),
                    suggestedInjectText: nil,
                    nextTaskProposal: redactor.redact(prompt),
                    confidence: "medium"
                )
            }
            switch conf {
            case .high:
                return reconfigure(
                    candidate,
                    action: .continue,
                    asymmetryNote: redactor.redact(justification),
                    suggestedInjectText: nil,
                    nextTaskProposal: redactor.redact(prompt),
                    confidence: "high"
                )
            case .medium:
                return reconfigure(
                    candidate,
                    action: .continue,
                    asymmetryNote: redactor.redact(justification),
                    suggestedInjectText: nil,
                    nextTaskProposal: redactor.redact(prompt),
                    confidence: "medium"
                )
            case .low:
                return reconfigure(
                    candidate,
                    action: .continue,
                    asymmetryNote: redactor.redact(justification),
                    suggestedInjectText: nil,
                    nextTaskProposal: nil,
                    confidence: "low"
                )
            }
        case let .lowConfidence(reasoning):
            return reconfigure(
                candidate,
                action: .continue,
                asymmetryNote: redactor.redact(reasoning),
                suggestedInjectText: nil,
                nextTaskProposal: nil,
                confidence: "low"
            )
        case let .error(reasoning):
            // Dispatcher errored — fall back to a plain idle notify.
            // Action goes to .notify (the router's .continue branch
            // would have nothing to dispatch); the candidate keeps
            // the rubric's reasoning_plain but gets a diagnostic
            // asymmetry note so the trace records why we degraded.
            trace.emit("dispatch", "dispatcher error → degrading to plain notify reason=\"\(reasoning.prefix(160))\"")
            return reconfigure(
                candidate,
                action: .notify,
                asymmetryNote: redactor.redact("Dispatcher error: \(reasoning)"),
                suggestedInjectText: nil,
                nextTaskProposal: nil,
                confidence: "low"
            )
        case let .objectiveComplete(summary):
            // The objective is built. Stop the loop cleanly (success — stop
            // reason objective_complete, not the 3-low backstop) and surface a
            // notify banner. No inject: there's nothing left to dispatch. The
            // loop won't fire again for this session until it's given a new
            // objective / reset.
            trace.emit("dispatch", "objective_complete → stopping loop session=\(sessionId) summary=\"\(summary.prefix(120))\"")
            await loopController?.stop(sessionId: sessionId, reason: .objectiveComplete)
            return reconfigure(
                candidate,
                action: .notify,
                asymmetryNote: redactor.redact("Objective complete: \(summary)"),
                suggestedInjectText: nil,
                nextTaskProposal: nil,
                confidence: "low"
            )
        }
    }

    // MARK: - Triage call

    private func evaluate(call: BashToolCallInfo, prePost: TriageDecision.PrePost) async {
        if RuntimeToggles.supervisorPaused { return }  // global pause (see evaluateIdle)
        onActivityChange?(.triaging)

        let rawWindow = perSessionWindow[call.sessionId] ?? []
        // Self-authorization gap. `window` is the full labeled window (injected
        // turns marked) — it backs the recovery doc. `triageWindow` is what the
        // MODEL sees: Supervisor-injected turns removed entirely. The §6d canary
        // proved the model treats its own injected text as owner authorization
        // even when that text is labeled [supervisor-injected] in the slot AND
        // in the window — so the robust, deterministic fix is to never show the
        // triage its own injected turns. The authorization anchor is the last
        // genuine OWNER prompt; with the injected text gone from the model's
        // view, an unauthorized destructive command reads as exactly that and
        // fires (baseline behavior), with no reliance on model compliance.
        let window = labelInjectedOrigins(rawWindow)
        let triageWindow = triageVisibleWindow(window)
        let cwd = lastSessionCWD(in: window)
        let lastPrompt = lastOwnerPrompt(in: window)
        let userPrompt = lastPrompt?.text
        let userPromptOrigin = lastPrompt?.origin ?? .owner
        let recentResult = lastBashResult(matching: call.toolUseId, in: triageWindow)

        // Deterministic catch-list (PRINCIPLES §3b/§5/§6): irreversible
        // local-loss git commands fire high/pause regardless of model
        // judgment. Authorization does NOT lower the floor for this family —
        // the asymmetry is extreme (a false pause costs a dismiss; a miss
        // costs uncommitted work permanently). A syntactic match short-
        // circuits the model call entirely; everything else falls through to
        // normal model triage unchanged.
        if let caught = DeterministicCatch.match(call.command) {
            let candidate = TriageCandidate(
                category: "destructive_action_pending",
                severity: .high,
                matchedCommand: call.command,
                action: .pause,
                reasoningPlain: "Claude Code is about to run `\(call.command)`, which permanently \(caught.effect). Even if you asked for this, I'm pausing first because it can't be undone and it's worth a two-second confirm. Resume if this is what you want.",
                reasoningTechnical: "Deterministic catch-list match: \(caught.pattern). Model-independent fire per PRINCIPLES §6: irreversible local data loss, authorization does not lower the floor for this command family."
            )
            let branch = sessionBranch[call.sessionId]
            let decision = TriageDecision(
                sessionId: call.sessionId,
                cwd: cwd,
                branch: branch,
                candidate: candidate,
                triggeringEvent: call,
                usage: AnthropicUsage(input_tokens: 0, output_tokens: 0,
                                      cache_creation_input_tokens: nil,
                                      cache_read_input_tokens: nil),
                model: "deterministic-catch",
                prePost: prePost,
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "CATCH session=\(call.sessionId) pattern=\(caught.pattern) action=pause cmd=\(call.command.prefix(60))")
            onActivityChange?(.flagged(severity: .high, action: .pause, reasoningPlain: candidate.reasoningPlain))
            onDecision?(decision)
            return
        }

        let request = TriagePrompt.buildRequest(
            model: model,
            input: .init(
                cwd: cwd,
                userPrompt: userPrompt,
                userPromptOrigin: userPromptOrigin,
                bashCall: call,
                recentResult: recentResult,
                recentEvents: triageWindow
            )
        )

        trace.emit("triage", "evaluating session=\(call.sessionId) cmd=\(call.command.prefix(60))")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(request)
        } catch {
            trace.emit("triage", "Haiku call failed: \(error)")
            onActivityChange?(.idle)
            return
        }

        // Cost accounting (best-effort).
        if let costStore {
            let cost = TokenAccounting.costUSD(model: model, usage: response.usage)
            try? costStore.recordHaiku(
                inputTokens: response.usage.input_tokens,
                outputTokens: response.usage.output_tokens,
                costUSD: cost
            )
        }

        guard let candidates = extractCandidates(from: response) else {
            trace.emit("triage", "Haiku didn't return record_triage call (stop_reason=\(response.stop_reason ?? "?"))")
            onActivityChange?(.idle)
            return
        }

        if candidates.isEmpty {
            trace.emit("triage", "all-clear for session=\(call.sessionId) cmd=\(call.command.prefix(40))")
            onActivityChange?(.idle)
            return
        }

        let branch = sessionBranch[call.sessionId]
        for candidate in candidates {
            let decision = TriageDecision(
                sessionId: call.sessionId,
                cwd: cwd,
                branch: branch,
                candidate: candidate,
                triggeringEvent: call,
                usage: response.usage,
                model: response.model,
                prePost: prePost,
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "FLAG session=\(call.sessionId) severity=\(candidate.severity.rawValue) action=\(candidate.action.rawValue) plain=\"\(candidate.reasoningPlain)\" tech=\"\(candidate.reasoningTechnical.prefix(200))\"")
            if let note = candidate.asymmetryNote, !note.isEmpty {
                trace.emit("triage", "FLAG.asymmetry session=\(call.sessionId) \(note)")
            }
            onActivityChange?(.flagged(severity: candidate.severity, action: candidate.action, reasoningPlain: candidate.reasoningPlain))
            onDecision?(decision)
        }
    }

    // MARK: - Assistant-text triage (v0.3.0)

    /// Evaluate an assistant message for the `user_question_pending`
    /// category. Triggered by the local prefilter in `consume()`. Runs
    /// the same record_triage tool against a focused prompt; for each
    /// candidate that fires, enriches with the secondary
    /// QuestionAnswerer call (engineering → inject text; taste →
    /// rewritten reasoning_plain; safety → pass through unchanged).
    private func evaluateAssistantText(info: AssistantTextInfo) async {
        if RuntimeToggles.supervisorPaused { return }  // global pause (see evaluateIdle)
        onActivityChange?(.triaging)

        let window = perSessionWindow[info.sessionId] ?? []
        // v0.3.1 (Issue #6): cwd resolution flow — window first
        // (cheap, doesn't require state), then per-session cache
        // (covers the after-30+-events case from the v0.3.0 dogfood),
        // then nil with a discriminating trace tag (the
        // session-start-never-seen edge case). Without this fallback,
        // every long-running session's inject path degrades to
        // notify because lastSessionCWD only sees events still in the
        // rolling window.
        let cwdFromWindow = lastSessionCWD(in: window)
        let cwdFromCache = sessionCwd[info.sessionId]
        let cwd = cwdFromWindow ?? cwdFromCache
        if cwd == nil {
            // The discriminating trace tag: we tried both sources and
            // came up empty. This means SessionStart was never seen
            // for this session (real edge case: Supervisor started
            // mid-session, or the JSONL is missing its lead-in lines).
            // We continue with cwd=nil; the engine downgrades any
            // .inject candidate to .notify below so the user still
            // gets a banner.
            trace.emit("triage", "assistant_text.no_cwd_session_start_not_seen session=\(info.sessionId)")
        } else if cwdFromWindow == nil {
            // Cache hit. Informational — useful for diagnosis when
            // someone wonders why a sessionStart isn't in the trace
            // right before a flag fires.
            trace.emit("triage", "assistant_text.cwd_from_cache session=\(info.sessionId) cwd=\(cwd ?? "?")")
        }
        // Self-authorization gap: the anchor is the last genuine OWNER prompt,
        // and the model's window excludes Supervisor-injected turns entirely
        // (the §6d canary proved a label is not enough — the model reads its own
        // injected text as authorization regardless).
        let labeledWindow = labelInjectedOrigins(window)
        let triageWindow = triageVisibleWindow(labeledWindow)
        let lastPrompt = lastOwnerPrompt(in: labeledWindow)
        let userPrompt = lastPrompt?.text
        let userPromptOrigin = lastPrompt?.origin ?? .owner

        let request = TriagePrompt.buildAssistantQuestionRequest(
            model: model,
            sessionId: info.sessionId,
            cwd: cwd,
            userPrompt: userPrompt,
            userPromptOrigin: userPromptOrigin,
            assistantText: info.text,
            recentEvents: triageWindow
        )

        trace.emit("triage", "evaluating session=\(info.sessionId) assistant_text_len=\(info.text.count)")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(request)
        } catch {
            trace.emit("triage", "Assistant-text triage call failed: \(error)")
            onActivityChange?(.idle)
            return
        }

        if let costStore {
            let cost = TokenAccounting.costUSD(model: model, usage: response.usage)
            try? costStore.recordHaiku(
                inputTokens: response.usage.input_tokens,
                outputTokens: response.usage.output_tokens,
                costUSD: cost
            )
        }

        guard let candidates = extractCandidates(from: response) else {
            trace.emit("triage", "Assistant-text: no record_triage call from Haiku")
            onActivityChange?(.idle)
            return
        }
        if candidates.isEmpty {
            trace.emit("triage", "Assistant-text all-clear (prefilter hit but Haiku didn't fire)")
            onActivityChange?(.idle)
            return
        }

        // For each fired candidate, run the secondary call to populate
        // suggestedInjectText (engineering) or rewrite reasoning_plain
        // (taste). Safety passes through untouched.
        for candidate in candidates {
            var enriched = await enrichWithSecondaryAnswer(
                candidate: candidate,
                question: info.text,
                sessionId: info.sessionId,
                cwd: cwd
            )
            // wrong_trajectory: the diagnostic redirect rides in
            // next_task_proposal (no secondary call for this category). Promote
            // it to the inject text the router types; if the LLM gave no message,
            // degrade to a banner rather than inject nothing. The cwd guard below
            // still applies (unresolvable cwd -> notify with the text in-banner).
            if enriched.category == "wrong_trajectory" {
                if let redirect = enriched.nextTaskProposal, !redirect.isEmpty {
                    trace.emit("triage", "wrong_trajectory redirect session=\(info.sessionId) bytes=\(redirect.utf8.count)")
                    enriched = reconfigure(enriched, action: .inject, suggestedInjectText: redirect)
                } else {
                    enriched = reconfigure(enriched, action: .notify)
                }
            }
            // v0.3.1 (Issue #6): if cwd is unresolvable, the inject
            // path can't run (locator needs cwd → PID). Downgrade
            // .inject to .notify with the answer text moved into the
            // banner. This keeps the user informed without the router
            // ever emitting the misleading
            // `intervention.inject.degraded reason=no_cwd_on_decision`
            // tag — the engine-level
            // `assistant_text.no_cwd_session_start_not_seen` tag
            // already discriminates the cause.
            if cwd == nil && enriched.action == .inject {
                let answer = enriched.suggestedInjectText ?? ""
                trace.emit("triage", "downgrade .inject → .notify session=\(info.sessionId) reason=no_cwd_in_engine answer_bytes=\(answer.utf8.count)")
                enriched = reconfigure(
                    enriched,
                    action: .notify,
                    // Promote the answer into the banner. Keep the original
                    // reasoning as a prefix so the user sees both context
                    // and answer.
                    reasoningPlain: "[Answer from PRINCIPLES.md] \(answer)"
                )
            }
            // Triage flags on assistant text use the BashToolCallInfo
            // synthetic-bridge so the existing TriageDecision struct
            // works unchanged. The triggering "command" is the
            // assistant's question text, truncated.
            let pseudoTrigger = BashToolCallInfo(
                sessionId: info.sessionId,
                command: String(info.text.prefix(200)),
                description: nil,
                toolUseId: info.turnUUID,  // closest-available unique id
                turnUUID: info.turnUUID,
                ts: info.ts
            )
            let decision = TriageDecision(
                sessionId: info.sessionId,
                cwd: cwd,
                branch: sessionBranch[info.sessionId],
                candidate: enriched,
                triggeringEvent: pseudoTrigger,
                usage: response.usage,
                model: response.model,
                prePost: .preExecution,  // assistant is waiting; nothing executed yet
                recentEvents: window,
                lastUserPrompt: userPrompt
            )
            trace.emit("triage", "FLAG session=\(info.sessionId) category=\(enriched.category) severity=\(enriched.severity.rawValue) action=\(enriched.action.rawValue) question_type=\(enriched.questionType ?? "?")")
            onActivityChange?(.flagged(severity: enriched.severity, action: enriched.action, reasoningPlain: enriched.reasoningPlain))
            onDecision?(decision)
        }
    }

    /// Run the secondary QuestionAnswerer call when appropriate. The
    /// returned candidate may have suggestedInjectText populated
    /// (engineering high/medium confidence) OR reasoning_plain rewritten
    /// (taste, or engineering low confidence degraded to taste). Safety
    /// candidates and non-user_question_pending categories pass through.
    private func enrichWithSecondaryAnswer(
        candidate: TriageCandidate,
        question: String,
        sessionId: String,
        cwd: String?
    ) async -> TriageCandidate {
        guard candidate.category == "user_question_pending",
              let answerer = questionAnswerer else {
            return candidate
        }
        let qt = candidate.questionType ?? "safety"

        switch qt {
        case "engineering":
            do {
                // Ground the answer in the live repo state (branch, recent
                // commits, uncommitted changes) so a routine commit/push
                // question gets a concrete, context-based answer rather than
                // a generic one. cwd is required to reach git; without it
                // the answerer falls back to PRINCIPLES.md only.
                // cwd-exclusivity gate: omit repo grounding when the cwd is
                // shared by multiple live sessions — the git state belongs to
                // whichever session is actively committing, not necessarily this
                // one. Without this, a co-located session's branch/commits bleed
                // into this answer (the 2026-06-13 tweet-engine bleed). cwd is
                // still used for targeting elsewhere; only grounding is gated.
                let gatedCwd = repoGroundingCwd(cwd) ?? ""
                let context = gatedCwd.isEmpty
                    ? ""
                    : await gatherRepoContextForAnswer(cwd: gatedCwd, branch: nil, trace: trace)
                let answer = try await answerer.answerEngineering(
                    question: question,
                    repoContext: context
                )
                if answer.confidence == .low || answer.answer.isEmpty {
                    // Degrade: PRINCIPLES didn't have a clear answer.
                    // Rewrite as taste and surface to user.
                    trace.emit("triage", "engineering low-confidence; degrading to taste session=\(sessionId)")
                    let rewrite = (try? await answerer.translateTaste(question: question))?.plainQuestion
                        ?? candidate.reasoningPlain
                    return reconfigure(
                        candidate,
                        action: .notify,
                        reasoningPlain: rewrite
                    )
                }
                return reconfigure(
                    candidate,
                    action: .inject,
                    suggestedInjectText: answer.answer
                )
            } catch {
                trace.emit("triage", "engineering answer call failed: \(error); degrading to notify")
                return reconfigure(candidate, action: .notify)
            }

        case "taste":
            do {
                let rewrite = try await answerer.translateTaste(question: question)
                return reconfigure(
                    candidate,
                    action: .notify,
                    reasoningPlain: rewrite.plainQuestion
                )
            } catch {
                trace.emit("triage", "taste translate call failed: \(error); using original")
                return reconfigure(candidate, action: .notify)
            }

        case "safety":
            // No secondary call. Safety questions reach the user
            // exactly as Haiku surfaced them.
            return reconfigure(candidate, action: .notify)

        default:
            return candidate
        }
    }

    /// v0.4.0 Part C: serialize one DispatchResult into a row for the
    /// `loop_dispatches` table. Static + nonisolated so tests (and any
    /// background-actor caller) can invoke it without going through
    /// the main-actor engine.
    nonisolated static func storedLoopDispatchRow(
        sessionId: String,
        result: DispatchResult,
        priorDispatchesConsidered: Int,
        ts: Date
    ) -> StoredLoopDispatch {
        switch result {
        case let .ready(prompt, justification, conf, path, issueN, _, _):
            return StoredLoopDispatch(
                sessionId: sessionId,
                ts: ts,
                responseShape: "ready",
                confidence: conf.rawValue,
                selectedPath: path.rawValue,
                selectedIssueNumber: issueN,
                taskProposalHead: String(prompt.prefix(200)),
                justification: justification,
                priorDispatchesConsidered: priorDispatchesConsidered
            )
        case let .lowConfidence(reasoning):
            return StoredLoopDispatch(
                sessionId: sessionId,
                ts: ts,
                responseShape: "lowConfidence",
                confidence: "low",
                selectedPath: SelectedPath.lowConfidenceNoAction.rawValue,
                selectedIssueNumber: nil,
                taskProposalHead: "",
                justification: reasoning,
                priorDispatchesConsidered: priorDispatchesConsidered
            )
        case let .error(reasoning):
            return StoredLoopDispatch(
                sessionId: sessionId,
                ts: ts,
                responseShape: "error",
                confidence: nil,
                selectedPath: nil,
                selectedIssueNumber: nil,
                taskProposalHead: "",
                justification: reasoning,
                priorDispatchesConsidered: priorDispatchesConsidered
            )
        case let .objectiveComplete(summary):
            return StoredLoopDispatch(
                sessionId: sessionId,
                ts: ts,
                responseShape: "objectiveComplete",
                confidence: nil,
                selectedPath: SelectedPath.objectiveComplete.rawValue,
                selectedIssueNumber: nil,
                taskProposalHead: String(summary.prefix(200)),
                justification: summary,
                priorDispatchesConsidered: priorDispatchesConsidered
            )
        }
    }

    /// Rebuild a candidate with new field values. TriageCandidate is
    /// immutable; this is the canonical "with" pattern.
    ///
    /// `nilOverride` sentinel pattern: passing an `Optional<...>?` lets
    /// the caller distinguish "leave field alone" (parameter omitted →
    /// outer Optional is nil) from "set field to nil" (parameter
    /// explicitly passed as `.some(nil)`). v0.4.0 Part B needs this
    /// for nextTaskProposal — low-confidence dispatches must blank the
    /// proposal even if the rubric set one.
    private func reconfigure(
        _ c: TriageCandidate,
        action: FlagAction? = nil,
        reasoningPlain: String? = nil,
        asymmetryNote: String? = nil,
        suggestedInjectText: String?? = nil,
        nextTaskProposal: String?? = nil,
        confidence: String?? = nil
    ) -> TriageCandidate {
        TriageCandidate(
            category: c.category,
            severity: c.severity,
            matchedCommand: c.matchedCommand,
            action: action ?? c.action,
            reasoningPlain: reasoningPlain ?? c.reasoningPlain,
            reasoningTechnical: c.reasoningTechnical,
            asymmetryNote: asymmetryNote ?? c.asymmetryNote,
            suggestedInjectText: suggestedInjectText ?? c.suggestedInjectText,
            questionType: c.questionType,
            nextTaskProposal: nextTaskProposal ?? c.nextTaskProposal,
            confidence: confidence ?? c.confidence
        )
    }

    // MARK: - Window helpers

    private func lastSessionCWD(in window: [SupervisorEvent]) -> String? {
        for event in window.reversed() {
            if case .sessionStart(let i) = event { return i.cwd }
        }
        return nil
    }

    /// v0.4.0 (Part A): like `lastSessionCWD` but pulls `gitBranch`.
    /// Falls back to `sessionBranch` cache at the call site.
    private func lastSessionBranch(in window: [SupervisorEvent]) -> String? {
        for event in window.reversed() {
            if case .sessionStart(let i) = event { return i.gitBranch }
        }
        return nil
    }

    /// Self-authorization gap: re-stamp each `.userPrompt` in the window with
    /// its true origin by correlating against the injection ledger. A turn
    /// Supervisor typed becomes `.supervisorInjected`; everything else stays
    /// `.owner`. Done at prompt-assembly time (not parse time) because the
    /// parser has no ledger and an injection is recorded by the router moments
    /// before its turn appears. No ledger → identity (every turn stays owner).
    private func labelInjectedOrigins(_ window: [SupervisorEvent]) -> [SupervisorEvent] {
        guard let ledger = injectionLedger else { return window }
        return window.map { event in
            guard case .userPrompt(let i) = event, i.origin == .owner else { return event }
            guard ledger.isSupervisorInjected(sessionId: i.sessionId, text: i.text, asOf: i.ts) else { return event }
            return .userPrompt(UserPromptInfo(
                sessionId: i.sessionId, text: i.text, ts: i.ts, channel: i.channel, origin: .supervisorInjected
            ))
        }
    }

    /// The most recent OWNER `.userPrompt` in the (already origin-labeled)
    /// window — supervisor-injected turns are SKIPPED. This is the
    /// authorization anchor the rubric reasons about ("did the user authorize
    /// this?"), so it must never be a turn Supervisor typed itself.
    ///
    /// Why skip, rather than label-and-let-the-model-discount: the §6d live
    /// canary proved the model (DeepSeek) ignores a `[supervisor-injected]`
    /// label in the anchor slot and treats the injected text as authorization
    /// anyway. The SAME canary proved the model fires correctly when there is
    /// NO owner authorization. So the safety property is made deterministic by
    /// construction: the anchor only ever holds genuine owner text, and the
    /// model's correct "fire on an unauthorized destructive action" behavior
    /// does the rest — no model compliance with a discount-this instruction
    /// required. Injected turns still appear (labeled) in the event window for
    /// context; they just never occupy the authorization slot. An earlier
    /// genuine owner authorization is still found even if an injected turn is
    /// more recent, so a real authorization is honored and only the fake one
    /// is dropped.
    private func lastOwnerPrompt(in labeledWindow: [SupervisorEvent]) -> UserPromptInfo? {
        for event in labeledWindow.reversed() {
            if case .userPrompt(let i) = event, i.origin == .owner { return i }
        }
        return nil
    }

    /// The window the triage MODEL is allowed to see: Supervisor-injected
    /// userPrompt turns removed entirely. The §6d canary proved the model reads
    /// an injected turn as owner authorization even when it is labeled
    /// `[supervisor-injected]` (it treats any user-role text in context as
    /// authorization), so the only robust fix is to keep its own injected text
    /// out of the triage's view. Non-userPrompt events and genuine owner prompts
    /// pass through unchanged. The FULL labeled window (injected turns included)
    /// still flows to the recovery doc — this filter scopes only what the model
    /// reasons over.
    private func triageVisibleWindow(_ labeledWindow: [SupervisorEvent]) -> [SupervisorEvent] {
        labeledWindow.filter { event in
            if case .userPrompt(let i) = event, i.origin == .supervisorInjected { return false }
            return true
        }
    }

    private func lastBashResult(matching toolUseId: String, in window: [SupervisorEvent]) -> BashToolResultInfo? {
        for event in window.reversed() {
            if case .bashToolResult(let i) = event, i.toolUseId == toolUseId { return i }
        }
        return nil
    }

    // MARK: - Response decoding

    private func extractCandidates(from response: AnthropicMessageResponse) -> [TriageCandidate]? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == TriagePrompt.recordTriageToolName,
                  case let .object(input)? = block.input,
                  case let .array(candidatesArr)? = input["candidates"]
            else { continue }
            var out: [TriageCandidate] = []
            for raw in candidatesArr {
                guard case let .object(c) = raw else { continue }
                if let candidate = parseCandidate(c) {
                    out.append(candidate)
                }
            }
            return out
        }
        return nil
    }

    /// Parse one candidate dict. The bare minimum to fire a flag at all is
    /// `category` + `severity` — everything else has a defined fallback so
    /// a slightly-broken Haiku response still produces a usable flag rather
    /// than vanishing silently. Logs `triage.schema.malformed` whenever
    /// any field falls back. Reasoning fields go through the Redactor
    /// before they land on the in-memory candidate — defense in depth.
    private func parseCandidate(_ c: [String: AnthropicJSON]) -> TriageCandidate? {
        guard case let .string(cat)? = c["category"],
              case let .string(sev)? = c["severity"],
              let severity = FlagSeverity(rawValue: sev) else {
            trace.emit("triage", "schema.malformed candidate missing category/severity raw=\(serializeForTrace(c))")
            return nil
        }

        var malformed = false
        var fallbackReason: [String] = []

        let matchedCommand: String
        if case let .string(cmd)? = c["matched_command"], !cmd.isEmpty {
            matchedCommand = cmd
        } else {
            matchedCommand = "(missing)"
            malformed = true
            fallbackReason.append("matched_command")
        }

        let action: FlagAction
        if case let .string(actStr)? = c["recommended_action"],
           let a = FlagAction(rawValue: actStr) {
            action = a
        } else {
            action = .notify
            malformed = true
            fallbackReason.append("recommended_action")
        }

        let reasoningPlain: String
        let reasoningTechnical: String
        let plainRaw: String?
        let techRaw: String?
        if case let .string(p)? = c["reasoning_plain"], !p.isEmpty {
            plainRaw = p
        } else {
            plainRaw = nil
            malformed = true
            fallbackReason.append("reasoning_plain")
        }
        if case let .string(t)? = c["reasoning_technical"], !t.isEmpty {
            techRaw = t
        } else {
            techRaw = nil
            malformed = true
            fallbackReason.append("reasoning_technical")
        }

        // Fallback rule (Mohammed-approved): when reasoning_plain is
        // missing, do NOT substitute reasoning_technical into the banner —
        // the whole point of the split is that technical text is unfit
        // for a banner. Use a fixed string instead.
        if let p = plainRaw {
            reasoningPlain = redactor.redact(p)
        } else {
            reasoningPlain = TriagePrompt.malformedVerdictBannerText
        }
        if let t = techRaw {
            reasoningTechnical = redactor.redact(t)
        } else {
            reasoningTechnical = ""
        }

        var asymmetryNote: String? = nil
        if case let .string(note)? = c["asymmetry_note"], !note.isEmpty {
            asymmetryNote = redactor.redact(note)
        }

        // v0.3.0: question_type is required when category is
        // user_question_pending and ignored otherwise. If the category
        // requires it and Haiku omits it, default to "safety" — that's
        // the rubric's safer-fallback rule.
        var questionType: String? = nil
        if cat == "user_question_pending" {
            if case let .string(qt)? = c["question_type"],
               ["engineering", "safety", "taste"].contains(qt) {
                questionType = qt
            } else {
                questionType = "safety"
                malformed = true
                fallbackReason.append("question_type")
            }
        }

        // v0.4.0: confidence + next_task_proposal are required when
        // category is worker_idle_post_completion and ignored otherwise.
        // If confidence is missing/invalid, default to "low" — that's the
        // safer-fallback rule (low → notify, no auto-dispatch). If
        // next_task_proposal is missing, leave nil; Part B's dispatcher
        // populates the prompt body anyway. In Part A the primary call
        // may leave next_task_proposal empty intentionally (the dispatcher
        // isn't wired up yet) so its absence is NOT logged as malformed.
        var confidence: String? = nil
        var nextTaskProposal: String? = nil
        if cat == "worker_idle_post_completion" {
            if case let .string(conf)? = c["confidence"],
               ["high", "medium", "low"].contains(conf) {
                confidence = conf
            } else {
                confidence = "low"
                malformed = true
                fallbackReason.append("confidence")
            }
            if case let .string(prop)? = c["next_task_proposal"], !prop.isEmpty {
                nextTaskProposal = redactor.redact(prop)
            }
            // Intentionally NOT marking malformed when next_task_proposal
            // is absent — Part A ships without the dispatcher; Part B
            // populates it.
        }

        if malformed {
            // Log the raw verdict (un-redacted) for debugging per Mohammed:
            // trace log is local-only, README is honest about that.
            trace.emit("triage", "schema.malformed fields=\(fallbackReason.joined(separator: ",")) action=\(action.rawValue) raw=\(serializeForTrace(c))")
        }

        return TriageCandidate(
            category: cat,
            severity: severity,
            matchedCommand: matchedCommand,
            action: action,
            reasoningPlain: reasoningPlain,
            reasoningTechnical: reasoningTechnical,
            asymmetryNote: asymmetryNote,
            suggestedInjectText: nil,  // populated by secondary call in TriageEngine.evaluate
            questionType: questionType,
            nextTaskProposal: nextTaskProposal,
            confidence: confidence
        )
    }

    /// Compact-serialize the raw candidate dict for the trace log. Truncated
    /// at 400 chars to keep the rolling log readable; full reconstruction
    /// after the fact is rarely needed since reasoning_technical is also
    /// stored on the StoredFlag.
    private func serializeForTrace(_ dict: [String: AnthropicJSON]) -> String {
        var pairs: [String] = []
        for (k, v) in dict {
            switch v {
            case .string(let s):  pairs.append("\(k)=\(s.prefix(80))")
            case .integer(let n): pairs.append("\(k)=\(n)")
            case .double(let n):  pairs.append("\(k)=\(n)")
            case .bool(let b):    pairs.append("\(k)=\(b)")
            case .null:           pairs.append("\(k)=null")
            case .array:          pairs.append("\(k)=[…]")
            case .object:         pairs.append("\(k)={…}")
            }
        }
        let joined = pairs.joined(separator: " ")
        return String(joined.prefix(400))
    }
}
