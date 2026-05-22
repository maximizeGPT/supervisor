// Notifier.swift
//
// UNUserNotificationCenter wrapper with the pre-NEXT-action copy rules
// from DESIGN.md §6.5. The honest framing:
//
//   - preExecution    → "Claude Code is about to <cmd> — pause?"
//   - alreadyExecuted → "Claude Code just ran <cmd> — stop further action?"
//
// On notification-denied (Spike 2 graceful degradation), `add` still
// succeeds and the flag lands in macOS Notification Center, just without
// a banner. We log and proceed — the user has already been told during
// onboarding that this can happen.

import Foundation
import UserNotifications

public final class Notifier: @unchecked Sendable {

    public enum Outcome: Sendable, Equatable {
        case posted
        case skippedDeniedSilently  // Spike-2 path: center.add succeeded but no banner
        case failed(reason: String)
    }

    private let center: UNUserNotificationCenter
    private let trace: TraceLog

    public init(
        center: UNUserNotificationCenter = .current(),
        trace: TraceLog = .shared
    ) {
        self.center = center
        self.trace = trace
    }

    /// Post a notification for a triage decision. Returns the outcome
    /// (mostly for tests / observability — the caller doesn't generally
    /// branch on it in v0.1.0).
    @discardableResult
    public func post(decision: TriageDecision) async -> Outcome {
        let content = UNMutableNotificationContent()
        content.title = "Supervisor: \(decision.candidate.category)"
        content.body = body(for: decision)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "supervisor.flag.\(UUID().uuidString)",
            content: content,
            trigger: nil  // post immediately
        )

        let settings = await currentSettings()
        do {
            try await center.add(request)
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                trace.emit("notifier", "posted category=\(decision.candidate.category) severity=\(decision.candidate.severity.rawValue)")
                return .posted
            case .denied:
                trace.emit("notifier", "added to Notification Center (banner suppressed): \(decision.candidate.reasoning.prefix(80))")
                return .skippedDeniedSilently
            case .notDetermined:
                trace.emit("notifier", "notification status notDetermined — posted but visibility uncertain")
                return .posted
            @unknown default:
                return .posted
            }
        } catch {
            trace.emit("notifier", "ERROR center.add threw: \(error)")
            return .failed(reason: "\(error)")
        }
    }

    /// v0.1.0 body copy. Branches on whether the tool has already run.
    public func body(for decision: TriageDecision) -> String {
        let cmd = decision.candidate.matchedCommand
        let head = cmd.split(separator: "\n").first.map(String.init) ?? cmd
        switch decision.prePost {
        case .preExecution:
            // The tool hasn't returned in our window — possibly because
            // it's a slow Bash. We can honestly use future tense.
            return "Claude Code is about to run `\(head)`. \(decision.candidate.reasoning.prefix(160))"
        case .alreadyExecuted:
            return "Claude Code just ran `\(head)`. \(decision.candidate.reasoning.prefix(160)) Stop further action?"
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { (cont: CheckedContinuation<UNNotificationSettings, Never>) in
            center.getNotificationSettings { cont.resume(returning: $0) }
        }
    }
}
