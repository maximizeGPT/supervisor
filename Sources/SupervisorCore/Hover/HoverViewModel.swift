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

        // Trigger the transient flash.
        actionFlash = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s flash
            self?.actionFlash = false
        }
    }

    /// Announce that Supervisor rebuilt and relaunched itself. Shows a
    /// short hover message and flashes, so the user can see the app
    /// updated on its own. Called at launch when a self-rebuild marker
    /// is present (written by the deploy step). Clears back to the idle
    /// watching label after a few seconds.
    public func announceSelfRebuild(version: String? = nil) {
        let label = version.map { "Supervisor updated itself to \($0)" }
            ?? "Supervisor updated itself"
        plainLabel = label

        let record = ActionRecord(action: .selfExtend, plainDescription: label)
        recentActions.insert(record, at: 0)
        if recentActions.count > 20 {
            recentActions.removeLast()
        }
        trace.emit("hover", "self-rebuild announced: \(label)")

        actionFlash = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.actionFlash = false
        }
        // Return to the idle watching label after a few seconds.
        acknowledgeDebouncerTask?.cancel()
        acknowledgeDebouncerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.acknowledgeFlag()
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

    /// Called by TriageEngine when it starts a Haiku call.
    public func triageStarted() {
        activity = .triaging
        plainLabel = "Checking something..."
        trace.emit("hover", "activity -> triaging")
    }

    /// Called by TriageEngine when a Haiku batch finishes without flags.
    public func triageFinishedNoFlag() {
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
        case .inject:     return "Answered a question for Claude Code"
        case .continue:   return "Sent Claude Code its next task"
        case .selfExtend: return "Helping the dispatch loop recover"
        case .pause:      return "Paused Claude Code. Needs your attention."
        case .kill:       return "Stopped Claude Code. Something looked dangerous."
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
            plainLabel = projectName.isEmpty
                ? "Watching. All clear"
                : "Watching \(projectName). All clear"
        case .bashToolCall(let info):
            toolCallCount += 1
            // Plain headline: "Running a command"
            // Detail (secondary, de-emphasized): the actual command
            let head = info.command
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)
                ?? info.command
            plainLabel = "Running a command"
            detailLabel = String(head.prefix(80))
        case .bashToolResult(let info):
            if info.isError {
                detailLabel += " (errored)"
            }
        case .userPrompt:
            turnCount += 1
        case .assistantText, .systemSignal:
            break
        }
    }
}
