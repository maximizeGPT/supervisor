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
        case flagged(severity: FlagSeverity)
    }

    // MARK: - Published surface

    /// Short label for the currently-focused session — typically the cwd
    /// basename. "(no session)" until the first event arrives.
    @Published public private(set) var sessionLabel: String = "(no session)"

    /// One-line description of the most recent tool call. "" until the
    /// first Bash tool_call lands.
    @Published public private(set) var currentToolDescription: String = ""

    /// Cumulative count of flags raised this lifetime. Resets across launches.
    @Published public private(set) var flagCount: Int = 0

    /// Drives the dot color + pulse intensity.
    @Published public private(set) var activity: Activity = .idle

    // MARK: - Dependencies

    private let bus: EventBus
    private let trace: TraceLog
    private var busCancellable: AnyCancellable?

    public init(bus: EventBus, trace: TraceLog = .shared) {
        self.bus = bus
        self.trace = trace
        self.busCancellable = bus.subscribe { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
    }

    // MARK: - Triage state hooks

    /// Called by TriageEngine when it starts a Haiku call.
    public func triageStarted() {
        activity = .triaging
        trace.emit("hover", "activity -> triaging")
    }

    /// Called by TriageEngine when a Haiku batch finishes without flags.
    public func triageFinishedNoFlag() {
        // Hold .triaging visible for ~200ms so the user notices it; then
        // drop back to idle.
        activity = .idle
        trace.emit("hover", "activity -> idle (no flag)")
    }

    /// Called by the FlagRouter when a flag is raised.
    public func flagRaised(severity: FlagSeverity) {
        flagCount += 1
        activity = .flagged(severity: severity)
        trace.emit("hover", "flag raised severity=\(severity.rawValue) total=\(flagCount)")
    }

    /// Resets the activity dot to idle. UI calls after a flag has been
    /// acknowledged by the user, or after a debounce timer expires.
    public func acknowledgeFlag() {
        activity = .idle
        trace.emit("hover", "flag acknowledged; activity -> idle")
    }

    // MARK: - Event subscription

    private func handle(event: SupervisorEvent) {
        switch event {
        case .sessionStart(let info):
            sessionLabel = (info.cwd as NSString).lastPathComponent.isEmpty
                ? info.sessionId
                : (info.cwd as NSString).lastPathComponent
        case .bashToolCall(let info):
            // Show "Bash: <first line of command, trimmed>" — keeps the
            // hover label informative without overflowing.
            let head = info.command
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)
                ?? info.command
            currentToolDescription = "Bash: \(head.prefix(80))"
        case .bashToolResult(let info):
            // After a Bash returns, briefly annotate with err/ok.
            if info.isError {
                currentToolDescription += " (errored)"
            }
        case .userPrompt, .assistantText, .systemSignal:
            break
        }
    }
}
