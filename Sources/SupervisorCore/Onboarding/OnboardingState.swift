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
