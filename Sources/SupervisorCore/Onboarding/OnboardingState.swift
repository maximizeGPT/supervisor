// OnboardingState.swift
//
// The state machine for the onboarding flow:
//   1. keyEntry            → user enters their Anthropic API key
//   2. axCheck             → user grants Accessibility in System Settings
//   3. screenRecordingCheck → user grants Screen Recording in System Settings
//                            (needed so Supervisor can see which Claude
//                            desktop conversation to drive or answer)
//   4. notifCheck          → user grants Notifications (or proceeds with
//                            `denied`, accepting the degradation banner)
//   complete               → onboarding window dismisses, main app comes up
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

    /// Waiting for the user to grant Screen Recording. `prompted` indicates
    /// whether the macOS "open System Settings?" request has already been
    /// triggered. We only fire it once per onboarding session, the same
    /// shape as axCheck. Screen Recording lets Supervisor screenshot and
    /// read the Claude desktop sidebar on-device so it can target the right
    /// conversation when it drives or answers; without it desktop driving
    /// degrades to a notify.
    case screenRecordingCheck(prompted: Bool = false)

    /// Notifications step. `status` is the most recently observed
    /// authorization status; UI branches on it.
    case notifCheck(status: NotificationAuthStatus)

    /// Customization explanation step: shows where config files live, that
    /// editing them changes Supervisor's behavior, and where exports go.
    /// Added after the notifications step so it is the last informational
    /// step before `.complete`.
    case customization(notifDegraded: Bool)

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
    /// The numeric step (1 through 5) for progress indicators.
    var step: Int {
        switch self {
        case .keyEntry, .keyValidating: return 1
        case .axCheck:                  return 2
        case .screenRecordingCheck:     return 3
        case .notifCheck:               return 4
        case .customization:            return 5
        case .complete:                 return 6
        }
    }
}

// MARK: - First run vs re-grant

/// Why the onboarding window is on screen.
///
/// A first run and an upgrade that lost a permission look identical to the
/// launch check (`hasKey && !axOK`), but they deserve very different flows.
/// The first-run user needs the whole five-step introduction. The returning
/// user has already read all of it; macOS just dropped a grant because the
/// app's signing identity changed underneath them (see docs/upgrading.md).
/// They should be asked for exactly what is missing, and nothing else.
public enum OnboardingFlow: Sendable, Equatable {
    /// No completed onboarding on this machine.
    case firstRun
    /// A previous install completed onboarding. `previousVersion` is what it
    /// recorded, or `OnboardingRecord.unknownVersion` when it was inferred.
    case regrant(previousVersion: String)

    public var isRegrant: Bool {
        if case .regrant = self { return true }
        return false
    }
}

/// A system permission the re-grant flow can ask for. Ordered as presented.
public enum OnboardingPermissionStep: Sendable, Equatable {
    case accessibility
    case screenRecording
}

/// Position in whichever flow is running, for the "Step N of M" indicator.
/// The re-grant flow has its own (much shorter) denominator, so the counter
/// stays honest instead of promising five steps and delivering one.
public struct OnboardingProgress: Sendable, Equatable {
    public let index: Int
    public let total: Int

    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }
}
