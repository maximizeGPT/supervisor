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
    /// issue #60 follow-up: the `flags` table row id this decision was
    /// persisted as. The app layer stamps it right after the FlagStore insert
    /// (main.swift handle(decision:)), BEFORE the router dispatch, so the
    /// Notifier's result hook can write the REAL InterventionOutcome back onto
    /// this exact row (FlagStore.markInterventionOutcome) and the banner can
    /// carry the id for the dismiss-response delegate path. nil for a decision
    /// that was never persisted (tests, older callers) — every persistence
    /// consumer skips on nil. `var` (not `let`) precisely so the app layer can
    /// stamp it post-insert without reconstructing the whole decision.
    public var flagId: String?

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
        lastUserPrompt: String? = nil,
        flagId: String? = nil
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
        self.flagId = flagId
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

        // -- v0.2.0 M7: stall-watchdog state. Independent of the plan loop. --

        /// Whether a background task or sub-agents are currently OUTSTANDING for
        /// this session, as last determined by the AsyncWorkScanner on a watchdog
        /// tick. Drives BOTH the watchdog stall decision AND the short-idle drive
        /// suppression (the drive does not inject "next task" over a legitimately
        /// running background task). Refreshed each watchdog tick; defaults false.
        var asyncWorkOutstanding: Bool = false
        /// Whether the "short-idle drive SUPPRESSED" trace has already been emitted
        /// for the CURRENT suppression episode. Set true on the transition INTO
        /// suppression (asyncWorkOutstanding flips false->true) so the line is
        /// logged once per episode, not every 1Hz tick (the busy-poll log flood
        /// fix). Reset to false when asyncWorkOutstanding clears, so a later episode
        /// logs once more. Suppression BEHAVIOR is unchanged; only the log cadence.
        var shortIdleSuppressionLogged: Bool = false
        /// Timestamp of the most recent watchdog check-in nudge for this session,
        /// for the trace + the per-interval cadence. nil until the first nudge.
        var lastNudgeTime: Date?
        /// How many check-in nudges have been sent for the CURRENT stall. Reset to
        /// 0 when the session moves again (new activity in updateIdleState). At the
        /// watchdog's cap the next verdict escalates instead of nudging.
        var watchdogNudgeCount: Int = 0
        /// True once the watchdog has escalated (notified + stopped nudging) for
        /// the current stall. Holds further nudges until the session moves, which
        /// clears it. Reset on new activity in updateIdleState.
        var watchdogEscalatedStopped: Bool = false
        /// FIX 7: monotonic lifetime count of check-in nudges for this session. Does
        /// NOT reset on movement (unlike watchdogNudgeCount), so it labels each nudge
        /// with a session-unique ordinal - which keeps the router's dedupDelivery
        /// gate from suppressing a LEGITIMATE re-nudge (e.g. after a movement reset
        /// produced an identical-ordinal check-in) while still catching a true
        /// same-decision re-fire. Only incremented alongside a real nudge.
        var watchdogTotalNudges: Int = 0

        // -- FIX 5: plan-harness "ungradable step" streak. --

        /// How many consecutive idle ticks the plan harness has skipped grading the
        /// CURRENT step because it had no observable ground truth (an edit-only /
        /// unobservable step). PlanLoop.driveIdleStep escalates instead of skipping
        /// once this reaches its cap. Reset to 0 when the step changes or a tick
        /// produces any non-skip outcome (see runPlanHarness).
        var planUngradableStreak: Int = 0
        /// The step id the `planUngradableStreak` count is for, so a cursor advance
        /// (or redirect to a different step) resets the streak rather than carrying
        /// a stale count onto a new step.
        var planUngradableStepId: String? = nil
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

    /// Conflict-fix (2026-07-03): max age of an incoming event before consume()
    /// withholds its loop/idle STATE MUTATIONS. A months-old event replayed by a
    /// `claude --resume` / post-compact copy would otherwise UN-STICK a stopped
    /// loop (a stale userPrompt -> notePause clears a three_consecutive_low hard
    /// stop), CLEAR a live pause (a stale bashToolCall -> clearPause), or drag
    /// idle bookkeeping backward off history. 120s is generous for live
    /// parse/bus latency (normally sub-second) while still shutting out any real
    /// backfill. The window still appends and the self-gating evaluate() path
    /// still dispatches; only the state mutations are gated.
    private let staleEventThresholdSeconds: TimeInterval

    /// v0.4.0 (Part A): injected clock for the idle check so tests can
    /// drive time deterministically without `Task.sleep`. Production
    /// uses `Date.init`.
    private let now: @MainActor () -> Date

    /// FIX 4 hardening (honest-health, 2026-07-04): the engine-progress
    /// recorder the background idle loop invokes once per completed cycle.
    /// Production uses the default (stamps the REAL
    /// `~/Library/Application Support/Supervisor/engine-progress.txt` via
    /// `EngineProgress.recordTick()`); tests inject a no-op or a temp-dir
    /// writer so a `swift test` run can never freshen the global liveness
    /// token over a genuinely hung production engine — the exact lying-GREEN
    /// the token exists to prevent. Mirrors the `now` seam's isolation
    /// (@MainActor, invoked only from the engine's own idle-loop Task).
    private let recordEngineProgress: @MainActor () -> Void

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

    /// v0.2.0 observability (Reddit feedback A): optional unified audit log.
    /// When non-nil, the engine records a skimmable, per-action audit row
    /// ADDITIVELY from its decision hooks - kind=autoAnswer when the
    /// QuestionAnswerer answers a question, kind=block on a DeterministicCatch
    /// destructive-command pause, kind=nudge on a stall-watchdog check-in (with
    /// the PART B failure-mode classification). Recording NEVER changes those
    /// hooks' behavior. Nil disables it (tests / no SupervisorDatabase).
    private let auditStore: AuditStore?

    /// v0.2.0 observability (Reddit feedback B): the pure stall failure-mode
    /// classifier. Labels WHY a session stalled from the AsyncWorkScanner signals
    /// so the nudge audit record carries more than "continued." Pure value type.
    private let stallClassifier: StallClassifier

    /// v0.2.0 M2d-2: optional Planner/Evaluator harness driver. When non-nil AND
    /// the RuntimeToggles.plannerEnabled opt-in marker is ON, the idle path runs
    /// the plan harness instead of the single-shot Dispatcher: it CREATES an
    /// awaiting-approval plan for an idle session that has an objective and no
    /// plan, and DRIVES an approved running plan step-by-step (inject -> observe
    /// -> evaluate -> decide). nil (the default, and when the toggle is OFF)
    /// leaves the Dispatcher path EXACTLY as today - this is the gate that keeps
    /// default behavior unchanged. Every plan-step injection still rides the
    /// existing marked+ledgered router path (the engine emits a `.continue`
    /// decision through `onDecision`), so the safety properties are preserved.
    private let planLoop: PlanLoop?

    /// v0.2.0 M2d-2: the opt-in gate read. Defaults to the live
    /// RuntimeToggles.plannerEnabled marker; injectable so tests exercise the
    /// gate (on/off) WITHOUT writing the real marker (which the running app would
    /// pick up). Mirrors LoopController.loopCapDisabled's injectable-toggle
    /// pattern. Read on the idle hot path only.
    private let plannerEnabled: @Sendable () -> Bool

    /// v0.2.0 M4-prep: the one-shot approve-plan affordance, read-then-consumed on
    /// the periodic idle tick. Returns true exactly once per owner touch of
    /// `approve-plan.marker` (it deletes the marker when present). Consulted ONLY
    /// when `plannerEnabled` is ON and a PlanLoop is wired, so it adds NO new
    /// behavior to the default (planner-off) build. Injectable so tests drive the
    /// approval WITHOUT writing the real marker the running app would pick up;
    /// production passes nothing (uses RuntimeToggles). Read on the idle tick only.
    private let consumeApprovePlanMarker: @Sendable () -> Bool

    /// The auto-dispatch kill-switch read. Defaults to the live
    /// `TriageEngine.autoDispatchDisabled` marker; injectable so tests can drive
    /// the dispatcher / plan-harness branch deterministically without depending on
    /// whether the real `dispatch-disabled.marker` happens to exist on the test
    /// machine. Production passes nothing (uses the marker). Read on the idle hot
    /// path only.
    private let autoDispatchDisabledRead: @Sendable () -> Bool

    /// Global-pause read (launch-audit fix, 2026-07): injectable like the other
    /// toggle reads so tests are hermetic against the REAL marker dir. The
    /// default consults the live `supervisor-paused.marker`; engine tests pass
    /// `{ false }` — a paused production Supervisor on the dev machine used to
    /// silently dorm every engine test into a timeout.
    private let supervisorPausedRead: @Sendable () -> Bool

    /// v0.2.0 observability (Reddit feedback E): the owner's decision-sensitivity
    /// setting read. Defaults to the persisted `DecisionSensitivityStore.current`;
    /// injectable so tests drive the act-vs-escalate gate WITHOUT touching the
    /// app's real UserDefaults domain. It controls ONE engine gate: the minimum
    /// auto-answer confidence that still injects (acts) vs. escalates the question
    /// to the human (`minAnswerConfidenceToInject`). At `.balanced` (the default)
    /// the gate is `.medium`, which is EXACTLY today's behavior, so the engine is
    /// unchanged unless the owner moves the dial. Read only on the answer path.
    private let decisionSensitivityRead: @Sendable () -> DecisionSensitivity

    // MARK: - v0.2.0 M7: background-task / stall watchdog (DEFAULT ON)

    /// The pure stall classifier (.ok / .checkIn / .escalate). Default thresholds;
    /// injectable so tests tune the nudge cap. Always present (the watchdog is
    /// default-on); the `watchdogEnabledRead` gate + the AsyncWorkScanner result
    /// are what decide whether it actually fires on a given tick.
    private let stallWatchdog: StallWatchdog
    /// The model-aware interval policy (default 30m). Injectable for tests.
    private let watchdogPolicy: WatchdogPolicy
    /// Detects whether a background task or sub-agents are outstanding by reading
    /// the session transcript (the parsed event stream cannot, by design - see
    /// AsyncWorkScanner). Injectable so tests point it at a fixture transcript.
    private let asyncWorkScanner: AsyncWorkScanner
    /// The default-ON gate read. Defaults to the live
    /// `RuntimeToggles.watchdogEnabled` (true unless the disable marker exists);
    /// injectable so tests drive on/off WITHOUT writing the real marker. Read on
    /// the watchdog tick only. The global `supervisorPaused` marker is checked
    /// SEPARATELY (a paused supervisor nudges nothing) and is not folded in here.
    private let watchdogEnabledRead: @Sendable () -> Bool
    /// Per-session model id for the watchdog interval policy, learned
    /// OPPORTUNISTICALLY from the transcript by the AsyncWorkScanner (the parsed
    /// event stream carries no model). nil -> the policy's 30m default. This is
    /// the "use it if visible" extension point named in the M7 spec; when a future
    /// change captures the model on the event path, populate this from there.
    private var watchdogSessionModel: [String: String] = [:]

    /// v0.2.0 M7 hardening (Finding 1a): per-session cache of the last
    /// AsyncWorkScanner result, keyed on the transcript's file identity (size +
    /// mtime). On each watchdog tick, if the transcript is unchanged since the
    /// cached scan, the cached `Scan` is reused and the tail-read + full JSON
    /// parse is SKIPPED. Correctness-preserving: identical bytes cannot yield a
    /// different outstanding determination. Pruned alongside `idleStates`.
    private struct CachedScan {
        let identity: AsyncWorkScanner.FileIdentity
        let scan: AsyncWorkScanner.Scan
    }
    private var watchdogScanCache: [String: CachedScan] = [:]

    /// v0.2.0 M7 hardening (Finding 1b): a session whose last event is older than
    /// this bound is considered gone and its per-session watchdog state is evicted
    /// on the next tick, so the maps cannot grow unbounded across a long-lived run
    /// (there is no session-end event to key removal on - see Event.swift). 24h is
    /// far past any real stall horizon (the loop's outer window is 4h), so a live
    /// session is never evicted; only abandoned ones are.
    private let watchdogStaleSessionEvictionSeconds: TimeInterval = 24 * 60 * 60

    /// Dormant-session gate (fix-queue #9): a session whose REAL last activity
    /// (`SessionIdleState.lastEventTs`) is older than this is treated as ABANDONED
    /// by the operator (they moved on to a different chat days/hours ago), not just
    /// idle mid-task. While dormant a session gets NONE of the auto-injections: no
    /// idle-dispatch drive, no plan-step drive, and no watchdog check-in nudge. This
    /// is the upper bound the loop never had: `LoopController.canDispatch` tracks
    /// the loop-EVALUATION time (`lastSeenAt`, refreshed every tick), not the
    /// session's real activity age, so a days-idle session was driven forever until
    /// the unrelated 24h watchdog eviction. We gate on SILENCE since the last real
    /// event, so a legitimately long-running but ACTIVE session (events keep
    /// arriving -> lastEventTs stays fresh) is never dormant. The moment the
    /// operator or worker produces a real event, lastEventTs updates and the next
    /// tick sees the session as active again (no sticky dormant state). Default 6h:
    /// clearly "stepped away for good," far past the 75-min single-task cap (§12)
    /// and the loop's 4h outer window, and well under the 24h watchdog eviction so
    /// dormancy suppresses BEFORE eviction reclaims the state. Tunable for tests.
    public nonisolated static let defaultDormantSessionSilenceSeconds: TimeInterval = 6 * 60 * 60
    private let dormantSessionSilenceSeconds: TimeInterval

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
        auditStore: AuditStore? = nil,
        stallClassifier: StallClassifier = StallClassifier(),
        planLoop: PlanLoop? = nil,
        plannerEnabled: @escaping @Sendable () -> Bool = { RuntimeToggles.plannerEnabled },
        consumeApprovePlanMarker: @escaping @Sendable () -> Bool = { RuntimeToggles.consumeApprovePlanRequested() },
        autoDispatchDisabledRead: @escaping @Sendable () -> Bool = { TriageEngine.autoDispatchDisabled },
        supervisorPausedRead: @escaping @Sendable () -> Bool = { RuntimeToggles.supervisorPaused },
        decisionSensitivityRead: @escaping @Sendable () -> DecisionSensitivity = { DecisionSensitivityStore.current() },
        stallWatchdog: StallWatchdog = StallWatchdog(),
        watchdogPolicy: WatchdogPolicy = WatchdogPolicy(),
        asyncWorkScanner: AsyncWorkScanner = AsyncWorkScanner(),
        watchdogEnabledRead: @escaping @Sendable () -> Bool = { RuntimeToggles.watchdogEnabled },
        idleThresholdSeconds: TimeInterval = 15,
        idleReTriageIntervalSeconds: TimeInterval = 60,
        idleCheckIntervalSeconds: TimeInterval = 1,
        staleEventThresholdSeconds: TimeInterval = 120,
        dormantSessionSilenceSeconds: TimeInterval = TriageEngine.defaultDormantSessionSilenceSeconds,
        liveSessionsSharingCwd: @escaping (String) -> Int = { _ in 1 },
        injectionLedger: InjectionLedger? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        recordEngineProgress: @escaping @MainActor () -> Void = { _ = EngineProgress.recordTick() },
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
        self.auditStore = auditStore
        self.stallClassifier = stallClassifier
        self.planLoop = planLoop
        self.plannerEnabled = plannerEnabled
        self.consumeApprovePlanMarker = consumeApprovePlanMarker
        self.autoDispatchDisabledRead = autoDispatchDisabledRead
        self.supervisorPausedRead = supervisorPausedRead
        self.decisionSensitivityRead = decisionSensitivityRead
        self.stallWatchdog = stallWatchdog
        self.watchdogPolicy = watchdogPolicy
        self.asyncWorkScanner = asyncWorkScanner
        self.watchdogEnabledRead = watchdogEnabledRead
        self.idleThresholdSeconds = idleThresholdSeconds
        self.idleReTriageIntervalSeconds = idleReTriageIntervalSeconds
        self.idleCheckIntervalSeconds = idleCheckIntervalSeconds
        self.staleEventThresholdSeconds = staleEventThresholdSeconds
        self.dormantSessionSilenceSeconds = dormantSessionSilenceSeconds
        self.liveSessionsSharingCwd = liveSessionsSharingCwd
        self.now = now
        self.recordEngineProgress = recordEngineProgress
        self.trace = trace
    }

    /// v0.2.0 M7 hardening: read-only counts of the per-session watchdog maps, so
    /// tests can assert the Finding 1b pruning actually evicts a gone session
    /// (no unbounded growth) without exposing the maps themselves. Internal, not
    /// public - test visibility only.
    var watchdogTrackedSessionCount: Int { idleStates.count }
    var watchdogScanCacheCount: Int { watchdogScanCache.count }

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

    /// `runIdleLoop` defaults to true (production always runs the background
    /// idle-check timer). Test harnesses that drive `checkIdleStates()` directly
    /// pass false so NO background idle-loop Task is spawned: that task's cancelled
    /// `Task.sleep` at teardown can otherwise surface a (handled) CancellationError
    /// against a test under XCTest's end-of-test task cancellation. The bus
    /// subscription is set up either way, so event consumption is unaffected.
    public func start(runIdleLoop: Bool = true) {
        busSubscription = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.consume(event: event) }
        }
        if runIdleLoop { startIdleCheckLoop() }
        trace.emit("triage", "engine started model=\(model) windowSize=\(windowSize) idleThreshold=\(idleThresholdSeconds)s idleReTriage=\(idleReTriageIntervalSeconds)s runIdleLoop=\(runIdleLoop)")
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
        // The REVIEW dimension (ReviewEngine, v0.3.x opt-in) owns fileEdit
        // events. The safety triage neither triggers on them nor keeps them in
        // its window: dropping the case here BEFORE any window append or state
        // mutation keeps the destructive-action path byte-for-byte unchanged now
        // that the parser emits a new event type. This is deliberately additive —
        // reviewing the code a worker writes is a separate concern from catching
        // a destructive command, and must never dilute or reshape the latter.
        if case .fileEdit = event { return }

        let sessionId = event.sessionId
        var window = perSessionWindow[sessionId] ?? []
        window.append(event)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }
        perSessionWindow[sessionId] = window

        // Conflict-fix (2026-07-03): gate the loop/idle STATE MUTATIONS below on
        // event age. A months-old replayed event (a `claude --resume` /
        // post-compact copy - the exact case SessionTail's fast-forward layer can
        // miss for a small fresh file) must NOT un-stick a stopped loop, clear a
        // live pause, or drag idle bookkeeping backward off stale history. The
        // window append above and the self-gating evaluate()/evaluateAssistantText()
        // dispatch below still run; only the state mutations are withheld. Clamp a
        // negative age to 0 so a future-dated event (clock skew / tz-ahead) counts
        // as fresh, not stale-forever.
        let nowTs = now()
        let eventAge = max(0, nowTs.timeIntervalSince(event.timestamp))
        let isStale = eventAge > staleEventThresholdSeconds
        if isStale {
            trace.emit("triage", "stale_event_state_skipped session=\(sessionId) age=\(Int(eventAge))s threshold=\(Int(staleEventThresholdSeconds))s eventTs=\(event.timestamp.timeIntervalSince1970) now=\(nowTs.timeIntervalSince1970)")
        } else {
            // v0.4.0 Part A: maintain per-session idle state on every FRESH event,
            // regardless of type. The timer reads this state once per tick.
            updateIdleState(for: event)
        }

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
            // Conflict-fix: a STALE (replayed) owner prompt must NOT reach
            // notePause - it would clear a three_consecutive_low hard stop and
            // re-stamp operator presence off months-old history. The injection-
            // ledger check is preserved for fresh prompts.
            if !isStale, let lc = loopController {
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
            // idle fire can dispatch normally. Conflict-fix: a STALE (replayed)
            // tool_use is not the worker resuming NOW - it must not clear a live
            // pause. evaluate() below is still dispatched unconditionally; its own
            // path is self-gating.
            if !isStale, let lc = loopController {
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
        // Conflict-fix (Finding 2): keep lastEventTs MONOTONIC. A fresh-but-out-of-
        // order event (bus reordering, a just-past-threshold arrival) must never
        // move lastEventTs BACKWARD - that would inflate silenceElapsed in
        // checkIdleStates and mis-fire idle/dormancy logic. (Truly stale events do
        // not reach here: consume() gates updateIdleState on staleness.)
        state.lastEventTs = max(state.lastEventTs, ts)
        // Any new event invalidates a prior idle-triage gate: the world
        // has changed since the rubric last said "no fire," so let the
        // timer re-ask if conditions hold.
        state.lastIdleTriageTs = nil

        // v0.2.0 M7: does THIS event count as worker "movement" that resets the
        // stall-watchdog nudge cycle? Real worker progress (assistant prose, a
        // tool call, or a tool result) always does; a userPrompt does ONLY when it
        // is a genuine owner turn (the human stepped in) - Supervisor's OWN nudge
        // lands as a userPrompt too, and counting that as movement would reset the
        // budget on every nudge and defeat the escalation. Correlate against the
        // ledger exactly as the loop-pause guard in `consume` does.
        var movement = false
        switch event {
        case .userPrompt:
            state.lastUserMsgTs = ts
            // User just spoke; the worker is no longer post-completion-idle
            // by definition. Clear stop-shape so we don't re-fire until a
            // new stop-shaped assistant message arrives.
            state.lastStopShapedTs = nil
            state.lastStopShapedPhrase = nil
            if case .userPrompt(let i) = event {
                let selfInjected = injectionLedger?.isSupervisorInjected(
                    sessionId: i.sessionId, text: i.text, asOf: i.ts) ?? false
                movement = !selfInjected
            }
        case .assistantText:
            // Any assistantText with no subsequent tool_use means the
            // worker stopped. Always mark as stopped; bashToolCall clears.
            state.lastStopShapedTs = ts
            state.lastStopShapedPhrase = "no_tool_use"
            movement = true
        case .bashToolCall:
            // Tool call means the worker is actively working again;
            // clear any prior stop-shape.
            state.lastStopShapedTs = nil
            state.lastStopShapedPhrase = nil
            movement = true
        case .bashToolResult:
            // A tool result is the worker's async work producing output -
            // unambiguous movement (and exactly what a stalled background task
            // is NOT doing).
            movement = true
        default:
            break
        }

        // On genuine movement, reset the watchdog cycle: a new stall has to build
        // up again from zero nudges, and any prior escalate-hold is released. The
        // asyncWorkOutstanding flag is recomputed on the next watchdog tick from a
        // fresh transcript scan, so we leave it for the tick to refresh.
        if movement {
            if state.watchdogNudgeCount != 0 || state.watchdogEscalatedStopped {
                trace.emit("watchdog", "movement resets nudge cycle session=\(sessionId) (was nudges=\(state.watchdogNudgeCount) escalated=\(state.watchdogEscalatedStopped))")
            }
            state.watchdogNudgeCount = 0
            state.watchdogEscalatedStopped = false
            state.lastNudgeTime = nil
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

    /// Spin up the idle-check loop. The loop runs on `@MainActor` so it can
    /// read and mutate `idleStates` without synchronization primitives.
    /// Cancelled by `stop()`.
    ///
    /// Sleep-FIRST: the loop waits one interval before its first check rather
    /// than firing an immediate `checkIdleStates()` at `start()`. That immediate
    /// fire ran on a later `await` hop — nondeterministically, after a test had
    /// already published events against a mocked clock — so a stray background
    /// tick raced the manually-driven checks (and could kick off dispatch/notify
    /// work) mid-test. Waiting a cadence first makes the loop fire only on its own
    /// timer; a freshly-started engine has nothing to sweep yet anyway. Every real
    /// harness parks this at a long interval and drives `checkIdleStates()`
    /// directly, so no test relies on the old immediate fire. Cancellation is
    /// handled explicitly (break, and never fire another check afterward) so no
    /// stray tick lands during teardown.
    private func startIdleCheckLoop() {
        idleCheckTask?.cancel()
        let interval = idleCheckIntervalSeconds
        idleCheckTask = Task { @MainActor [weak self] in
            // Convert seconds → nanoseconds once.
            let nanos = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: nanos) }
                catch { break }  // cancelled during the wait: exit the loop cleanly
                guard !Task.isCancelled else { break }
                // Engine deallocated without stop(): exit rather than keep stamping
                // a liveness token with no engine behind it (an orphaned loop would
                // otherwise read as permanent lying-GREEN). Unreachable in prod today
                // (the app holds the engine for its lifetime), but closes the class.
                guard let self else { break }
                self.checkIdleStates()
                // FIX 4 (honest-health): advance the engine-liveness token ONLY
                // after a real loop cycle actually ran checkIdleStates. A hung
                // MainActor / wedged checkIdleStates stops it advancing, so the
                // status bar honestly goes amber/red even while the process stays
                // alive. (Placed here, not in checkIdleStates(), so the hundreds of
                // unit tests that call checkIdleStates() directly don't touch the
                // real engine-progress file.) Routed through the injectable
                // `recordEngineProgress` seam — production defaults to
                // EngineProgress.recordTick(); test harnesses inject a no-op so
                // their 1s loops cannot stamp the REAL global liveness token.
                self.recordEngineProgress()
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

        // v0.2.0 M4-prep: the approve-plan marker affordance. Strictly gated by
        // the planner opt-in (and a wired PlanLoop), so this is INERT in the
        // default build: when the planner toggle is OFF we never even read the
        // marker. When ON and the owner has touched approve-plan.marker, approve
        // the watched session's latest awaiting-approval plan + start driving it,
        // then the marker is consumed (one-shot). Runs once per tick, before the
        // per-session idle walk.
        if plannerEnabled(), planLoop != nil {
            checkApprovePlanMarker()
        }

        // v0.2.0 M7: the background-task / stall watchdog pass. Runs BEFORE the
        // short-idle dispatch walk, INDEPENDENT of the plan loop and the
        // stop-shape gate (async work can be outstanding while the worker sits
        // "stopped" waiting on it). It refreshes each session's
        // asyncWorkOutstanding flag and, when a session is stalled (outstanding
        // async work + silence past the model-aware interval), injects a marked +
        // ledgered check-in nudge or, at the cap, notifies + stops. Gated by the
        // default-ON enable read AND the global pause. The refreshed
        // asyncWorkOutstanding then SUPPRESSES the short-idle dispatch below so the
        // drive loop never injects "next task" over a legitimately running
        // background task.
        runWatchdogPass(nowTs: nowTs)

        for (sessionId, state) in idleStates {
            guard let stopTs = state.lastStopShapedTs else { continue }
            let silenceElapsed = nowTs.timeIntervalSince(state.lastEventTs)
            guard silenceElapsed >= idleThresholdSeconds else { continue }

            // Fix-queue #9: a dormant session (real last event older than the
            // dormant bound) is NOT auto-driven - no idle dispatch, no plan-step
            // drive. The bug this closes: LoopController.canDispatch resets only on
            // its own lastSeenAt (refreshed every tick), so nothing bounded the
            // drive by the session's REAL activity age and a days-idle chat was
            // driven forever. We gate on silence since the last real event, so a
            // long-running ACTIVE session is unaffected and a returning operator's
            // fresh event clears dormancy on the next tick. Skipping here covers
            // BOTH the Dispatcher path AND the plan harness (both run inside
            // evaluateIdle, dispatched below).
            if isSessionDormant(state, nowTs: nowTs) {
                trace.emit("triage", "drive.skipped reason=session_dormant silence=\(Int(silenceElapsed))s session=\(sessionId)")
                continue
            }

            // v0.2.0 M7: SUPPRESS the short-idle drive while async work is
            // outstanding for this session. A background task / sub-agent is
            // legitimately running, so the drive loop must NOT inject other "next
            // task" work over it (the watchdog owns this session until the work
            // completes or it nudges/escalates). Healthy sessions with no
            // outstanding async work are unaffected. Refreshed by runWatchdogPass
            // immediately above; re-read from the (just-updated) state map.
            if idleStates[sessionId]?.asyncWorkOutstanding == true {
                // Log-flood fix: emit the SUPPRESSED line once per suppression
                // episode (on the transition into suppression), not every 1Hz tick.
                // The flag is reset when asyncWorkOutstanding clears (runWatchdogPass),
                // so a future episode logs once more. Behavior is unchanged: we still
                // `continue` and never drive over outstanding async work.
                if idleStates[sessionId]?.shortIdleSuppressionLogged != true {
                    trace.emit("watchdog", "short-idle drive SUPPRESSED session=\(sessionId): async work outstanding (background task / sub-agents running)")
                    idleStates[sessionId]?.shortIdleSuppressionLogged = true
                }
                continue
            }

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

    /// Fix-queue #9: is this session dormant (abandoned by the operator), as
    /// opposed to merely idle mid-task? True when the silence since the session's
    /// REAL last event exceeds `dormantSessionSilenceSeconds`. Gated on
    /// `lastEventTs` (the real activity clock), NOT the loop-evaluation time, so a
    /// long-running ACTIVE session that keeps producing events is never dormant,
    /// and a returning operator's fresh event clears dormancy on the next tick (no
    /// sticky state). Both auto-drive walks (idle dispatch + plan step) and the
    /// watchdog nudge pass consult this so a dormant session gets NO auto-injection.
    private func isSessionDormant(_ state: SessionIdleState, nowTs: Date) -> Bool {
        nowTs.timeIntervalSince(state.lastEventTs) >= dormantSessionSilenceSeconds
    }

    // MARK: - v0.2.0 M7: background-task / stall watchdog

    /// The watchdog pass: for every watched session, refresh whether async work is
    /// outstanding and act on a stall. Runs once per tick from `checkIdleStates`,
    /// BEFORE the short-idle dispatch walk. Default-ON, but inert unless a stall is
    /// actually present:
    ///   - GATING: skip entirely when the watchdog is disabled (marker present) OR
    ///     the supervisor is globally paused. Both default to "active": no marker,
    ///     not paused -> the pass runs.
    ///   - SCAN: only sessions that have gone quiet (silence >= the short-idle
    ///     floor) are scanned, to keep the transcript read off the hot path. The
    ///     scan reads the session JSONL for outstanding background-Bash /
    ///     sub-agent launches (the parsed event stream cannot tell - see
    ///     AsyncWorkScanner) and the opportunistic model id, and writes
    ///     asyncWorkOutstanding back into the session state (which the dispatch
    ///     walk then consults for suppression).
    ///   - DECIDE: with the refreshed signals + the model-aware interval, ask the
    ///     pure StallWatchdog. On .checkIn inject a marked + ledgered nudge and
    ///     bump the count; on .escalate notify + set the stop flag (no more
    ///     nudges until movement). NEVER auto-kills.
    private func runWatchdogPass(nowTs: Date) {
        guard watchdogEnabledRead() else { return }
        // Global pause: a paused supervisor nudges nothing (and spends no I/O).
        if supervisorPausedRead() { return }

        // Finding 1b: evict abandoned sessions so the per-session watchdog maps
        // cannot grow unbounded over a long run. There is no session-end event to
        // key on (Event.swift), so a session whose last event is older than the
        // stale bound is treated as gone. Runs once per tick before the walk.
        pruneStaleWatchdogState(nowTs: nowTs)

        for (sessionId, state) in idleStates {
            // Only scan sessions that have actually gone quiet. Below the
            // short-idle floor nothing can be stalled yet, and we avoid a
            // transcript read on every active session every second.
            let silence = nowTs.timeIntervalSince(state.lastEventTs)
            guard silence >= idleThresholdSeconds else {
                // Active session: clear any stale outstanding flag so a finished
                // task does not keep suppressing the drive. Also reset the
                // once-per-episode suppression-log flag so the next episode logs again.
                if state.asyncWorkOutstanding {
                    var cleared = state
                    cleared.asyncWorkOutstanding = false
                    cleared.shortIdleSuppressionLogged = false
                    idleStates[sessionId] = cleared
                }
                continue
            }

            // Fix-queue #9: a dormant session (real last event older than the
            // dormant bound) gets NO check-in nudge. The operator has stepped away
            // from this chat for good, so probing it is just an unwanted injection
            // into an abandoned conversation. Skip BEFORE the transcript scan so a
            // dormant session costs no I/O. Resumes the moment a real event arrives
            // (lastEventTs refreshes -> not dormant next tick).
            if isSessionDormant(state, nowTs: nowTs) {
                trace.emit("watchdog", "nudge.skipped reason=session_dormant silence=\(Int(silence))s session=\(sessionId)")
                continue
            }

            // The outstanding flag from BEFORE this tick's refresh - used to spot
            // the true->false completion transition below (Finding 2).
            let wasOutstanding = (idleStates[sessionId] ?? state).asyncWorkOutstanding

            // Refresh the outstanding-async-work signal from the transcript.
            // Finding 1a: skip the tail-read + parse when the transcript is
            // unchanged since the last scan (same size AND mtime). If unchanged,
            // the outstanding determination cannot have changed, so the cached
            // Scan is exact. A missing/unreadable file yields a nil identity; we
            // then fall through to scan() (which returns .none) and do not cache.
            let identity = asyncWorkScanner.fileIdentity(sessionId: sessionId)
            let scan: AsyncWorkScanner.Scan
            if let identity, let cached = watchdogScanCache[sessionId], cached.identity == identity {
                scan = cached.scan
            } else {
                scan = asyncWorkScanner.scan(sessionId: sessionId, now: nowTs)
                if let identity {
                    watchdogScanCache[sessionId] = CachedScan(identity: identity, scan: scan)
                }
            }
            var updated = idleStates[sessionId] ?? state
            updated.asyncWorkOutstanding = scan.outstanding
            if let m = scan.observedModel { watchdogSessionModel[sessionId] = m }

            // Log-flood fix: when outstanding work clears (true->false) the
            // suppression episode is over. Reset the once-per-episode log flag so a
            // future episode logs the SUPPRESSED line once more, and emit a single
            // RESUMED line so the trace shows the episode ended.
            if wasOutstanding, !scan.outstanding, updated.shortIdleSuppressionLogged {
                trace.emit("watchdog", "short-idle drive RESUMED session=\(sessionId): async work cleared")
                updated.shortIdleSuppressionLogged = false
            }

            // Finding 2: outstanding async work that flips true -> false is real
            // progress (the background task / sub-agent fan-out completed), even
            // though a Task/Agent completion is not surfaced as a "movement" event
            // by updateIdleState (EventParser only emits a result for Bash ids). So
            // treat the completion as a cycle reset here: a later, unrelated stall
            // starts fresh from zero nudges instead of inheriting a prior
            // escalate-hold.
            if wasOutstanding, !scan.outstanding,
               updated.watchdogNudgeCount != 0 || updated.watchdogEscalatedStopped {
                trace.emit("watchdog", "async work completed (outstanding true->false) resets nudge cycle session=\(sessionId) (was nudges=\(updated.watchdogNudgeCount) escalated=\(updated.watchdogEscalatedStopped))")
                updated.watchdogNudgeCount = 0
                updated.watchdogEscalatedStopped = false
                updated.lastNudgeTime = nil
            }
            idleStates[sessionId] = updated

            guard scan.outstanding else { continue }

            // Model-aware interval (opportunistic model -> policy; nil -> 30m).
            let model = watchdogSessionModel[sessionId]
            let interval = watchdogPolicy.interval(forModel: model)

            let signals = WatchdogSignals(
                lastActivityTime: updated.lastEventTs,
                asyncWorkOutstanding: true,
                nudgeCount: updated.watchdogNudgeCount,
                escalatedStopped: updated.watchdogEscalatedStopped
            )
            let decision = stallWatchdog.assess(signals: signals, now: nowTs, interval: interval)

            // FIX 7: enforce the nudge CADENCE. The pure StallWatchdog returns
            // .checkIn / .escalate on the stall condition but does NOT know when the
            // LAST nudge was sent, so on its own a stalled session would get all 3
            // check-ins + the escalate dumped within a few 1Hz ticks (~3s). Gate BOTH
            // actions on `lastNudgeTime` + the model-aware `interval`, mirroring the
            // idle path's `lastIdleTriageTs` + `idleReTriageIntervalSeconds` gate: an
            // action fires only once its interval has elapsed since the last nudge.
            if case .checkIn = decision {
                if let last = updated.lastNudgeTime, nowTs.timeIntervalSince(last) < interval {
                    // Too soon since the last nudge - hold this stall for now.
                    continue
                }
            } else if case .escalate = decision {
                // Only escalate an interval AFTER the last nudge, so the final nudge
                // is given its full interval to produce movement before we give up.
                if let last = updated.lastNudgeTime, nowTs.timeIntervalSince(last) < interval {
                    continue
                }
            }

            switch decision {
            case .ok:
                continue
            case let .checkIn(reason):
                // v0.2.0 observability B: classify WHY the session stalled from
                // the scanner signals so the nudge audit record (A) is specific.
                let classification = stallClassifier.classify(scan: scan)
                trace.emit("watchdog", "CHECK-IN session=\(sessionId) silence=\(Int(silence))s interval=\(Int(interval))s model=\(model ?? "?") launches=\(scan.launchCount) unpaired=\(scan.unpairedCount) class=\(classification.rawValue) nudge=\(updated.watchdogNudgeCount + 1): \(reason)")
                // Stamp BEFORE the async inject lands so the next tick cannot fire
                // a duplicate nudge for the same stall (mirrors the idle-triage
                // stamp). The cycle resets only on real movement (updateIdleState).
                var stamped = updated
                stamped.watchdogNudgeCount += 1
                stamped.watchdogTotalNudges += 1
                stamped.lastNudgeTime = nowTs
                idleStates[sessionId] = stamped
                emitWatchdogNudge(sessionId: sessionId, interval: interval, nudgeNumber: stamped.watchdogTotalNudges, withinStall: stamped.watchdogNudgeCount, maxNudges: stallWatchdog.maxNudges, classification: classification)
            case let .escalate(reason):
                trace.emit("watchdog", "ESCALATE session=\(sessionId) silence=\(Int(silence))s interval=\(Int(interval))s nudges=\(updated.watchdogNudgeCount): \(reason)")
                var stamped = updated
                stamped.watchdogEscalatedStopped = true
                idleStates[sessionId] = stamped
                // FIX 7: report the ACTUAL silence + the ACTUAL number of nudges sent
                // (both now honest under the cadence gate), not an inferred "~N
                // intervals" off a raced nudge count.
                emitWatchdogEscalation(sessionId: sessionId, silence: silence, nudges: updated.watchdogNudgeCount, interval: interval)
            }
        }
    }

    /// Finding 1b: evict per-session watchdog state for sessions that have been
    /// silent past `watchdogStaleSessionEvictionSeconds`. Claude Code emits no
    /// session-end event (Event.swift), so a session that is simply abandoned
    /// would otherwise leave its `idleStates` entry - and its sibling
    /// `watchdogSessionModel` / `watchdogScanCache` entries - resident forever,
    /// and (before the Finding 1a cache) cost a tail-read + parse every second.
    /// The bound is far beyond any real stall horizon, so a live or
    /// legitimately-long-running session is never evicted; if such a session
    /// later emits an event it simply re-registers a fresh idle state. Removing
    /// the entries also stops the watchdog pass from iterating dead sessions.
    private func pruneStaleWatchdogState(nowTs: Date) {
        let stale = idleStates.filter {
            nowTs.timeIntervalSince($0.value.lastEventTs) > watchdogStaleSessionEvictionSeconds
        }.map(\.key)
        guard !stale.isEmpty else { return }
        for sessionId in stale {
            idleStates.removeValue(forKey: sessionId)
            watchdogSessionModel.removeValue(forKey: sessionId)
            watchdogScanCache.removeValue(forKey: sessionId)
        }
        trace.emit("watchdog", "pruned \(stale.count) stale session(s) from watchdog state (silent > \(Int(watchdogStaleSessionEvictionSeconds))s)")
    }

    /// Inject the gentle "checking in" nudge as a high-confidence `.continue`
    /// decision, so it rides the EXACT same ledgered injection path a plan step /
    /// dispatch does (InterventionRouter.routeContinue ->
    /// continueHighInjectOrDegrade records it in the InjectionLedger before
    /// typing; the injection itself reads clean, no in-text banner). The text is
    /// redacted for defense in depth. NEVER a raw inject, NEVER a kill.
    private func emitWatchdogNudge(sessionId: String, interval: TimeInterval, nudgeNumber: Int = 1, withinStall: Int = 1, maxNudges: Int = StallWatchdog.defaultMaxNudges, classification: StallClassification = .unknown) {
        let intervalLabel = Self.watchdogIntervalLabel(interval)
        // FIX 7: the session-unique monotonic `nudgeNumber` (#N) makes each nudge's
        // text DISTINCT so the router's dedupDelivery gate never suppresses a
        // legitimate spaced or post-reset check-in (equal intervals would otherwise
        // reproduce identical text within the dedup window). `withinStall` is the
        // human-friendly "n of maxNudges" progress toward escalation.
        let nudge = "Checking in: it has been about \(intervalLabel) with no visible progress (check-in #\(nudgeNumber); \(withinStall) of \(maxNudges) this stall). Has the background task or your sub-agents produced output yet? If something stalled or died, summarize what you have so far and continue; otherwise report current status."
        // v0.2.0 observability A+B: record the nudge with its failure-mode
        // classification ADDITIVELY (does not change the nudge that is sent).
        recordNudgeAudit(sessionId: sessionId, intervalLabel: intervalLabel, classification: classification)
        let cwd = sessionCwd[sessionId]
        let branch = sessionBranch[sessionId]
        let candidate = TriageCandidate(
            category: "worker_idle_post_completion",
            severity: .medium,
            matchedCommand: "(watchdog) check-in",
            action: .continue,
            reasoningPlain: "Supervisor is checking in on a background task or sub-agents that have gone quiet.",
            reasoningTechnical: "v0.2.0 M7 stall watchdog: outstanding async work + silence past the \(Int(interval))s interval; sending a check-in nudge.",
            asymmetryNote: nil,
            suggestedInjectText: nil,
            questionType: nil,
            nextTaskProposal: redactor.redact(nudge),
            confidence: "high",
            // FIX 7: opt the nudge into the router's delivered-dedup gate so an
            // identical repeat check-in cannot be re-typed (belt-and-suspenders with
            // the lastNudgeTime cadence gate above).
            dedupDelivery: true
        )
        let usage = AnthropicUsage(input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
        let response = AnthropicMessageResponse(
            id: "watchdog-checkin", type: "message", role: "assistant",
            model: "stall-watchdog", content: [], stop_reason: nil,
            stop_sequence: nil, usage: usage
        )
        emitSyntheticIdleDecision(candidate, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: nil)
    }

    /// Surface the escalation as a plain `.notify` banner (no injection). After
    /// ~3 no-movement nudges the human is told a background task may have stalled;
    /// the watchdog then stops nudging until the session moves. Redacted for
    /// defense in depth.
    private func emitWatchdogEscalation(sessionId: String, silence: TimeInterval, nudges: Int, interval: TimeInterval) {
        let cwd = sessionCwd[sessionId]
        let branch = sessionBranch[sessionId]
        // FIX 7: honest copy - report the REAL silence duration and the REAL number
        // of check-in nudges actually sent (the cadence gate makes both accurate),
        // rather than inferring "~N intervals" from a possibly-raced count.
        let silenceLabel = Self.watchdogIntervalLabel(silence)
        let nudgeWord = nudges == 1 ? "nudge" : "nudges"
        let message = "Supervisor: a background task may have stalled - the session has been silent about \(silenceLabel) with outstanding async work, and \(nudges) check-in \(nudgeWord) produced no movement. I have stopped nudging; it will resume if the session moves again. (I never auto-kill or restart anything.)"
        let candidate = TriageCandidate(
            category: "worker_idle_post_completion",
            severity: .medium,
            matchedCommand: "(watchdog) escalate",
            action: .notify,
            reasoningPlain: redactor.redact(message),
            reasoningTechnical: "v0.2.0 M7 stall watchdog: \(nudges) check-in nudges over ~\(Int(silence))s silence (interval \(Int(interval))s) produced no movement; notifying + holding further nudges until the session moves.",
            asymmetryNote: nil,
            suggestedInjectText: nil,
            questionType: nil,
            nextTaskProposal: nil,
            confidence: "low"
        )
        let usage = AnthropicUsage(input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
        let response = AnthropicMessageResponse(
            id: "watchdog-escalate", type: "message", role: "assistant",
            model: "stall-watchdog", content: [], stop_reason: nil,
            stop_sequence: nil, usage: usage
        )
        emitSyntheticIdleDecision(candidate, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: nil)
    }

    /// A compact "Nm" / "X.Yh" label for the nudge copy.
    private static func watchdogIntervalLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%.1fh", s / 3600) }
        let minutes = Int((s / 60).rounded())
        return "\(minutes) minutes"
    }

    // MARK: - v0.2.0 observability A: audit recording (additive, best-effort)
    //
    // Each helper writes one StoredAuditEntry from a decision hook and is a
    // no-op when no auditStore is wired (tests / no DB). A write failure is
    // logged to the trace and swallowed - the audit trail is observability, it
    // must never break the decision path it observes. The text fields are
    // redacted (defense in depth) since they can echo command/question content.

    /// Record an auto-answer (the headline trust-evidence case): the question,
    /// the context Supervisor drew on, the authorizing principle (the answer's
    /// citation), and the answer itself.
    private func recordAutoAnswerAudit(
        sessionId: String,
        question: String,
        contextUsed: String,
        citation: String,
        answer: String
    ) {
        guard let auditStore else { return }
        let entry = StoredAuditEntry(
            sessionId: sessionId,
            createdAt: now(),
            kind: .autoAnswer,
            summary: redactor.redact("Answered Claude Code's question: \(answer.prefix(160))"),
            question: redactor.redact(String(question.prefix(500))),
            contextUsed: contextUsed.isEmpty ? "PRINCIPLES.md" : redactor.redact("PRINCIPLES.md + live repo context"),
            authorizingRule: citation.isEmpty ? nil : String(citation.prefix(200))
        )
        do { try auditStore.record(entry) } catch {
            trace.emit("audit", "record autoAnswer FAILED session=\(sessionId) error=\(error)")
        }
    }

    /// Record a destructive-command block (the "receipt"): the command, the
    /// catch pattern as the risk reason, and the human effect. The catch
    /// classification itself is unchanged - this only writes it down.
    ///
    /// The `summary` is a SCANNABLE receipt: capped at ~120 chars with a
    /// " …[truncated]" marker so a long shell pipeline no longer gets chopped
    /// mid-command with no sign it was cut. The FULL command is preserved
    /// separately in the `command` field, so the audit trail stays complete.
    /// The `riskReason` is a clear human sentence derived from the match (never
    /// empty — `caught.effect` may be blank, so we fall back to the pattern).
    private func recordBlockAudit(
        sessionId: String,
        command: String,
        caught: DeterministicCatch.Match,
        cwd: String?
    ) {
        guard let auditStore else { return }

        // Human risk reason: "<pattern>: <effect>", never empty. If the catch
        // carries no human effect phrase, fall back to a generic destructive
        // reason so the receipt is never blank.
        let effect = caught.effect.trimmingCharacters(in: .whitespacesAndNewlines)
        let riskReason = effect.isEmpty
            ? "\(caught.pattern): irreversible operation"
            : "\(caught.pattern): \(effect)"

        let entry = StoredAuditEntry(
            sessionId: sessionId,
            createdAt: now(),
            kind: .block,
            summary: redactor.redact(
                Self.truncatedSummary("Paused Claude Code before `\(command)` (\(caught.pattern))")
            ),
            command: redactor.redact(String(command.prefix(500))),
            targetPath: cwd.map { redactor.redact($0) },
            riskReason: redactor.redact(riskReason)
        )
        do { try auditStore.record(entry) } catch {
            trace.emit("audit", "record block FAILED session=\(sessionId) error=\(error)")
        }
    }

    /// Cap a receipt summary at ~120 chars, appending a visible " …[truncated]"
    /// marker when it overflows so a clipped shell command reads as clipped
    /// (the full command is kept in the audit entry's `command` field). Short
    /// summaries pass through untouched.
    static func truncatedSummary(_ text: String, limit: Int = 120) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " …[truncated]"
    }

    /// Record a stall-watchdog check-in nudge with its PART B failure-mode
    /// classification.
    private func recordNudgeAudit(
        sessionId: String,
        intervalLabel: String,
        classification: StallClassification
    ) {
        guard let auditStore else { return }
        let entry = StoredAuditEntry(
            sessionId: sessionId,
            createdAt: now(),
            kind: .nudge,
            summary: "Nudged a stalled session after ~\(intervalLabel) of silence (\(classification.humanReason)).",
            classification: classification.rawValue
        )
        do { try auditStore.record(entry) } catch {
            trace.emit("audit", "record nudge FAILED session=\(sessionId) error=\(error)")
        }
    }

    // MARK: - v0.2.0 M4-prep: approve-plan marker affordance

    /// Read-then-consume the approve-plan marker and, if it was present, approve
    /// the watched session's LATEST awaiting-approval plan and start driving it.
    /// Called once per tick by `checkIdleStates`, ONLY after the planner opt-in is
    /// confirmed ON and a PlanLoop is wired - so the default (planner-off) build
    /// never reaches here. ONE-SHOT: the marker is deleted on read, so a single
    /// owner touch approves exactly one plan.
    ///
    /// "Latest awaiting-approval plan" is resolved across the engine's watched
    /// sessions (the sessions it has seen events for): for each, the store's
    /// currentPlan is the most recent plan for that session; we keep the one whose
    /// status is awaitingApproval with the newest createdAt. If none is found
    /// (toggle on but nothing awaiting approval), the consumed marker is simply a
    /// no-op for this tick and we log that nothing was pending. The actual approve
    /// + first-step inject goes through `approvePlan(planId:)`, i.e. the SAME
    /// marked + ledgered path the M3 UI button will call.
    private func checkApprovePlanMarker() {
        // Read-and-delete first (one-shot): even if nothing is pending, an owner
        // touch is consumed so it cannot linger and fire on a later, unrelated tick.
        guard consumeApprovePlanMarker() else { return }
        guard let planLoop = self.planLoop else { return }  // gate (also checked by caller)

        // Candidate sessions: everything the engine has tracked. currentPlan is
        // per-session-latest; collect EVERY awaiting-approval plan across them.
        let sessionIds = Set(idleStates.keys).union(perSessionWindow.keys).union(sessionCwd.keys)
        var pending: [Plan] = []
        for sid in sessionIds {
            guard let plan = (try? planLoop.planStore.currentPlan(sessionId: sid)) ?? nil,
                  plan.status == .awaitingApproval else { continue }
            pending.append(plan)
        }

        guard !pending.isEmpty else {
            trace.emit("planloop", "approve-plan marker consumed but NO awaiting-approval plan is pending for any watched session - ignoring (toggle on, nothing to approve)")
            return
        }

        // FIX 6: the marker is a single global signal but approval must bind to ONE
        // plan. When exactly one plan is pending, approve it. When MORE than one is
        // pending across sessions, the marker is AMBIGUOUS - silently approving "the
        // newest" could start driving a session the owner did not mean to approve.
        // Refuse to auto-pick: notify the owner to approve the specific plan from
        // the panel (which targets a plan id) instead.
        guard pending.count == 1 else {
            let sorted = pending.sorted { $0.createdAt > $1.createdAt }
            trace.emit("planloop", "approve-plan marker consumed but \(pending.count) plans are awaiting approval across sessions \(sorted.map(\.sessionId)) - REFUSING to auto-approve the newest (ambiguous); notifying the owner to approve a specific plan from the panel")
            let newest = sorted[0]
            emitPlanNotify(
                message: "Supervisor did not auto-approve a plan: \(pending.count) plans are awaiting your approval across different sessions, so the approve request was ambiguous. Open the panel and approve the specific plan you meant (approving from the panel targets that exact plan).",
                escalation: nil,
                sessionId: newest.sessionId,
                cwd: sessionCwd[newest.sessionId],
                branch: sessionBranch[newest.sessionId],
                response: Self.syntheticPlanResponse(id: "approve-plan-ambiguous", model: "approve-plan-marker"),
                userPrompt: nil
            )
            return
        }

        let plan = pending[0]
        trace.emit("planloop", "approve-plan marker -> approving plan=\(plan.id) session=\(plan.sessionId) steps=\(plan.steps.count) objective=\"\(plan.objective.prefix(160))\" (sole pending plan; starting to drive)")
        let planId = plan.id
        Task { await self.approvePlan(planId: planId) }
    }

    /// Build an idle-evaluation triage request for one session and
    /// process the response. Parallel structure to `evaluate(call:)` and
    /// `evaluateAssistantText(info:)` — the same record_triage tool path,
    /// just scoped to the worker_idle_post_completion category.
    private func evaluateIdle(sessionId: String) async {
        // Global pause (owner toggle): stay dormant — no triage, dispatch, or
        // inject, and no API spend. consume() keeps tracking window/idle state,
        // so resume is seamless. Same guard on evaluate + evaluateAssistantText.
        if supervisorPausedRead() { return }
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
                if autoDispatchDisabledRead() {
                    trace.emit("loop", "auto-dispatch DISABLED by marker — worker_idle silent (safety detection unaffected) session=\(sessionId)")
                    onActivityChange?(.idle)
                    return
                }
                // v0.2.0 M2d-2: the Planner/Evaluator harness gate. ONLY when the
                // opt-in marker is ON and a PlanLoop is wired: an idle session
                // with an approved running plan is DRIVEN (inject -> observe ->
                // evaluate -> decide), and an idle session with an objective + no
                // plan gets an awaiting-approval plan. Either way the harness owns
                // this idle tick and we return. When the gate is closed (toggle
                // off, no PlanLoop, or no plan + no usable objective) it returns
                // .fellThrough and the existing Dispatcher path below runs
                // UNCHANGED. This is the seam that keeps default behavior intact.
                if plannerEnabled(), let planLoop = self.planLoop {
                    let outcome = await runPlanHarness(
                        planLoop: planLoop, sessionId: sessionId, cwd: cwd,
                        branch: branch, window: window, response: response,
                        userPrompt: userPrompt
                    )
                    if case .handled = outcome {
                        onActivityChange?(.idle)
                        return
                    }
                    // .fellThrough: keep the Dispatcher path (e.g. no approved plan
                    // and the planner could not ground one, or no objective yet).
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
            onActivityChange?(.flagged(severity: finalCandidate.severity, action: finalCandidate.action, reasoningPlain: finalCandidate.reasoningPlain, sessionId: sessionId, sessionCwd: cwd))
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
    nonisolated public static var autoDispatchDisabled: Bool {
        // resolvedHome, not homeDirectoryForCurrentUser: a SUPERVISOR_HOME-
        // isolated instance (E2E harness) must read ITS OWN dispatch marker,
        // never toggle-with / read the live app's.
        let marker = ConfigPaths.resolvedHome
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
                    confidence: "high",
                    // Fix #12: this is the dispatcher's unbounded auto-dispatch.
                    // It re-detects idle+objective every tick and would otherwise
                    // re-send the IDENTICAL proposal forever (and re-steal focus),
                    // so it opts into the router's delivered-dedup + retry gate.
                    dedupDelivery: true
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

    // MARK: - v0.2.0 M2d-2: Planner/Evaluator harness wiring

    /// Result of one idle tick handled (or not) by the plan harness.
    private enum PlanHarnessOutcome {
        /// The harness owned this idle tick (drove a step, created a plan,
        /// escalated, completed). The caller stops here.
        case handled
        /// The harness declined (no approved plan to drive AND no plan was
        /// created). The caller falls through to the existing Dispatcher path,
        /// UNCHANGED.
        case fellThrough
    }

    /// Run the plan harness for one idle tick. Two cohesive cases, in priority
    /// order:
    ///   1. An approved RUNNING plan exists -> DRIVE the current step: build the
    ///      observation since the step was injected, evaluate, decide, execute.
    ///   2. No plan yet AND the session has a captured objective -> CREATE an
    ///      awaiting-approval plan and notify the human it is ready to approve,
    ///      INSTEAD of a single-shot dispatch.
    /// Anything else (a plan awaiting approval / completed / aborted, or no
    /// objective to plan from) returns `.fellThrough` so the Dispatcher path
    /// runs unchanged. All injections/notifies are emitted through the existing
    /// marked + ledgered `onDecision` path (see emitPlanInject / emitPlanNotify).
    private func runPlanHarness(
        planLoop: PlanLoop,
        sessionId: String,
        cwd: String?,
        branch: String?,
        window: [SupervisorEvent],
        response: AnthropicMessageResponse,
        userPrompt: String?
    ) async -> PlanHarnessOutcome {
        // Case 1: an approved running plan -> drive its current step.
        if let plan = planLoop.runningPlan(sessionId: sessionId) {
            // FIX 1 (adversarial review): an escalate/abort decision already called
            // loopController.stop(...) but the plan's persisted status stays
            // .running (so the human can resume the SAME step). Gating re-entry on
            // runningPlan() alone therefore re-drives a paused plan on the very next
            // idle tick -> re-evaluate -> re-escalate, every interval, forever. So
            // before driving, consult the SAME dispatch permission the Dispatcher
            // loop uses: when it is not .proceed (stopped by escalate/abort, or
            // paused), do NOT drive and stay silent. The plan is still .handled so
            // the Dispatcher path below does not run and re-fire. A healthy run (no
            // stop set) returns .proceed and drives exactly as before. No
            // LoopController wired -> behave as before (drive).
            if let lc = loopController {
                let decision = await lc.canDispatch(sessionId: sessionId)
                guard case .proceed = decision else {
                    trace.emit("planloop", "idle: NOT driving running plan=\(plan.id) session=\(sessionId) - loop not dispatchable (\(decision)); staying silent (escalate/abort holds)")
                    return .handled
                }
            }
            let injectedAt = injectionLedger?.lastInjectionTime(sessionId: sessionId)
            // FIX 5: the prior consecutive "ungradable (no ground truth)" streak for
            // the CURRENT step, so PlanLoop can escalate an edit-only/unobservable
            // step instead of skipping it forever. Reset the carried count if the
            // step changed since we last tracked it.
            let currentStepId = plan.currentStep?.id
            let priorStreak: Int = {
                guard let st = idleStates[sessionId],
                      st.planUngradableStepId == currentStepId else { return 0 }
                return st.planUngradableStreak
            }()
            trace.emit("planloop", "idle: driving running plan=\(plan.id) step=\(plan.currentStepIndex) session=\(sessionId) injectedAt=\(injectedAt.map { "\($0.timeIntervalSince1970)" } ?? "nil") ungradableStreak=\(priorStreak)")
            let action = await planLoop.driveIdleStep(
                plan: plan, sessionId: sessionId, cwd: cwd, window: window,
                stepInjectedAt: injectedAt, consecutiveUngradableTicks: priorStreak, now: now()
            )
            // FIX 5: update the streak from this tick's outcome. A no-ground-truth
            // skip bumps it (bound to the current step); any other outcome (a grade,
            // an inject, an escalation) means the step is no longer stuck-ungradable,
            // so clear it.
            if case let .none(reason) = action, reason == "no_ground_truth_yet" {
                var st = idleStates[sessionId] ?? SessionIdleState(lastEventTs: now(), lastStopShapedTs: nil, lastStopShapedPhrase: nil, lastUserMsgTs: nil, lastIdleTriageTs: nil)
                st.planUngradableStreak = (st.planUngradableStepId == currentStepId) ? st.planUngradableStreak + 1 : 1
                st.planUngradableStepId = currentStepId
                idleStates[sessionId] = st
            } else if var st = idleStates[sessionId], st.planUngradableStreak != 0 || st.planUngradableStepId != nil {
                st.planUngradableStreak = 0
                st.planUngradableStepId = nil
                idleStates[sessionId] = st
            }
            await executePlanAction(action, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
            return .handled
        }

        // Case 2: no plan AND there is an objective to plan from -> create a plan.
        // The objective is the session's opening prompt (SessionObjective); the
        // dispatcher path's userPrompt is a proxy we ALSO require so we never
        // plan a session with no captured intent. If there is already ANY plan
        // (awaiting approval / completed / aborted), do NOT create another - that
        // is the human's to act on - and fall through.
        if !planLoop.hasAnyPlan(sessionId: sessionId),
           SessionObjective.read(sessionId: sessionId)?.isEmpty == false {
            // FIX 4: gate the plan-CREATION LLM call through the SAME dispatch
            // permission the drive path uses (mirrors the Case-1 canDispatch guard).
            // Without it, an ungrounded planner re-fires an 8192-token planForSession
            // call every idle interval for up to the 6h loop budget - the create
            // path had no stop/backoff of its own. When the loop is not .proceed
            // (stopped by an earlier backoff, or paused), do NOT create; stay silent
            // (.handled) so the Dispatcher path below does not run and re-fire either.
            if let lc = loopController {
                let decision = await lc.canDispatch(sessionId: sessionId)
                guard case .proceed = decision else {
                    trace.emit("planloop", "idle: NOT creating plan session=\(sessionId) - loop not dispatchable (\(decision)); staying silent")
                    return .handled
                }
            }
            // capCheck note: the Planner's plan-creation LLM calls run through the
            // shared LLMClient, whose createMessage ALREADY enforces the daily cost
            // cap (capCheck), so the plan path inherits the same cap as the main
            // client. The cap seam is the LLMClient construction in main.swift (the
            // Planner is handed that same client); nothing to wire from here.
            let action = await planLoop.createPlan(
                sessionId: sessionId, cwd: cwd, gitBranch: branch, window: window
            )
            if case let .none(reason) = action {
                // FIX 4: the Planner could not ground a plan. Record it as a
                // low/error dispatch so the consecutive-low backoff climbs and the
                // loop STOPS retrying an ungrounded planner at 1/min (the canDispatch
                // guard above then blocks the next create). Then fall through to the
                // single-step Dispatcher exactly as today.
                if let lc = loopController {
                    if reason == "planner_error" {
                        await lc.recordDispatch(sessionId: sessionId, result: .error(reasoning: "plan creation errored"))
                    } else {
                        await lc.recordDispatch(sessionId: sessionId, result: .lowConfidence(reasoning: "planner could not ground a plan"))
                    }
                }
                return .fellThrough
            }
            await executePlanAction(action, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
            return .handled
        }

        // No approved plan to drive, and nothing to plan: the Dispatcher path runs.
        return .fellThrough
    }

    /// Carry out a PlanLoopAction by emitting the right decision through the
    /// existing path (the same `onDecision` -> InterventionRouter pipeline a
    /// dispatch uses), so a plan injection is marked + ledgered and a plan notify
    /// is a normal banner. PlanLoop has already done all persistence + loop-state
    /// changes; this is purely the surfacing.
    private func executePlanAction(
        _ action: PlanLoopAction,
        sessionId: String,
        cwd: String?,
        branch: String?,
        response: AnthropicMessageResponse,
        userPrompt: String?
    ) async {
        switch action {
        case let .none(reason):
            trace.emit("planloop", "action=none reason=\(reason) session=\(sessionId) (no surface)")
        case let .inject(text, stepIndex, kind):
            trace.emit("planloop", "action=inject step=\(stepIndex) kind=\(kind.rawValue) session=\(sessionId) bytes=\(text.utf8.count)")
            emitPlanInject(text: text, stepIndex: stepIndex, kind: kind, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
        case let .notify(message, escalation):
            trace.emit("planloop", "action=notify escalation=\(escalation?.rawValue ?? "-") session=\(sessionId)")
            emitPlanNotify(message: message, escalation: escalation, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
        }
    }

    /// Emit a plan-step injection as a high-confidence `.continue` decision. This
    /// routes through InterventionRouter.routeContinue -> continueHighInjectOrDegrade,
    /// which records it in the InjectionLedger before typing - so a plan injection
    /// is NEVER a raw inject and is always ledgered (the triage will not read it
    /// back as owner authorization). The injection itself reads clean, no in-text
    /// banner. The proposal text is redacted (defense in depth),
    /// matching the dispatch path.
    private func emitPlanInject(
        text: String,
        stepIndex: Int,
        kind: PlanLoopAction.InjectKind,
        sessionId: String,
        cwd: String?,
        branch: String?,
        response: AnthropicMessageResponse,
        userPrompt: String?
    ) {
        // FIX 1 (CRITICAL): harm-screen EVERY plan inject before it is typed into
        // the live session. The plan text is model-generated from an attacker-
        // influenceable context (repo output, issue bodies), and this is the single
        // choke point ALL plan injects flow through - step objectives (firstStep/
        // nextStep/replanStep) AND the evaluator's redirect/steer feedback. The only
        // net downstream (DeterministicCatch) runs post-hoc on already-executed
        // Bash; screening here is BEFORE the keystrokes. On a block: do NOT inject.
        // Escalate to the human (a notify banner) and pause the loop so the same
        // blocked text is not re-driven every idle tick.
        if case let .block(reason) = InjectionSafetyScreen.screen(text) {
            trace.emit("planloop", "plan_inject_screened_blocked reason=\(reason) session=\(sessionId) step=\(stepIndex) kind=\(kind.rawValue) - withholding the inject, escalating to human")
            if let lc = loopController {
                Task { await lc.stop(sessionId: sessionId, reason: .explicitStop) }
            }
            // Persist the plan .paused (like FIX 2) so the block is DURABLE across a
            // restart - otherwise runningPlan() would re-drive the .running plan,
            // regenerate the same screened text, and re-block/notify every tick.
            if let plan = (try? planLoop?.planStore.currentPlan(sessionId: sessionId)) ?? nil,
               plan.status == .running {
                try? planLoop?.planStore.updatePlan(planId: plan.id, status: .paused, currentStepIndex: plan.currentStepIndex, now: now())
            }
            emitPlanNotify(
                message: "Supervisor withheld an auto-generated plan step for step \(stepIndex + 1) because it did not pass the injection safety screen (\(reason)). The plan is paused; review the step and give direction before it continues.",
                escalation: .safetySecurity,
                sessionId: sessionId, cwd: cwd, branch: branch,
                response: response, userPrompt: userPrompt
            )
            return
        }
        let candidate = TriageCandidate(
            category: "worker_idle_post_completion",
            severity: .medium,
            matchedCommand: "(plan) step \(stepIndex + 1) [\(kind.rawValue)]",
            action: .continue,
            reasoningPlain: "Supervisor is driving the approved plan: sending step \(stepIndex + 1).",
            reasoningTechnical: "v0.2.0 plan harness: inject kind=\(kind.rawValue) for plan step index=\(stepIndex).",
            asymmetryNote: nil,
            suggestedInjectText: nil,
            questionType: nil,
            nextTaskProposal: redactor.redact(text),
            confidence: "high"
        )
        emitSyntheticIdleDecision(candidate, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
    }

    /// Emit a plan notify (plan ready to approve, plan complete, escalation,
    /// abort) as a plain `.notify` decision through the same path - a normal
    /// banner, no injection. The message is redacted for defense in depth.
    private func emitPlanNotify(
        message: String,
        escalation: EscalationTrigger?,
        sessionId: String,
        cwd: String?,
        branch: String?,
        response: AnthropicMessageResponse,
        userPrompt: String?
    ) {
        let severity: FlagSeverity = (escalation == nil) ? .low : .medium
        let candidate = TriageCandidate(
            category: "worker_idle_post_completion",
            severity: severity,
            matchedCommand: escalation.map { "(plan) escalate: \($0.rawValue)" } ?? "(plan) status",
            action: .notify,
            reasoningPlain: redactor.redact(message),
            reasoningTechnical: "v0.2.0 plan harness notify escalation=\(escalation?.rawValue ?? "-").",
            asymmetryNote: nil,
            suggestedInjectText: nil,
            questionType: nil,
            nextTaskProposal: nil,
            confidence: "low"
        )
        emitSyntheticIdleDecision(candidate, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: userPrompt)
    }

    /// A zero-usage synthetic AnthropicMessageResponse for engine-originated plan
    /// notifies that have no real LLM call behind them (e.g. the FIX 6 ambiguous-
    /// approve banner). Mirrors the watchdog helpers' inline synthetic responses.
    private static func syntheticPlanResponse(id: String, model: String) -> AnthropicMessageResponse {
        let usage = AnthropicUsage(input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
        return AnthropicMessageResponse(
            id: id, type: "message", role: "assistant",
            model: model, content: [], stop_reason: nil,
            stop_sequence: nil, usage: usage
        )
    }

    /// Wrap a plan candidate in a TriageDecision (with the synthetic idle trigger
    /// the rest of the idle path already uses) and hand it to `onDecision` -> the
    /// router. Shared by emitPlanInject / emitPlanNotify so both take the exact
    /// same delivery path a dispatch does.
    private func emitSyntheticIdleDecision(
        _ candidate: TriageCandidate,
        sessionId: String,
        cwd: String?,
        branch: String?,
        response: AnthropicMessageResponse,
        userPrompt: String?
    ) {
        let pseudoTrigger = BashToolCallInfo(
            sessionId: sessionId,
            command: "(plan) \(candidate.matchedCommand)",
            description: "Synthetic trigger for the v0.2.0 plan harness.",
            toolUseId: "plan-\(UUID().uuidString)",
            turnUUID: "plan-\(UUID().uuidString)",
            ts: now()
        )
        let decision = TriageDecision(
            sessionId: sessionId,
            cwd: cwd,
            branch: branch,
            candidate: candidate,
            triggeringEvent: pseudoTrigger,
            usage: response.usage,
            model: response.model,
            prePost: .preExecution,
            recentEvents: perSessionWindow[sessionId] ?? [],
            lastUserPrompt: userPrompt
        )
        onActivityChange?(.flagged(severity: candidate.severity, action: candidate.action, reasoningPlain: candidate.reasoningPlain, sessionId: sessionId, sessionCwd: cwd))
        onDecision?(decision)
    }

    /// v0.2.0 M2d-2: approve a plan and inject its first step. The M3 UI calls
    /// this from the panel's Approve button; it sets the plan approved+running
    /// and injects the first step through the marked + ledgered path. No-op
    /// (logs) when no PlanLoop is wired or the plan is not approvable. cwd/branch
    /// for the inject are resolved from the engine's per-session caches.
    public func approvePlan(planId: String) async {
        guard let planLoop = self.planLoop else {
            trace.emit("planloop", "approvePlan: no PlanLoop wired (plan id=\(planId)) - ignoring")
            return
        }
        let action = await planLoop.approvePlan(planId: planId, now: now())
        // Resolve a session + cwd/branch for the inject. PlanLoop.approvePlan
        // returns an inject for the plan's first step; we need the session to
        // target. Read it back from the plan record.
        guard let plan = (try? planLoop.planStore.plan(id: planId)) ?? nil else {
            trace.emit("planloop", "approvePlan: plan id=\(planId) not found after approve")
            return
        }
        let sessionId = plan.sessionId
        let cwd = sessionCwd[sessionId]
        let branch = sessionBranch[sessionId]
        // Build a minimal response stand-in for usage/model on the synthetic
        // decision (no LLM call happened here - approval is a UI action).
        let usage = AnthropicUsage(input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
        let response = AnthropicMessageResponse(
            id: "plan-approve", type: "message", role: "assistant",
            model: "plan-harness", content: [], stop_reason: nil,
            stop_sequence: nil, usage: usage
        )
        await executePlanAction(action, sessionId: sessionId, cwd: cwd, branch: branch, response: response, userPrompt: nil)
    }

    // MARK: - Triage call

    private func evaluate(call: BashToolCallInfo, prePost: TriageDecision.PrePost) async {
        if supervisorPausedRead() { return }  // global pause (see evaluateIdle)
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
            // Restart-replay dedupe (launch-audit fix, 2026-07): tails resume
            // from the last PERSISTED offset, so an engine restart re-delivers
            // the trailing events. Loop/idle state mutations are already
            // stale-gated in consume() (stale_event_state_skipped), but the
            // catch re-fired on the replayed tool_use — two identical
            // destructive-action banners for one command. Dedupe on the
            // event's tool_use uuid, persisted in sqlite so it survives the
            // restart. Keyed on identity, NOT age: a never-seen destructive
            // event still always fires, however late Supervisor reads it.
            if let auditStore,
               (try? auditStore.hasDeterministicCatch(eventUuid: call.toolUseId)) == true {
                trace.emit("triage", "CATCH_deduped session=\(call.sessionId) toolUseId=\(call.toolUseId) pattern=\(caught.pattern) — already caught+notified this event (replay), not re-notifying")
                onActivityChange?(.idle)
                return
            }
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
            // v0.2.0 observability A: record the block "receipt" (command +
            // target + risk reason) ADDITIVELY. Does not change the decision; the
            // catch classification (caught.pattern / .effect) is unchanged.
            recordBlockAudit(sessionId: call.sessionId, command: call.command, caught: caught, cwd: cwd)
            onActivityChange?(.flagged(severity: .high, action: .pause, reasoningPlain: candidate.reasoningPlain, sessionId: call.sessionId, sessionCwd: cwd))
            onDecision?(decision)
            // Stamp the dedupe ledger AFTER emitting the decision: a crash
            // between notify and stamp re-notifies (annoying), the other order
            // could swallow a never-delivered catch (unsafe). A write failure
            // degrades to pre-fix behavior — fire on replay — never to a miss.
            if let auditStore {
                do { try auditStore.recordDeterministicCatch(eventUuid: call.toolUseId, sessionId: call.sessionId, at: now()) }
                catch { trace.emit("audit", "record deterministic-catch dedupe FAILED session=\(call.sessionId) toolUseId=\(call.toolUseId) error=\(error)") }
            }
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
            onActivityChange?(.flagged(severity: candidate.severity, action: candidate.action, reasoningPlain: candidate.reasoningPlain, sessionId: call.sessionId, sessionCwd: cwd))
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
        if supervisorPausedRead() { return }  // global pause (see evaluateIdle)
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
            onActivityChange?(.flagged(severity: enriched.severity, action: enriched.action, reasoningPlain: enriched.reasoningPlain, sessionId: info.sessionId, sessionCwd: cwd))
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
                // Act-vs-escalate gate. The answer injects only when its
                // confidence MEETS the owner's decision-sensitivity minimum;
                // otherwise it degrades to a human-facing taste notify. At
                // .balanced (the default) the minimum is .medium, so this is
                // EXACTLY the prior `confidence == .low` degrade. Cautious raises
                // it to .high (medium now escalates - ask the human more); an
                // empty answer always degrades regardless of the dial.
                let minConfidence = decisionSensitivityRead().minAnswerConfidenceToInject
                if answer.answer.isEmpty || !answer.confidence.meets(minConfidence) {
                    // Degrade: the answer didn't clear the act bar for this
                    // sensitivity (or PRINCIPLES had no clear answer). Rewrite as
                    // taste and surface to the user.
                    trace.emit("triage", "engineering answer below act-bar (confidence=\(answer.confidence.rawValue) min=\(minConfidence.rawValue)); degrading to taste session=\(sessionId)")
                    let rewrite = (try? await answerer.translateTaste(question: question))?.plainQuestion
                        ?? candidate.reasoningPlain
                    return reconfigure(
                        candidate,
                        action: .notify,
                        reasoningPlain: rewrite
                    )
                }
                // v0.2.0 observability A (the headline): record the auto-answer
                // WITH its justification - the question, the context it drew on,
                // the authorizing principle (the answer's citation), and the
                // answer itself. ADDITIVE; the returned candidate is unchanged.
                recordAutoAnswerAudit(
                    sessionId: sessionId,
                    question: question,
                    contextUsed: context,
                    citation: answer.citation,
                    answer: answer.answer
                )
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
        confidence: String?? = nil,
        // Fix #12: nil preserves the candidate's existing value, non-nil
        // overrides. Only the dispatcher's high-confidence auto-dispatch sets it.
        dedupDelivery: Bool? = nil
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
            confidence: confidence ?? c.confidence,
            dedupDelivery: dedupDelivery ?? c.dedupDelivery
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
