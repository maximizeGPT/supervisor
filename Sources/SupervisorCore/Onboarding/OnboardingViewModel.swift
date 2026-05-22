// OnboardingViewModel.swift
//
// Drives the three-step onboarding state machine. Lives in Core so it can
// be exhaustively unit-tested without an AppKit/SwiftUI runtime.
//
// Dependencies (all protocols / closures so tests inject stubs):
//   - PermissionChecker  : probes AX / Notification / Screen Recording
//   - APIKeyStore        : Keychain or in-memory
//   - clientFactory      : (String) -> AnthropicClient — lets tests inject
//                          a client wired to a MockURLProtocol
//
// The view model is an ObservableObject (Combine) so SwiftUI can bind to
// `state`. Core imports Combine — never SwiftUI.
//
// Loud rule, enforced by the public surface: there is no `setState`
// method. Every state transition flows through a named intent
// (`submitKey`, `advancePastAX`, `recheckNotifications`, etc.), so the
// transition graph is explicit and reviewable.

import Combine
import Foundation

@MainActor
public final class OnboardingViewModel: ObservableObject {

    // MARK: - Observable surface

    @Published public private(set) var state: OnboardingState

    // MARK: - Dependencies

    private let permissions: any PermissionChecker
    private let keyStore: any APIKeyStore
    private let clientFactory: @Sendable (String) -> AnthropicClient
    private let trace: TraceLog

    // MARK: - Init

    /// Construct a view model that resumes at the right step based on what
    /// state is already on disk. A key already in Keychain means we skip
    /// step 1; AX already granted means we skip step 2; both means we go
    /// straight to step 3 (or to .complete if notifications are good too).
    public init(
        permissions: any PermissionChecker,
        keyStore: any APIKeyStore,
        clientFactory: @escaping @Sendable (String) -> AnthropicClient,
        trace: TraceLog = .shared
    ) {
        self.permissions = permissions
        self.keyStore = keyStore
        self.clientFactory = clientFactory
        self.trace = trace

        // Resume point: lets a user who already onboarded skip past steps.
        let hasKey = (try? keyStore.read()) ?? nil != nil
        let axOK = permissions.isAXGranted()
        switch (hasKey, axOK) {
        case (false, _):
            self.state = .keyEntry()
        case (true, false):
            self.state = .axCheck()
        case (true, true):
            // Notifications status is async; start in axCheck and refresh.
            // The view will call `recheckPermissions()` on appear, which
            // moves us forward correctly without making init async.
            self.state = .axCheck()
        }
        trace.emit("onboarding", "viewmodel init state=\(state)")
    }

    // MARK: - Intents

    /// Validate the key against Anthropic, save on success, surface a
    /// typed inline error on failure. Allows retry without leaving step 1.
    public func submitKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            state = .keyEntry(error: .invalidKey(message: "Key field is empty."))
            return
        }
        state = .keyValidating
        trace.emit("onboarding", "submitKey len=\(key.count)")

        let client = clientFactory(key)
        do {
            _ = try await client.validateKey()
            try keyStore.write(key)
            trace.emit("onboarding", "key validated + persisted")
            state = .axCheck()
        } catch let e as AnthropicClientError {
            let mapped = Self.mapClientError(e)
            trace.emit("onboarding", "key validation failed: \(e)")
            state = .keyEntry(error: mapped)
        } catch {
            trace.emit("onboarding", "key validation unexpected: \(error)")
            state = .keyEntry(error: .unexpected(message: "\(error)"))
        }
    }

    /// User dismissed an inline error and is ready to retry the key entry.
    /// Returns the view to the key-entry state with no error so the field
    /// stays editable.
    public func clearKeyError() {
        if case .keyEntry = state {
            state = .keyEntry(error: nil)
        }
    }

    /// Prompt for AX (triggers the macOS sheet on first call) and re-poll
    /// permission state. Called by the AX-step "Open System Settings" CTA
    /// and by a periodic refresh in the SwiftUI view.
    public func promptForAX() {
        guard case .axCheck(let prompted) = state else { return }
        if !prompted {
            _ = permissions.requestAX(prompt: true)
            trace.emit("onboarding", "AX prompt requested")
            state = .axCheck(prompted: true)
        }
    }

    /// Re-probe AX. If granted, advance to notification step.
    public func recheckAX() async {
        guard case .axCheck = state else { return }
        if permissions.isAXGranted() {
            let status = await permissions.notificationStatus()
            trace.emit("onboarding", "AX granted; advancing to notif step (notif=\(status))")
            state = .notifCheck(status: status)
        }
    }

    /// User clicked "Skip for now" on the AX step. Matches the §6.6
    /// proceed-with-degradation philosophy (same shape as the Notifications
    /// step's denied → continue-anyway path). v0.1.0 has no Inject
    /// intervention so AX isn't actually used at runtime; for v0.1.1+ a
    /// PermissionMonitor event will re-surface the popover when the user
    /// triggers an action that needs AX.
    public func skipAX() async {
        guard case .axCheck = state else { return }
        let status = await permissions.notificationStatus()
        trace.emit("onboarding", "AX skipped by user; advancing to notif step (notif=\(status))")
        state = .notifCheck(status: status)
    }

    /// Ask macOS to prompt the user for notifications. On success, re-poll
    /// status and refresh state. Handles the Spike-2 "Code=1" error path
    /// by treating it as denied and advancing — the user can still see
    /// notifications in Notification Center even with banners suppressed,
    /// and the degradation banner explains that.
    public func requestNotifications() async {
        guard case .notifCheck = state else { return }
        do {
            _ = try await permissions.requestNotifications()
        } catch {
            trace.emit("onboarding", "requestNotifications threw: \(error) (treating as denied)")
        }
        let after = await permissions.notificationStatus()
        trace.emit("onboarding", "notif status after request: \(after)")
        state = .notifCheck(status: after)
    }

    /// User clicked Continue on the notification step. Lock in whatever
    /// state they're in — `authorized` / `provisional` proceed cleanly,
    /// `denied` proceeds with the degradation banner flag set.
    public func finishNotificationStep() {
        guard case .notifCheck(let status) = state else { return }
        let degraded: Bool = (status == .denied)
        trace.emit("onboarding", "complete notifDegraded=\(degraded) status=\(status)")
        state = .complete(notifDegraded: degraded)
    }

    /// Periodic refresh while window is up. Called every ~2s by the view's
    /// timer. Advances state if the user granted AX out-of-band in System
    /// Settings (which they always do — macOS has no in-app AX grant).
    public func tick() async {
        switch state {
        case .axCheck:
            await recheckAX()
        case .notifCheck:
            let after = await permissions.notificationStatus()
            if case .notifCheck(let prev) = state, prev != after {
                state = .notifCheck(status: after)
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private static func mapClientError(_ e: AnthropicClientError) -> KeyEntryError {
        switch e {
        case .invalidKey(let m):           return .invalidKey(message: m)
        case .permissionDenied(let m):     return .invalidKey(message: "key lacks access: \(m)")
        case .rateLimit(_, let r):         return .rateLimit(retryAfter: r)
        case .network(let m):              return .network(message: m)
        case .serverError(let s, let m):   return .server(status: s, message: m)
        case .requestError(let s, let m):  return .server(status: s, message: m)
        case .decodingFailed(let r):       return .unexpected(message: "decode: \(r)")
        case .redactorMissing:             return .unexpected(message: "internal: redactor missing")
        }
    }
}
