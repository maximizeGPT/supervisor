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
    /// Examples: "Watching — all clear", "Paused Claude Code — needs
    /// your attention", "Checking something..."
    @Published public private(set) var plainLabel: String = "Watching — all clear"

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
            ? "Watching — all clear"
            : "Watching \(projectName) — all clear"
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
            ? "Watching — all clear"
            : "Watching \(projectName) — all clear"
        detailLabel = ""
        trace.emit("hover", "flag acknowledged; activity -> idle")
    }

    /// Plain-language label for a flag, based on the action taken.
    static func plainLabelForFlag(action: FlagAction, reasoningPlain: String?) -> String {
        // If we have a plain reasoning, use a short version of it.
        if let plain = reasoningPlain, !plain.isEmpty {
            // Take the first sentence, capped at 60 chars for the hover.
            let firstSentence = plain.split(separator: ".", maxSplits: 1).first.map(String.init) ?? plain
            let capped = firstSentence.count > 60 ? String(firstSentence.prefix(57)) + "..." : firstSentence
            return capped
        }
        // Generic fallback per action type.
        switch action {
        case .notify:     return "Noticed something — check the notification"
        case .inject:     return "Answered a question for Claude Code"
        case .continue:   return "Sent Claude Code its next task"
        case .selfExtend: return "Helping the dispatch loop recover"
        case .pause:      return "Paused Claude Code — needs your attention"
        case .kill:       return "Stopped Claude Code — something looked dangerous"
        }
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
                ? "Watching — all clear"
                : "Watching \(projectName) — all clear"
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
