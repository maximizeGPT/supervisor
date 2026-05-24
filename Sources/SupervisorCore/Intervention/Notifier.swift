// Notifier.swift
//
// UNUserNotificationCenter wrapper. v0.1.2 banner shape is a tiny composer
// that prepends a fixed brand prefix to `reasoning_plain` — Haiku now
// writes the full sentence (with the right pre/post tense based on
// whether the tool already executed) so there's no copy synthesis to do
// downstream. The prefix is "Supervisor: " and is intentionally not
// reading from any LLM output — it gives the banner a consistent visual
// identity even if Haiku ever produces a subject-less sentence.
//
// On notification-denied (Spike 2 graceful degradation), `add` still
// succeeds and the flag lands in macOS Notification Center, just without
// a banner. We log and proceed — the user has already been told during
// onboarding that this can happen.

import Foundation
import UserNotifications

/// Abstracts the banner-posting surface so InterventionRouter tests can
/// inject a capturing mock instead of constructing a real Notifier
/// (which crashes the xctest harness — UNUserNotificationCenter.current()
/// aborts on missing CFBundleIdentifier).
public protocol Notifying: Sendable {
    func post(decision: TriageDecision) async -> Notifier.Outcome

    /// v0.1.4 Gap 1+2+3: post a banner whose body reflects whether the
    /// router's pause/kill executor actually fired. Has a default
    /// implementation that delegates to `post(decision:)` so existing
    /// mocks keep compiling — real Notifier overrides to surface the
    /// outcome-specific copy (pause → PID + `kill -CONT` recovery;
    /// kill → "start a new claude invocation" follow-on).
    func postInterventionResult(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) async -> Notifier.Outcome
}

public extension Notifying {
    func postInterventionResult(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) async -> Notifier.Outcome {
        await post(decision: decision)
    }
}

/// What the router actually did, used by Notifier to compose the right
/// banner body. `notifyOnly` is the default (action == .notify, or any
/// degraded pause/kill that fell back to a banner). `pauseSucceeded` /
/// `killSucceeded` only flow when the SIGSTOP / SIGTERM actually
/// landed — the banner then includes the recovery information the user
/// needs to act.
///
/// v0.1.6: `recoveryDocPath` is the URL where RecoveryDocWriter wrote
/// the markdown handoff. May be nil if the doc write failed (filesystem
/// error, etc.) — Notifier falls back to inline recovery copy in that
/// case so the banner is never silent about how to recover.
public enum InterventionOutcome: Sendable, Equatable {
    case notifyOnly
    case pauseSucceeded(pid: pid_t, recoveryDocPath: URL?)
    case killSucceeded(recoveryDocPath: URL?)
    /// v0.3.0: inject landed in the hosting terminal. `bytes` is the
    /// payload size (informational). The banner just says "Supervisor
    /// answered" — the answer text isn't repeated in the banner
    /// because it's already in the user's terminal.
    case injectSucceeded(pid: pid_t, bytes: Int)
    /// v0.3.0: inject couldn't run. The banner falls back to surfacing
    /// the intended text so the user can paste it manually. `reason`
    /// goes into the trace, not the banner.
    case injectDegraded(intendedText: String, reason: String)
}

public final class Notifier: Notifying, @unchecked Sendable {

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
                trace.emit("notifier", "added to Notification Center (banner suppressed): \(decision.candidate.reasoningPlain.prefix(80))")
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

    /// Banner body prefix — kept as a constant so tests and callers reference
    /// the same string and never drift. Trailing space is part of the prefix.
    public static let bannerPrefix = "Supervisor: "

    /// v0.1.2 body composer. Just the brand prefix + the plain-English
    /// reasoning Haiku wrote. No pre/post tense synthesis here — Haiku
    /// writes its own tense based on the "Has the command already
    /// executed?" section of the triage prompt.
    public func body(for decision: TriageDecision) -> String {
        Self.bannerPrefix + decision.candidate.reasoningPlain
    }

    /// v0.1.4 Gap 1+2+3 + v0.1.6 recovery doc pointer: outcome-aware body
    /// composer. Pause/kill banners include the recovery doc path so the
    /// user can open it from Finder or `open <path>`. If the doc write
    /// failed (path is nil), the banner falls back to v0.1.4's inline
    /// recovery copy — never silent about how to recover.
    public func body(for decision: TriageDecision, outcome: InterventionOutcome) -> String {
        let base = Self.bannerPrefix + decision.candidate.reasoningPlain
        switch outcome {
        case .notifyOnly:
            return base
        case .pauseSucceeded(let pid, let recoveryDocPath):
            if let path = recoveryDocPath {
                return base + " Session paused (PID \(pid)). Recovery: \(path.path)"
            } else {
                return base + " Session paused. To resume: `kill -CONT \(pid)`."
            }
        case .killSucceeded(let recoveryDocPath):
            if let path = recoveryDocPath {
                return base + " Session killed. Read recovery doc before starting new `claude`: \(path.path)"
            } else {
                return base + " Session killed. Start a new `claude` invocation to continue."
            }
        case .injectSucceeded(let pid, let bytes):
            // The injected text is already in the user's terminal — no
            // need to repeat it in the banner. Just acknowledge.
            return base + " Supervisor answered (PID \(pid), \(bytes) bytes injected)."
        case .injectDegraded(let intendedText, _):
            // The inject path failed; surface the intended text so the
            // user can paste it manually. Reason goes to trace, not the
            // banner — banner stays user-facing, not diagnostic.
            return base + " Supervisor would have answered: \(intendedText) Paste this into Claude Code to continue."
        }
    }

    /// v0.1.4 Gap 1+2+3: post a banner reflecting the actual outcome
    /// of the intervention. The router calls this after a successful
    /// SIGSTOP / SIGTERM (and on the existing notify path) so the user
    /// gets ONE consistent surface for "Supervisor did X" no matter
    /// which executor handled the verdict.
    @discardableResult
    public func postInterventionResult(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) async -> Outcome {
        let content = UNMutableNotificationContent()
        content.title = "Supervisor: \(decision.candidate.category)"
        content.body = body(for: decision, outcome: outcome)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "supervisor.flag.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let settings = await currentSettings()
        do {
            try await center.add(request)
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                trace.emit("notifier", "posted outcome=\(outcome) category=\(decision.candidate.category) severity=\(decision.candidate.severity.rawValue)")
                return .posted
            case .denied:
                trace.emit("notifier", "added to Notification Center (banner suppressed) outcome=\(outcome): \(decision.candidate.reasoningPlain.prefix(80))")
                return .skippedDeniedSilently
            case .notDetermined:
                trace.emit("notifier", "notification status notDetermined outcome=\(outcome)")
                return .posted
            @unknown default:
                return .posted
            }
        } catch {
            trace.emit("notifier", "ERROR center.add threw outcome=\(outcome): \(error)")
            return .failed(reason: "\(error)")
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { (cont: CheckedContinuation<UNNotificationSettings, Never>) in
            center.getNotificationSettings { cont.resume(returning: $0) }
        }
    }
}
