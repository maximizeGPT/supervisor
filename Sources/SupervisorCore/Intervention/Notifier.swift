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
    /// goes into the trace, not the banner. `copiedToClipboard` reports
    /// whether the router's clipboard write ACTUALLY succeeded
    /// (NSPasteboard.setString can fail) — the banner only claims "it's
    /// on your clipboard" when it's true, and falls back to embedding
    /// the text when it isn't.
    case injectDegraded(intendedText: String, reason: String, copiedToClipboard: Bool)
    /// Fix #4a: a desktop inject (or continue-dispatch) could not target the
    /// Claude conversation because Screen Recording is off. Unlike the generic
    /// degrade, this is ACTIONABLE: the banner names the missing permission and
    /// where to grant it, so the operator knows the plan did not die, it is
    /// waiting on one toggle. `intendedText` is the prompt that did not land so
    /// the user can still paste it manually. Both the inject and the
    /// continue-dispatch paths route here when they see screen_recording_denied,
    /// once per (re)injection, not per tick. `copiedToClipboard` is the real
    /// clipboard-write result (see `injectDegraded`) so the banner never
    /// claims a clipboard it didn't populate.
    case screenRecordingDenied(intendedText: String, copiedToClipboard: Bool)
    /// v0.4.0 Part B: continue dispatched. CGEventPost typed the
    /// dispatcher's next_task_proposal into Claude Code. `promptHead`
    /// is the first ~80 chars so the banner can show what got sent.
    case continueFired(pid: pid_t, bytes: Int, promptHead: String)
    /// v0.4.0 Part B: dispatcher returned medium confidence — surface
    /// the proposal to the user via banner rather than injecting it.
    /// `proposal` is the next_task_proposal text; the banner invites
    /// the user to paste it themselves. `copiedToClipboard` is true only
    /// when this outcome is a HIGH-confidence dispatch that degraded on a
    /// delivery failure and the router actually placed the proposal on the
    /// clipboard (a genuine medium proposal never touches the clipboard).
    case continueProposedMedium(proposal: String, justification: String, copiedToClipboard: Bool)
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

public extension InterventionOutcome {
    /// issue #60 follow-up: the payload-free kind persisted to
    /// `flags.intervention_outcome` (FlagStore.markInterventionOutcome). The
    /// associated values (PIDs, intended text, doc paths) stay in the trace +
    /// banner where they already live; the scorecard only needs WHICH outcome
    /// the executor actually produced.
    var kind: InterventionOutcomeKind {
        switch self {
        case .notifyOnly:             return .notifyOnly
        case .pauseSucceeded:         return .pauseSucceeded
        case .killSucceeded:          return .killSucceeded
        case .injectSucceeded:        return .injectSucceeded
        case .injectDegraded:         return .injectDegraded
        case .screenRecordingDenied:  return .screenRecordingDenied
        case .continueFired:          return .continueFired
        case .continueProposedMedium: return .continueProposedMedium
        case .continueLowConfidence:  return .continueLowConfidence
        case .queued:                 return .queued
        }
    }
}

/// Gate in front of every `UNUserNotificationCenter.current()` touch.
/// `current()` does not return nil on failure — it raises
/// NSInternalInconsistencyException and the uncaught exception abort()s the
/// process — whenever the process has no bundle identifier (a bare binary,
/// a detached spawn, the SPM xctest harness). That abort took down real user
/// launches: three identical SIGABRTs on 2026-07-05, crash frame
/// `+[UNUserNotificationCenter currentNotificationCenter]` inside
/// `enterRunningState`. Notifications must degrade; they must never decide
/// whether the app launches.
public enum NotificationCenterGate {
    /// A bundle identifier alone is NOT sufficient: the SPM xctest runner
    /// has one, and `current()` still aborts there with
    /// "bundleProxyForCurrentProcess is nil" (proven by this package's own
    /// test run). The condition UserNotifications actually needs is a real
    /// registered .app bundle, so gate on both.
    public static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// The degraded stand-in when the notification center is unavailable: keeps
/// the InterventionRouter fully functional (inject/pause/kill still run) and
/// records every banner it could not post in the trace log.
public struct TraceOnlyNotifier: Notifying {
    private let trace: TraceLog

    public init(trace: TraceLog = .shared) {
        self.trace = trace
    }

