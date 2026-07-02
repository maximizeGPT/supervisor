// HoverViewModel.swift
//
// Drives the always-on-top hover window. Subscribes to EventBus +
// a "flag arrived" callback wired by the main app, exposes published
// properties the SwiftUI view binds to.
//
// One viewmodel per process. v0.1.0 follows a "show the most recently
// active session" rule — no session picker yet. Multi-session UI is
// v0.1.2.
//
// v0.1.7: expanded panel support. The viewmodel now tracks session
// metrics (turn count, tool call count) and holds references to
// CostStore + FlagStore for the expanded panel's data needs.

import Combine
import Foundation

@MainActor
public final class HoverViewModel: ObservableObject {

    public enum Activity: Sendable, Equatable {
        case idle
        case triaging
        /// Carries severity (dot color), action (overlay icon), and
        /// the triage's plain-voice reasoning (hover headline).
        case flagged(severity: FlagSeverity, action: FlagAction, reasoningPlain: String? = nil)
        /// v0.3.0 (P0-3): Supervisor is alive but model triage is NOT
        /// running — provider unreachable, dead API key, or the daily
        /// cost cap. Amber dot; `reason` is the hover headline ("Can't
        /// reach Anthropic — check your API key"). A green "All clear"
        /// in this state would be the product lying about watching.
        case degraded(reason: String)
    }

    // MARK: - Published surface

    /// Plain-language headline a non-engineer can read at a glance.
    /// Examples: "Watching. All clear", "Paused Claude Code — needs
    /// your attention", "Checking something..."
    @Published public private(set) var plainLabel: String = "Watching. All clear"

    /// Secondary detail (de-emphasized). The actual command or tool
    /// name, shown only when there's something specific to surface.
    /// Empty string hides the secondary line.
    @Published public private(set) var detailLabel: String = ""

    /// Cumulative count of flags raised this lifetime. Resets across launches.
    @Published public private(set) var flagCount: Int = 0

    /// Drives the dot color + pulse intensity.
    @Published public private(set) var activity: Activity = .idle

    /// Whether the expanded panel is visible.
    @Published public var isExpanded: Bool = false

    // MARK: - Owner runtime toggles (panel controls)

    /// Global pause — when true, Supervisor is dormant (no triage/dispatch/
    /// inject). Mirrors the RuntimeToggles marker; the panel's Pause button
    /// flips it and the engine reads the marker live, so it takes effect at once.
    @Published public private(set) var supervisorPaused: Bool = RuntimeToggles.supervisorPaused

    /// 4-hour loop-cap disabled — when true, the loop runs without the 4-hour
    /// wall-clock hard stop (for long sessions / the screen-record demo). The
    /// other hard stops still apply.
    @Published public private(set) var loopCapDisabled: Bool = RuntimeToggles.loopCapDisabled

    // MARK: - Session metrics (v0.1.7 expanded panel)

    /// Number of assistant turns (user prompt → assistant response cycles).
    @Published public private(set) var turnCount: Int = 0

    /// Number of tool calls observed this session.
    @Published public private(set) var toolCallCount: Int = 0

    /// The triage model name (e.g. "claude-haiku-4-5-20251001").
    @Published public private(set) var modelName: String = ""

    /// The project name (cwd basename) for use in plain labels.
    public private(set) var projectName: String = ""

    /// The full cwd path for the expanded panel header.
    @Published public private(set) var sessionCwd: String = ""

    /// Whether a resume from pause is in progress.
    @Published public private(set) var isResuming: Bool = false

    // MARK: - Action log (v0.8.1 — "what Supervisor DID")

    /// A record of a substantial action Supervisor took.
    public struct ActionRecord: Identifiable, Equatable {
        public let id: String
        public let ts: Date
        public let action: FlagAction
        public let plainDescription: String

        public init(action: FlagAction, plainDescription: String, ts: Date = Date()) {
            self.id = UUID().uuidString
            self.ts = ts
            self.action = action
            self.plainDescription = plainDescription
        }
    }

    /// Recent actions (newest first). Capped at 20.
    @Published public private(set) var recentActions: [ActionRecord] = []

    /// Transient "action flash" — true for a brief moment when Supervisor
    /// takes a substantial action (pause/kill/inject/continue/selfExtend).
    /// Drives a distinct flash animation on the hover dot.
    @Published public private(set) var actionFlash: Bool = false

