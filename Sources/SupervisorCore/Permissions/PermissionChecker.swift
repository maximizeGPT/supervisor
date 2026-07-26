// PermissionChecker.swift
//
// Three macOS permission surfaces Supervisor cares about:
//   - Accessibility (AX)   — required for Inject in v0.1.x.
//   - Notifications        — required for Notify.
//   - Screen Recording     — optional, only used by the v0.2 screen-capture
//                            fallback observation channel.
//
// All three are probed through a protocol so tests can inject a stub.
// `LivePermissionChecker` is the production implementation. The deep-link
// URLs to System Settings are static; the protocol exposes them so tests
// can assert exact strings without invoking AppKit.
//
// Spike-2 reminder enforced here: getNotificationSettings returns one of
// notDetermined / denied / authorized / provisional / ephemeral. Each gets
// a distinct branch in onboarding. The mapping lives in
// `NotificationAuthStatus`.

import Foundation
import AppKit
import ApplicationServices
import UserNotifications
import CoreGraphics

// MARK: - State

public enum NotificationAuthStatus: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

public struct PermissionSnapshot: Sendable, Equatable {
    public let ax: Bool
    public let notifications: NotificationAuthStatus
    public let screenRecording: Bool

    public init(ax: Bool, notifications: NotificationAuthStatus, screenRecording: Bool) {
        self.ax = ax
        self.notifications = notifications
        self.screenRecording = screenRecording
    }

    /// True when both required surfaces (AX + Notifications) are satisfied
    /// enough to leave onboarding. Screen Recording is optional.
    public var clearedForOnboardingExit: Bool {
        // AX must be granted. Notifications must be authorized OR provisional
        // OR ephemeral (these all permit center.add to succeed). `denied` is
        // still acceptable — we surface the degradation banner and proceed,
        // because the user may have intentionally blocked banners but still
        // wants Supervisor running (per Spike 2 finding: center.add succeeds
        // even when banners are denied; notifications still land in
        // Notification Center).
        return ax
    }
}

// MARK: - Protocol

public protocol PermissionChecker: AnyObject, Sendable {

    /// Current AX state. Does not prompt.
    func isAXGranted() -> Bool

    /// Current notification authorization. Does not prompt.
    func notificationStatus() async -> NotificationAuthStatus

    /// Current Screen Recording state. Does not prompt.
    func isScreenRecordingGranted() -> Bool

    /// Prompt the user for Screen Recording permission. Like AX, macOS routes
    /// the user to System Settings; there is no in-app grant. Returns the
    /// resulting state (typically still false on first call, until the user
    /// enables it and Supervisor polls again). The screen-recording analogue
    /// of `requestAX`.
    func requestScreenRecording() -> Bool

    /// Prompt the user for AX permission. macOS routes them to System
    /// Settings — there is no in-app permission grant for AX. Returns
    /// the resulting state (likely still false until they actually grant
    /// and Supervisor polls again).
    func requestAX(prompt: Bool) -> Bool

    /// Request notification authorization. Returns granted bool from the
    /// system. If the underlying ad-hoc-signing state is bad (Spike 2's
    /// Code=1 case), this throws AnthropicClient-style "notSupported"-ish
    /// errors — caller handles by deep-linking to System Settings.
    func requestNotifications() async throws -> Bool

    /// Snapshot all three at once. Cheap; safe to call from a polling timer.
    func snapshot() async -> PermissionSnapshot
}

// MARK: - Deep links

/// System Settings deep links. macOS sometimes changes these between major
/// versions; v0.1.0 targets macOS 13+, where these strings are stable.
public enum PermissionSettingsURL {

    public static let accessibility: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    public static let notifications: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications"
    )!

    public static let screenRecording: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
}

// MARK: - Live implementation

public final class LivePermissionChecker: PermissionChecker, @unchecked Sendable {

    public init() {}

    public func isAXGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public func notificationStatus() async -> NotificationAuthStatus {
        // NotificationCenterGate: current() abort()s in a process with no
        // bundle identifier; report .denied instead of crashing the caller.
        guard NotificationCenterGate.available else { return .denied }
        return await withCheckedContinuation { (cont: CheckedContinuation<NotificationAuthStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: NotificationAuthStatus(settings.authorizationStatus))
            }
        }
    }

    public func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func requestAX(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func requestNotifications() async throws -> Bool {
        guard NotificationCenterGate.available else { return false }
        return try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            ax: isAXGranted(),
            notifications: await notificationStatus(),
            screenRecording: isScreenRecordingGranted()
        )
    }
}

// MARK: - Mapping helper

extension NotificationAuthStatus {
    init(_ raw: UNAuthorizationStatus) {
        switch raw {
        case .notDetermined: self = .notDetermined
        case .denied:        self = .denied
        case .authorized:    self = .authorized
        case .provisional:   self = .provisional
        // .ephemeral is iOS-only (App Clips); macOS SDK marks it
        // @available(macOS, unavailable). Falls into the default arm.
        @unknown default:    self = .denied
        }
    }
}
