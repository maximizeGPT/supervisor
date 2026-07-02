// OnboardingState.swift
//
// The state machine for the three-step onboarding flow:
//   1. keyEntry      → user enters their Anthropic API key
//   2. axCheck       → user grants Accessibility in System Settings
//   3. notifCheck    → user grants Notifications (or proceeds with
//                      `denied`, accepting the degradation banner)
//   complete         → onboarding window dismisses, main app comes up
//
// State is a sum type so the UI binds against one value, and so all
// invalid combinations (e.g. axCheck with a key-entry error attached)
// are unrepresentable.

import Foundation

public enum OnboardingState: Sendable, Equatable {

    /// User is entering their API key. Optional inline error from a
    /// previous validation attempt — UI surfaces it next to the field.
    case keyEntry(error: KeyEntryError? = nil)

    /// Async validation in flight. UI disables the form + shows progress.
    case keyValidating

    /// Waiting for the user to grant AX. `prompted` indicates whether the
    /// macOS "open System Settings?" sheet has already been shown — we
    /// only show it once per onboarding session.
    case axCheck(prompted: Bool = false)

    /// Notifications step. `status` is the most recently observed
    /// authorization status; UI branches on it.
    case notifCheck(status: NotificationAuthStatus)

    /// Onboarding is done. UI dismisses the window. `notifDegraded` is
    /// true when the user proceeded with notifications denied — main app
    /// shows a one-time hover-window banner explaining the degradation.
    case complete(notifDegraded: Bool)
}

/// Reasons key validation could fail, distinguished by the error path the
/// UI takes (inline retry vs deep-link CTA).
public enum KeyEntryError: Sendable, Equatable {
    case invalidKey(message: String)
    case rateLimit(retryAfter: TimeInterval?)
    case network(message: String)
    case server(status: Int, message: String)
    case unexpected(message: String)
}

// MARK: - Launch gate (v0.3.0 F5)

/// The launch-flow decision: re-run onboarding, or go straight to the running
/// state? Modelled as a value so `LaunchGate.decide` is a pure, unit-testable
/// function with no AppKit dependency.
public enum LaunchDecision: Sendable, Equatable {
    /// Enter the running state. `notifyOnlyDegraded` is true when the user is
    /// onboarded but WITHOUT Accessibility (they chose "Skip for now"), so
    /// Inject is unavailable and the app runs notify-only. Informational for
    /// logging — the running state is entered either way.
    case run(notifyOnlyDegraded: Bool)
    /// Re-run onboarding: no API key, or AX is neither granted nor was it
    /// deliberately skipped in a prior run.
    case onboard
}

/// The launch gate. Extracted from `applicationDidFinishLaunching` so the
/// decision is testable without a running app.
///
/// The F5 fix lives here: a user who chose "Skip for now" on Accessibility
/// persisted an ax-skip marker, so `axSkipped == true`. They are fully
/// onboarded and must NOT be dragged back through the whole wizard on every
/// launch. They enter the running state degraded (notify-only) instead.
public enum LaunchGate {
    public static func decide(hasKey: Bool, axGranted: Bool, axSkipped: Bool) -> LaunchDecision {
        // No key → nothing works; always onboard.
        guard hasKey else { return .onboard }
        // AX granted → the full experience (inject available).
        if axGranted { return .run(notifyOnlyDegraded: false) }
        // AX not granted, but the user deliberately skipped it before →
        // honour that choice and run notify-only rather than re-onboarding.
        if axSkipped { return .run(notifyOnlyDegraded: true) }
        // Key present but AX neither granted nor previously skipped → the AX
        // step was never resolved; onboard so the user can grant or skip it.
        return .onboard
    }
}

public extension OnboardingState {
    /// The numeric step (1, 2, 3, or 4) for progress indicators.
    var step: Int {
        switch self {
        case .keyEntry, .keyValidating: return 1
        case .axCheck:                  return 2
        case .notifCheck:               return 3
        case .complete:                 return 4
        }
    }
}