    public func post(decision: TriageDecision) async -> Notifier.Outcome {
        trace.emit("notifier", "degraded (no bundle identifier): banner suppressed for \(decision.candidate.category)")
        return .failed(reason: "notification center unavailable: no bundle identifier")
    }
}

public final class Notifier: Notifying, @unchecked Sendable {

    public enum Outcome: Sendable, Equatable {
        case posted
        case skippedDeniedSilently  // Spike-2 path: center.add succeeded but no banner
        case failed(reason: String)
    }

    /// The only safe way to build a real Notifier from app code. Returns nil
    /// (instead of crashing the launch) when `UNUserNotificationCenter.current()`
    /// would abort — see NotificationCenterGate. The plain `init` stays for
    /// tests that inject their own center.
    public static func ifAvailable(
        trace: TraceLog = .shared,
        onResult: (@Sendable (TriageDecision, InterventionOutcome) -> Void)? = nil
    ) -> Notifier? {
        guard NotificationCenterGate.available else {
            trace.emit("notifier", "ERROR notification center unavailable (no bundle identifier); notifications disabled, launch continues")
            return nil
        }
        return Notifier(trace: trace, onResult: onResult)
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

    // MARK: - Notification categories

    /// Category + action identifiers for the one Context Health notification. The
    /// app registers the category and handles the action to open the window.
    public static let contextHealthCategoryID = "SUPERVISOR_CONTEXT_HEALTH"
    public static let contextHealthShowActionID = "SUPERVISOR_SHOW_CONTEXT_HEALTH"

    /// issue #60 follow-up: the category every flag banner now carries. It has
    /// NO actions (banner appearance is unchanged) — its one job is
    /// `.customDismissAction`, which makes macOS deliver an explicit banner
    /// dismissal (UNNotificationDismissActionIdentifier) to the app delegate,
    /// where it lands as `flags.user_response = dismissed` via
    /// FlagStore.markUserResponseIfUnset. A plain tap (default action) is
    /// engagement, not a response, and is deliberately NOT recorded.
    public static let flagCategoryID = "SUPERVISOR_FLAG"

    /// userInfo key carrying the `flags` table row id on a flag banner, so the
    /// delegate's dismiss handler can address the exact persisted row. Only
    /// set when the decision was actually persisted (decision.flagId != nil).
    public static let flagIdUserInfoKey = "supervisor_flag_id"

    /// Register the notification categories: Context Health (its "Show me"
    /// action) + the flag category (dismiss-action delivery). Call once at
    /// launch. `setNotificationCategories` REPLACES the set, so both are
    /// registered together (the merge the old per-category comment promised
    /// once flags started using a category).
    public func registerNotificationCategories() {
        let show = UNNotificationAction(
            identifier: Self.contextHealthShowActionID, title: "Show me", options: [.foreground])
        let contextHealth = UNNotificationCategory(
            identifier: Self.contextHealthCategoryID, actions: [show], intentIdentifiers: [], options: [])
        let flag = UNNotificationCategory(
            identifier: Self.flagCategoryID, actions: [], intentIdentifiers: [],
            options: [.customDismissAction])
        center.setNotificationCategories([contextHealth, flag])
    }

    /// Post THE single Context Health nudge — the one earned notification fired the
    /// first time a background audit finds notable context drift. Carries a "Show
    /// me" action (the app opens the window) and NO sound, so it reads as a calm
    /// heads-up, never a safety alarm.
    @discardableResult
    public func postContextHealth(count: Int, lines: Int) async -> Outcome {
        let content = UNMutableNotificationContent()
        content.title = "Context Health"
        let lineClause = lines > 0 ? " (~\(lines) lines)" : ""
        content.body = "Supervisor found \(count) cleanup\(count == 1 ? "" : "s") in your Claude context\(lineClause). Nothing changed."
        content.categoryIdentifier = Self.contextHealthCategoryID
        let request = UNNotificationRequest(
            identifier: "supervisor.contexthealth.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            trace.emit("notifier", "posted context-health nudge: \(count) cleanups")
            return .posted
        } catch {
            trace.emit("notifier", "context-health nudge failed: \(error)")
            return .failed(reason: "\(error)")
        }
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
        Self.attachFlagIdentity(to: content, decision: decision)

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
        case .screenRecordingDenied:
            return "Supervisor needs Screen Recording to drive Claude"
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
        Self.composeBody(for: decision, outcome: outcome)
    }

    /// The pure composer behind `body(for:outcome:)` — static so tests can
    /// assert the REAL banner copy (constructing a Notifier needs
    /// UNUserNotificationCenter, which aborts in the xctest harness).
    public static func composeBody(for decision: TriageDecision, outcome: InterventionOutcome) -> String {
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
        case .injectDegraded(let intendedText, _, let copiedToClipboard):
            // The answer is COPIED TO THE CLIPBOARD by the router (a notification
            // body truncates and isn't selectable, so embedding the text here made
            // it useless). Point the owner at the clipboard; a short head lets them
            // confirm which answer it is. HONESTY: only claim the clipboard when
            // the write actually succeeded — otherwise fall back to embedding the
            // text (truncated, but real) rather than pointing at an empty pasteboard.
            if copiedToClipboard {
                return plain + "\n\nSupervisor couldn't type the answer automatically, so it copied it to your clipboard — paste it into Claude Code with Cmd-V." + Self.clipboardHead(intendedText)
            } else {
                return plain + "\n\nSupervisor couldn't type the answer automatically, and copying it to your clipboard also failed. Here is the answer to paste yourself:\n\n" + intendedText
            }
        case .screenRecordingDenied(let intendedText, let copiedToClipboard):
            let base = plain + "\n\nSupervisor could not drive the Claude desktop app: Screen Recording permission is off. Grant it in System Settings > Privacy and Security > Screen Recording, then Supervisor will resume."
            if copiedToClipboard {
                return base + "\n\nThe answer is on your clipboard — paste it into Claude with Cmd-V." + Self.clipboardHead(intendedText)
            } else {
                return base + "\n\nHere is the answer to paste into Claude yourself:\n\n" + intendedText
            }
        case .continueFired(_, _, let promptHead):
            let head = promptHead.count >= 80 ? promptHead + "..." : promptHead
            return "Supervisor sent Claude Code its next task: \(head)"
        case .continueProposedMedium(let proposal, _, let copiedToClipboard):
            let closing = copiedToClipboard
                ? "It's on your clipboard — paste it into Claude Code with Cmd-V if you agree, or write your own direction."
                : "Paste this into Claude Code if you agree, or write your own direction."
            return "Supervisor thinks Claude Code should work on this next, but wants your approval:\n\n\(proposal)\n\n" + closing
        case .continueLowConfidence(let reasoning):
            return "Claude Code finished its work and Supervisor couldn't decide what to do next. \(reasoning)\n\nTell Claude Code what to work on, or add items to the issue queue."
        case .queued(let promptHead):
            let head = promptHead.count >= 80 ? promptHead + "..." : promptHead
            return "Claude Code is busy, so Supervisor queued this and will send it when the worker is ready:\n\n\(head)"
        }
    }

