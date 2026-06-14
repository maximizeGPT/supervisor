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
    /// v0.4.0 Part B: continue dispatched. CGEventPost typed the
    /// dispatcher's next_task_proposal into Claude Code. `promptHead`
    /// is the first ~80 chars so the banner can show what got sent.
    case continueFired(pid: pid_t, bytes: Int, promptHead: String)
    /// v0.4.0 Part B: dispatcher returned medium confidence — surface
    /// the proposal to the user via banner rather than injecting it.
    /// `proposal` is the next_task_proposal text; the banner invites
    /// the user to paste it themselves.
    case continueProposedMedium(proposal: String, justification: String)
    /// v0.4.0 Part B: dispatcher returned low confidence — supervisor
    /// saw the idle state but couldn't pick a next task. `reasoning`
    /// is the dispatcher's justification (lands in the banner so the
    /// user knows WHY supervisor went quiet).
    case continueLowConfidence(reasoning: String)
    /// Piece 3 (queued-as-delivered, 2026-06-13): the router was ready to
    /// deliver, but the human is actively at the keyboard (Piece 1's
    /// HumanActivityProbe), so it deferred rather than typing over them. This
    /// is NOT a failure and NOT a fire — the dispatch is held; the loop
    /// re-attempts on the next idle tick and delivers once the human pauses.
    /// `promptHead` is the first ~80 chars of what's queued, for the banner.
    case queued(promptHead: String)
}

public final class Notifier: Notifying, @unchecked Sendable {

    public enum Outcome: Sendable, Equatable {
        case posted
        case skippedDeniedSilently  // Spike-2 path: center.add succeeded but no banner
        case failed(reason: String)
    }

    private let center: UNUserNotificationCenter
    private let trace: TraceLog

    /// v0.9.0 (integrity): result hook fired with the SAME (decision, outcome)
    /// that drives the banner body, so every OTHER surface (the hover action
    /// log + live label) reports what the executor ACTUALLY did, never intent.
    /// Set by the app at construction; nil in tests/mocks.
    private let onResult: (@Sendable (TriageDecision, InterventionOutcome) -> Void)?

    public init(
        center: UNUserNotificationCenter = .current(),
        trace: TraceLog = .shared,
        onResult: (@Sendable (TriageDecision, InterventionOutcome) -> Void)? = nil
    ) {
        self.center = center
        self.trace = trace
        self.onResult = onResult
    }

    /// Post a notification for a triage decision. Returns the outcome
    /// (mostly for tests / observability — the caller doesn't generally
    /// branch on it in v0.1.0).
    @discardableResult
    public func post(decision: TriageDecision) async -> Outcome {
        let content = UNMutableNotificationContent()
        content.title = Self.plainTitle(for: .notifyOnly)
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

    /// Plain-language notification title. Uses the triage's plain
    /// reasoning to describe what happened, not raw category names.
    public static func plainTitle(for outcome: InterventionOutcome) -> String {
        switch outcome {
        case .notifyOnly:
            return "Supervisor noticed something"
        case .pauseSucceeded:
            return "Supervisor paused Claude Code"
        case .killSucceeded:
            return "Supervisor stopped Claude Code"
        case .injectSucceeded:
            return "Supervisor answered a question"
        case .injectDegraded:
            return "Supervisor has an answer for you"
        case .continueFired:
            return "Supervisor kept Claude Code working"
        case .continueProposedMedium:
            return "Supervisor has a suggestion"
        case .continueLowConfidence:
            return "Supervisor is waiting for direction"
        case .queued:
            return "Supervisor queued a task"
        }
    }

    /// v0.1.2 body composer. Plain-language — what happened and what
    /// (if anything) the user should do. No raw category names, no
    /// severity integers, no PIDs in the headline.
    public func body(for decision: TriageDecision) -> String {
        decision.candidate.reasoningPlain
    }

    /// Outcome-aware body composer. Plain language throughout.
    /// Recovery details (doc paths, PIDs) go to a second line when
    /// relevant, never the headline.
    public func body(for decision: TriageDecision, outcome: InterventionOutcome) -> String {
        let plain = decision.candidate.reasoningPlain
        switch outcome {
        case .notifyOnly:
            return plain
        case .pauseSucceeded(_, let recoveryDocPath):
            if let path = recoveryDocPath {
                return plain + "\n\nClaude Code is paused. Open the recovery doc for next steps: \(path.path)"
            } else {
                return plain + "\n\nClaude Code is paused and waiting for you to decide what to do next."
            }
        case .killSucceeded(let recoveryDocPath):
            if let path = recoveryDocPath {
                return plain + "\n\nThe session was stopped. Read the recovery doc before continuing: \(path.path)"
            } else {
                return plain + "\n\nThe session was stopped. Start a new Claude Code session to continue your work."
            }
        case .injectSucceeded:
            return plain + "\n\nSupervisor answered the question directly. Check your terminal to see the response."
        case .injectDegraded(let intendedText, _):
            return plain + "\n\nSupervisor couldn't type the answer automatically. Paste this into Claude Code:\n\(intendedText)"
        case .continueFired(_, _, let promptHead):
            let head = promptHead.count >= 80 ? promptHead + "..." : promptHead
            return "Supervisor sent Claude Code its next task: \(head)"
        case .continueProposedMedium(let proposal, _):
            return "Supervisor thinks Claude Code should work on this next, but wants your approval:\n\n\(proposal)\n\nPaste this into Claude Code if you agree, or write your own direction."
        case .continueLowConfidence(let reasoning):
            return "Claude Code finished its work and Supervisor couldn't decide what to do next. \(reasoning)\n\nTell Claude Code what to work on, or add items to the issue queue."
        case .queued(let promptHead):
            let head = promptHead.count >= 80 ? promptHead + "..." : promptHead
            return "Claude Code is busy, so Supervisor queued this and will send it when the worker is ready:\n\n\(head)"
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
        // v0.9.0 (integrity): drive the hover action log + live label from the
        // SAME outcome the banner uses, BEFORE composing the banner, so no
        // surface claims an inject it didn't make — even if the banner is
        // suppressed (notifications denied).
        onResult?(decision, outcome)
        let content = UNMutableNotificationContent()
        content.title = Self.plainTitle(for: outcome)
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