    // MARK: - Dependencies

    private let bus: EventBus
    private let trace: TraceLog
    public let costStore: CostStore?
    public let flagStore: FlagStore?
    private var busCancellable: AnyCancellable?
    private var acknowledgeDebouncerTask: Task<Void, Never>?
    /// Cancels the in-flight "turn the flash off" timer when a newer action
    /// arrives, so back-to-back actions don't clip each other's flash.
    private var flashOffTask: Task<Void, Never>?
    /// How long to hold the flagged state before auto-acknowledging.
    /// Resets on each new flag.
    public let acknowledgeDebounceDuration: TimeInterval

    /// Callback to resume a paused session. Takes cwd, returns true on
    /// success. Wired in main.swift with ProcessLocator + SignalSender.
    public var resumeHandler: ((String) async -> Bool)?

    public init(
        bus: EventBus,
        trace: TraceLog = .shared,
        acknowledgeDebounceDuration: TimeInterval = 5.0,
        initialFlagCount: Int = 0,
        costStore: CostStore? = nil,
        flagStore: FlagStore? = nil,
        modelName: String = ""
    ) {
        self.bus = bus
        self.trace = trace
        self.acknowledgeDebounceDuration = acknowledgeDebounceDuration
        self.flagCount = initialFlagCount
        self.costStore = costStore
        self.flagStore = flagStore
        self.modelName = modelName
        self.busCancellable = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event: event) }
        }
        if initialFlagCount > 0 {
            trace.emit("hover", "seeded flagCount=\(initialFlagCount) from history")
        }
        // F11: if the app launches while globally paused, the hover must say so
        // from the first frame — never a green "All clear" over a dormant engine.
        if supervisorPaused {
            reflectSupervisorPaused(true)
        }
    }

    // MARK: - Paused-state honesty (v0.3.0 F11)

    /// The hover label shown while Supervisor is globally paused. Deliberately
    /// NOT "All clear": the engine is dormant, spending nothing and watching
    /// nothing, so a green "watching" reading would be the product lying.
    public static let pausedLabel = "Supervisor paused"

    /// Reflect the global-pause state on the hover. Pure presentation — does
    /// NOT touch the marker file (the toggle setter owns that), so tests can
    /// exercise the precedence without writing a real marker.
    ///
    /// Precedence: a live safety flag or a genuine network-degraded state is a
    /// more urgent truth than "paused", so paused never overwrites either — it
    /// only paints when the hover is otherwise idle/triaging. It reuses the
    /// `.degraded` presentation (amber dot — "alive, but not model-watching"
    /// is literally true when paused).
    public func reflectSupervisorPaused(_ paused: Bool) {
        supervisorPaused = paused
        if paused {
            switch activity {
            case .flagged, .degraded:
                // A safety flag / network-degraded state outranks paused.
                trace.emit("hover", "paused: presentation held (\(activity) outranks paused)")
            case .idle, .triaging:
                activity = .degraded(reason: Self.pausedLabel)
                plainLabel = Self.pausedLabel
                detailLabel = ""
                acknowledgeDebouncerTask?.cancel()
                trace.emit("hover", "activity -> paused")
            }
        } else {
            // Leaving paused: restore idle only if the paused presentation is
            // what's currently showing (don't stomp a flag/network-degraded
            // state that landed while paused).
            if case .degraded(let reason) = activity, reason == Self.pausedLabel {
                activity = .idle
                plainLabel = projectName.isEmpty
                    ? "Watching. All clear"
                    : "Watching \(projectName). All clear"
                detailLabel = ""
                trace.emit("hover", "unpaused; activity -> idle")
            }
        }
    }

    // MARK: - Expanded panel data

    /// Today's estimated cost from CostStore. Returns 0 if store unavailable.
    public func todayCostUSD() -> Double {
        guard let store = costStore else { return 0 }
        return (try? store.today().estimatedCostUsd) ?? 0
    }

    /// Recent flags from FlagStore, most recent first.
    public func recentFlags(limit: Int = 20) -> [StoredFlag] {
        guard let store = flagStore else { return [] }
        return (try? store.recent(limit: limit)) ?? []
    }

    /// Toggle expanded panel state.
    public func toggleExpanded() {
        isExpanded.toggle()
        trace.emit("hover", "expanded panel \(isExpanded ? "opened" : "closed")")
    }

    /// Owner control: pause / resume Supervisor globally. The engine reads the
    /// marker live, so the effect is immediate — no rebuild, no restart.
    public func toggleSupervisorPaused() {
        let next = !supervisorPaused
        RuntimeToggles.setSupervisorPaused(next)
        trace.emit("hover", "owner toggled supervisor_paused=\(next)")
        // F11: keep every surface honest — reflect the pause on the hover
        // (label + amber dot) the instant it's toggled, not just in the engine.
        reflectSupervisorPaused(next)
    }

    /// Owner control: turn the 4-hour loop cap off / on for this machine.
    public func toggleLoopCapDisabled() {
        let next = !loopCapDisabled
        RuntimeToggles.setLoopCapDisabled(next)
        loopCapDisabled = next
        trace.emit("hover", "owner toggled loop_cap_disabled=\(next)")
    }

    /// Record user response (dismiss / false positive) for a flag.
    public func respondToFlag(flagId: String, response: FlagUserResponse) {
        guard let store = flagStore else {
            trace.emit("hover", "respondToFlag: no flagStore")
            return
        }
        do {
            try store.markUserResponse(flagId: flagId, response: response)
            trace.emit("hover", "respondToFlag id=\(flagId) response=\(response.rawValue)")
        } catch {
            trace.emit("hover", "respondToFlag ERROR: \(error)")
        }
    }

    /// Reject — the human override. Effect depends on current state:
    ///   - If Supervisor PAUSED Claude Code: reject = let it continue (SIGCONT).
    ///   - Otherwise: reject = record the override. Future dispatches/actions
    ///     for this flag are suppressed.
    /// Per PRINCIPLES: reject never overrides kill-level safety (a kill
    /// already happened, the session ended — reject just records dissent).
    public func rejectFlag(flagId: String, action: FlagAction) {
        // Record the rejection first.
        respondToFlag(flagId: flagId, response: .rejected)

        // If the live state is paused and this is the flag that caused it,
        // rejecting means "let Claude Code continue" — send SIGCONT.
        if action == .pause && isPaused {
            trace.emit("hover", "reject: releasing pause (SIGCONT) for flagId=\(flagId)")
            resumePausedSession()
        } else if action == .kill {
            trace.emit("hover", "reject: kill already fired, recording dissent for flagId=\(flagId)")
        } else {
            trace.emit("hover", "reject: recorded override for flagId=\(flagId) action=\(action.rawValue)")
        }
    }

    // MARK: - Action recording

    /// Record a substantial action Supervisor just took. Triggers the
    /// action flash and adds to the action log. Called from main.swift
    /// after the InterventionRouter dispatches.
    public func recordAction(action: FlagAction, description: String) {
        // Only record substantial actions, not plain notify.
        guard action != .notify else { return }

        let record = ActionRecord(action: action, plainDescription: description)
        recentActions.insert(record, at: 0)
        if recentActions.count > 20 {
            recentActions.removeLast()
        }
        trace.emit("hover", "action recorded: \(action.rawValue) — \(description)")

        // Flash AND surface the plain-language label, so the user sees — in
        // the moment — WHAT Supervisor did ("Paused Claude Code", "Sent
        // Claude its next task"), not just a border glow. The label settles
        // back to the activity label after the hold. HoverWindowController
        // observes actionFlash and forces the hover visible for the
        // duration, so this is seen even when no terminal is frontmost.
        beginActionFlash(label: description, holdSeconds: 2.5)
    }

    /// Announce that Supervisor rebuilt and relaunched itself. Shows a
    /// short hover message and flashes, so the user can see the app
    /// updated on its own. Called at launch when a self-rebuild marker
    /// is present (written by the deploy step). Clears back to the idle
    /// watching label after a few seconds.
    public func announceSelfRebuild(version: String? = nil) {
        let label = version.map { "Supervisor updated itself to \($0)" }
            ?? "Supervisor updated itself"

        let record = ActionRecord(action: .selfExtend, plainDescription: label)
        recentActions.insert(record, at: 0)
        if recentActions.count > 20 {
            recentActions.removeLast()
        }
        trace.emit("hover", "self-rebuild announced: \(label)")

        // Longer hold than a normal action: the hover window is recreated on
        // relaunch and the frontmost app right after a self-deploy is almost
        // never a terminal, so the normal visibility gate would hide this.
        // The controller force-shows while actionFlash is true; a 5s hold
        // gives the user (and on-screen verification) time to actually see
        // "Supervisor updated itself" before it settles back.
        beginActionFlash(label: label, holdSeconds: 5.0)
    }

    /// Drive the action flash: surface `label`, glow/scale the hover (via
    /// `actionFlash`), then settle the label back to the live activity after
    /// `holdSeconds`. Centralized so recordAction and announceSelfRebuild
    /// behave identically. HoverWindowController observes `actionFlash` and
    /// forces the hover visible for the hold, so the flash is seen even when
    /// no terminal is frontmost.
    private func beginActionFlash(label: String, holdSeconds: Double) {
        plainLabel = label
        detailLabel = ""   // clear any stale command detail for a clean flash
        actionFlash = true

        flashOffTask?.cancel()
        acknowledgeDebouncerTask?.cancel()
        let holdNanos = UInt64(max(0, holdSeconds) * 1_000_000_000)
        flashOffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: holdNanos)
            guard !Task.isCancelled, let self else { return }
            self.actionFlash = false
            self.plainLabel = self.labelForCurrentActivity()
        }
    }

    /// The plain label that matches the current `activity` — used to settle
    /// the hover after a transient action flash without reverting an active
    /// pause/flag to "all clear".
    private func labelForCurrentActivity() -> String {
        switch activity {
        case .idle:
            return projectName.isEmpty
                ? "Watching. All clear"
                : "Watching \(projectName). All clear"
        case .triaging:
            return "Checking something..."
        case let .flagged(_, action, reasoningPlain):
            return Self.plainLabelForFlag(action: action, reasoningPlain: reasoningPlain)
        case let .degraded(reason):
            return reason
        }
    }

    /// Whether the current flag is a pause that can be resumed.
    public var isPaused: Bool {
        guard case .flagged(_, .pause, _) = activity else { return false }
        return true
    }

    /// Resume a paused session by sending SIGCONT to the process.
    /// Called from the expanded panel's Resume button.
    public func resumePausedSession() {
        guard isPaused, !sessionCwd.isEmpty, let handler = resumeHandler else {
            trace.emit("hover", "resume: precondition failed (isPaused=\(isPaused) cwd=\(sessionCwd.isEmpty ? "empty" : "set") handler=\(resumeHandler == nil ? "nil" : "set"))")
            return
        }
        isResuming = true
        let cwd = sessionCwd
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await handler(cwd)
            self.isResuming = false
            if ok {
                self.trace.emit("hover", "resume: SIGCONT sent successfully cwd=\(cwd)")
                self.acknowledgeFlag()
            } else {
                self.trace.emit("hover", "resume: SIGCONT failed cwd=\(cwd)")
            }
        }
    }

    // MARK: - Triage state hooks

    /// v0.3.0 (P0-3): the degraded reason while the engine can't complete
    /// model calls (provider unreachable / dead key / daily cap). Non-nil
    /// keeps the hover honest across transient label changes: a flag
    /// auto-acknowledge settles back to `.degraded`, never to a false
    /// "All clear". Set by `enterDegraded`, cleared by `clearDegraded`
    /// (wired to the engine's recovery hook) and by the success-path
    /// `triageFinishedNoFlag`.
    private var degradedReason: String?

    /// Called (via the app's onActivityChange wiring) when TriageEngine
    /// enters or re-asserts the degraded state. The reason IS the label —
    /// the hover must say "Can't reach Anthropic — check your API key",
    /// not "Watching. All clear", while triage is dead.
    public func enterDegraded(reason: String) {
        degradedReason = reason
        activity = .degraded(reason: reason)
        plainLabel = reason
        detailLabel = ""
        // A pending flag auto-acknowledge would reset the label to "All
        // clear" seconds after this honest state lands — cancel it. The
        // degraded state clears only on a successful model call.
        acknowledgeDebouncerTask?.cancel()
        trace.emit("hover", "activity -> degraded reason=\(reason)")
    }

    /// Called on recovery (first successful model call after degraded).
    /// Restores idle if the hover is still showing the degraded state;
    /// silent by design — the green dot returning IS the announcement.
    public func clearDegraded() {
        guard degradedReason != nil else { return }
        degradedReason = nil
        if case .degraded = activity {
            activity = .idle
            plainLabel = projectName.isEmpty
                ? "Watching. All clear"
                : "Watching \(projectName). All clear"
            trace.emit("hover", "degraded cleared; activity -> idle")
        }
    }

    /// Called by TriageEngine when it starts a Haiku call.
    public func triageStarted() {
        // Don't stomp an active action flash. On a busy session the triage
        // engine fires constantly; without this guard it overwrites the
        // "Paused Claude Code" / "Supervisor updated itself" label (and the
        // dot) milliseconds after the flash sets it, so the user never sees
        // the action. The flash owns the hover for its brief duration.
        guard !actionFlash else {
            trace.emit("hover", "triage started — label held (action flash active)")
            return
        }
        // While degraded, hold the amber state through retry attempts —
        // flashing "Checking something..." per retry reads as recovered
        // when it isn't. A successful retry restores idle via
        // triageFinishedNoFlag / clearDegraded.
        if case .degraded = activity {
            trace.emit("hover", "triage started — label held (degraded)")
            return
        }
        activity = .triaging
        plainLabel = "Checking something..."
        trace.emit("hover", "activity -> triaging")
    }

    /// Called by TriageEngine when a Haiku batch finishes without flags.
    public func triageFinishedNoFlag() {
        // A completed batch means the model call succeeded — the degraded
        // state (if any) is over regardless of the flash guard below.
        degradedReason = nil
        guard !actionFlash else {
            trace.emit("hover", "triage idle — label held (action flash active)")
            return
        }
        activity = .idle
        plainLabel = projectName.isEmpty
            ? "Watching. All clear"
            : "Watching \(projectName). All clear"
        trace.emit("hover", "activity -> idle (no flag)")
    }

    /// Called by the FlagRouter when a flag is raised. The plain label
    /// says what happened in language a non-engineer understands.
    /// `reasoningPlain` is the triage's plain-voice summary — if
    /// available, the label uses it; otherwise falls back to a
    /// generic action-based sentence.
    public func flagRaised(severity: FlagSeverity, action: FlagAction, reasoningPlain: String? = nil) {
        flagCount += 1
        activity = .flagged(severity: severity, action: action)
        plainLabel = Self.plainLabelForFlag(action: action, reasoningPlain: reasoningPlain)
        trace.emit("hover", "flag raised severity=\(severity.rawValue) action=\(action.rawValue) total=\(flagCount)")

        // Auto-acknowledge after the debounce duration. Each new flag
        // resets the timer so rapid flags don't flicker.
        acknowledgeDebouncerTask?.cancel()
        let duration = acknowledgeDebounceDuration
        acknowledgeDebouncerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.acknowledgeFlag()
        }
    }

    /// Resets the activity dot to idle. UI calls after a flag has been
    /// acknowledged by the user, or after a debounce timer expires.
    public func acknowledgeFlag() {
        // While degraded, a flag ack (e.g. a deterministic-catch pause,
        // which needs no model call) settles back to the amber degraded
        // state — never to a green "All clear" the engine can't back up.
        if let reason = degradedReason {
            activity = .degraded(reason: reason)
            plainLabel = reason
            detailLabel = ""
            trace.emit("hover", "flag acknowledged; activity -> degraded (still can't reach model)")
            return
        }
        activity = .idle
        plainLabel = projectName.isEmpty
            ? "Watching. All clear"
            : "Watching \(projectName). All clear"
        detailLabel = ""
        trace.emit("hover", "flag acknowledged; activity -> idle")
    }

    /// Plain-language label for a flag, based on the action taken.
    public static func plainLabelForFlag(action: FlagAction, reasoningPlain: String?) -> String {
        // If we have a plain reasoning, use a short version of it.
        if let plain = reasoningPlain, !plain.isEmpty {
            // Take the first sentence using Foundation's sentence boundary
            // detection. A naive split on "." breaks on any embedded period:
            // version numbers ("v0.8.3"), abbreviations ("e.g."), file paths
            // ("config.yaml"). ICU's sentence tokenizer handles all of those.
            let firstSentence = Self.firstSentence(of: plain)
            let capped = firstSentence.count > 60 ? String(firstSentence.prefix(57)) + "..." : firstSentence
            return capped
        }
        // Generic fallback per action type.
        switch action {
        case .notify:     return "Noticed something. Check the notification."
        // Flag-time label, set BEFORE the inject runs — present tense, never a
        // success claim. The honest result lands later via
        // recordInterventionOutcome once the executor actually finishes.
        case .inject:     return "Answering a question for Claude Code"
        case .continue:   return "Sending Claude Code its next task"
        case .selfExtend: return "Helping the dispatch loop recover"
        case .pause:      return "Paused Claude Code. Needs your attention."
        case .kill:       return "Stopped Claude Code. Something looked dangerous."
        }
    }

    /// v0.9.0 (integrity): record the action-log entry + live label from the
    /// ACTUAL intervention outcome, never from intent. The app wires this to the
    /// Notifier's result hook, so it fires with the same (decision, outcome) the
    /// banner uses, AFTER the router's executor finishes. A degraded inject or
    /// continue reports honestly that it couldn't place the text and points to
    /// the banner; it NEVER claims it answered. This replaces the old eager
    /// record that fired at decision time with the intent label.
    public func recordInterventionOutcome(_ decision: TriageDecision, _ outcome: InterventionOutcome) {
        guard let result = Self.actionForOutcome(outcome) else { return }
        recordAction(action: result.action, description: result.label)
        plainLabel = result.label
        trace.emit("hover", "action recorded from REAL outcome: \(result.label)")
    }

    /// Map a real intervention outcome to an honest (action, label), or nil when
    /// there's nothing Supervisor actually did to record (a plain notify, or a
    /// low-confidence "waiting for direction" — neither is an action taken, and
    /// a degraded pause/kill arrives as `.notifyOnly`, so it never claims it
    /// paused/stopped something it didn't).
    nonisolated static func actionForOutcome(_ outcome: InterventionOutcome) -> (action: FlagAction, label: String)? {
        switch outcome {
        case .injectSucceeded:
            return (.inject, "Answered a question for Claude Code")
        case .injectDegraded:
            return (.inject, "Couldn't place the answer in the conversation. It's in the banner to paste.")
        case .continueFired:
            return (.continue, "Sent Claude Code its next task")
        case .continueProposedMedium:
            return (.continue, "Suggested a next task. It's in the banner for you.")
        case .queued:
            // Piece 3: deferred because the human is typing. Honest — it has
            // NOT sent/answered; it's holding the dispatch until the worker is
            // ready, when the loop re-fires and delivers it.
            return (.continue, "Queued — will send when Claude Code is ready")
        case .pauseSucceeded:
            return (.pause, "Paused Claude Code. Needs your attention.")
        case .killSucceeded:
            return (.kill, "Stopped Claude Code. Something looked dangerous.")
        case .notifyOnly, .continueLowConfidence:
            return nil
        }
    }

    /// First sentence of `text`, using Foundation's sentence boundary
    /// detection (ICU). Robust against embedded periods (versions,
    /// abbreviations, file paths) that a naive split on "." would treat
    /// as sentence ends. Returns the whole string if no sentence boundary
    /// is found.
    static func firstSentence(of text: String) -> String {
        var result: String?
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .bySentences
        ) { substring, _, _, stop in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                result = s
                stop.pointee = true
            }
        }
        return result ?? text
    }

    // MARK: - Event subscription

    private func handle(event: SupervisorEvent) {
        switch event {
        case .sessionStart(let info):
            let basename = (info.cwd as NSString).lastPathComponent
            projectName = basename.isEmpty ? "" : basename
            sessionCwd = info.cwd
            // Reset per-session metrics on new session.
            turnCount = 0
            toolCallCount = 0
            // Don't stomp an active action flash (see triageStarted). On a
            // busy session these bus events fire constantly and were the main
            // reason the flash/announce label was never seen — they
            // overwrote it within milliseconds.
            if !actionFlash {
                plainLabel = projectName.isEmpty
                    ? "Watching. All clear"
                    : "Watching \(projectName). All clear"
            }
        case .bashToolCall(let info):
            toolCallCount += 1
            guard !actionFlash else { break }   // hold the flash label
            // Plain headline: "Running a command"
            // Detail (secondary, de-emphasized): the actual command
            let head = info.command
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)
                ?? info.command
            plainLabel = "Running a command"
            detailLabel = String(head.prefix(80))
        case .bashToolResult(let info):
            if info.isError && !actionFlash {
                detailLabel += " (errored)"
            }
        case .userPrompt:
            turnCount += 1
        case .assistantText, .systemSignal:
            break
        }
    }
}
