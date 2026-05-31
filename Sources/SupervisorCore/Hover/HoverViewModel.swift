// HoverViewModel.swift
//
// Drives the always-on-top hover window. Subscribes to EventBus +
// a "flag arrived" callback wired by the main app, exposes published
// properties the SwiftUI view binds to.
//
// One viewmodel per process. v0.1.0 follows a "show the most recently
// active session" rule — no session picker yet. Multi-session UI is
// v0.1.2.

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

    /// The project name (cwd basename) for use in plain labels.
    private var projectName: String = ""

    // MARK: - Dependencies

    private let bus: EventBus
    private let trace: TraceLog
    private var busCancellable: AnyCancellable?

    public init(bus: EventBus, trace: TraceLog = .shared) {
        self.bus = bus
        self.trace = trace
        // Bind self locally before the Task so Swift 5.10 (CI toolchain)
        // doesn't reject the closure as "reference to captured var 'self'
        // in concurrently-executing code." Swift 6.2 (my local) is more
        // permissive; CI is the source of truth. Same nil-safety as the
        // original `self?.handle` — guard returns early on dealloc.
        self.busCancellable = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event: event) }
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
            plainLabel = projectName.isEmpty
                ? "Watching — all clear"
                : "Watching \(projectName) — all clear"
        case .bashToolCall(let info):
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
        case .userPrompt, .assistantText, .systemSignal:
            break
        }
    }
}