    /// A short "(starts: …)" tail so the owner recognizes which answer is on the
    /// clipboard, without dumping the full (often long) text into a banner that
    /// would truncate it anyway. Empty for empty text.
    static func clipboardHead(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let head = trimmed.replacingOccurrences(of: "\n", with: " ").prefix(60)
        return "\n(starts: \"\(head)\(trimmed.count > 60 ? "…" : "")\")"
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
        Self.attachFlagIdentity(to: content, decision: decision)

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

    /// issue #60 follow-up: stamp a flag banner with the flag category (so its
    /// explicit dismissal is delivered to the delegate — `.customDismissAction`)
    /// and, when the decision was persisted, the flag row id in userInfo so the
    /// dismiss handler can address the exact row. Shared by both flag-banner
    /// paths (`post` + `postInterventionResult`); the Context Health nudge has
    /// its own category and never routes through here.
    private static func attachFlagIdentity(to content: UNMutableNotificationContent, decision: TriageDecision) {
        content.categoryIdentifier = flagCategoryID
        if let flagId = decision.flagId {
            content.userInfo[flagIdUserInfoKey] = flagId
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { (cont: CheckedContinuation<UNNotificationSettings, Never>) in
            center.getNotificationSettings { cont.resume(returning: $0) }
        }
    }
}
