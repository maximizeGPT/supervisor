// OnboardingViewModel.swift
//
// Drives the three-step onboarding state machine. Lives in Core so it can
// be exhaustively unit-tested without an AppKit/SwiftUI runtime.
//
// Dependencies (all protocols / closures so tests inject stubs):
//   - PermissionChecker     : probes AX / Notification / Screen Recording
//   - ProviderKeyStore      : per-provider Keychain (v0.2.0+)
//   - ActiveProviderStore   : records which provider is currently active
//   - clientFactory         : (LLMProvider, String) -> LLMClient — lets
//                             tests inject a client wired to a
//                             MockURLProtocol; production builds wrap
//                             the real LLMClient.
//
// The view model is an ObservableObject (Combine) so SwiftUI can bind to
// `state`. Core imports Combine — never SwiftUI.
//
// Loud rule, enforced by the public surface: there is no `setState`
// method. Every state transition flows through a named intent
// (`submitKey`, `advancePastAX`, `recheckNotifications`, etc.), so the
// transition graph is explicit and reviewable.
//
// v0.2.0: the view model gained a `selectedProvider` field. The
// key-entry step's submitKey takes the currently-selected provider; on
// success we also write it to the ActiveProviderStore so the triage
// engine knows which provider to call.

import Combine
import Foundation

@MainActor
public final class OnboardingViewModel: ObservableObject {

    // MARK: - Observable surface

    @Published public private(set) var state: OnboardingState

    /// Which provider's key the user is currently entering. SwiftUI binds
    /// to this for the picker in KeyEntryStep. Defaults to `.anthropic`
    /// to preserve the v0.1.x experience for users on their first run
    /// after upgrading.
    @Published public var selectedProvider: LLMProvider = .anthropic

    // MARK: - Dependencies

    private let permissions: any PermissionChecker
    private let keyStore: any ProviderKeyStore
    private let activeProviderStore: any ActiveProviderStore
    private let clientFactory: @Sendable (LLMProvider, String) -> LLMClient
    private let trace: TraceLog

    /// v0.3.0 (F5): where the "user skipped AX" marker is persisted. Defaults
    /// to the real ConfigPaths location; tests inject a temp URL so a run
    /// never drops a real marker the deployed app would read.
    private let axSkippedMarkerURL: URL

    // MARK: - Init

    /// Construct a view model that resumes at the right step based on what
    /// state is already on disk. A key already in Keychain for the active
    /// provider means we skip step 1; AX already granted means we skip
    /// step 2; both means we go straight to step 3 (or to .complete if
    /// notifications are good too).
    public init(
        permissions: any PermissionChecker,
        keyStore: any ProviderKeyStore,
        activeProviderStore: any ActiveProviderStore,
        clientFactory: @escaping @Sendable (LLMProvider, String) -> LLMClient,
        axSkippedMarkerURL: URL = ConfigPaths().axSkippedMarkerPath,
        trace: TraceLog = .shared
    ) {
        self.permissions = permissions
        self.keyStore = keyStore
        self.activeProviderStore = activeProviderStore
        self.clientFactory = clientFactory
        self.axSkippedMarkerURL = axSkippedMarkerURL
        self.trace = trace

        // Pick the resume provider: whatever's marked active, falling back
        // to .anthropic for a clean install.
        let resumeProvider = (try? activeProviderStore.read()) ?? .anthropic
        self.selectedProvider = resumeProvider

        // Resume point: lets a user who already onboarded skip past steps.
        // "Has key" means: a key exists for the resume provider.
        let hasKey = (try? keyStore.read(resumeProvider))?.isEmpty == false
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
        trace.emit("onboarding", "viewmodel init state=\(state) provider=\(resumeProvider.rawValue)")
    }

    // MARK: - Intents

    /// Validate the key against the currently-selected provider, save on
    /// success, surface a typed inline error on failure. Allows retry
    /// without leaving step 1. On success also records the selected
    /// provider as active so the triage engine picks it up.
    public func submitKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            state = .keyEntry(error: .invalidKey(message: "Key field is empty."))
            return
        }
        state = .keyValidating
        let provider = selectedProvider
        trace.emit("onboarding", "submitKey provider=\(provider.rawValue) len=\(key.count)")

        let client = clientFactory(provider, key)
        do {
            _ = try await client.validateKey()
            try keyStore.write(key, for: provider)
            try activeProviderStore.write(provider)
            trace.emit("onboarding", "key validated + persisted provider=\(provider.rawValue)")
            state = .axCheck()
        } catch let e as AnthropicClientError {
            let mapped = Self.mapClientError(e)
            trace.emit("onboarding", "key validation failed provider=\(provider.rawValue): \(e)")
            state = .keyEntry(error: mapped)
        } catch {
            trace.emit("onboarding", "key validation unexpected provider=\(provider.rawValue): \(error)")
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
            // AX is now really on — clear any stale skip marker so a later
            // revoke re-onboards rather than silently running notify-only.
            clearAXSkip()
            let status = await permissions.notificationStatus()
            trace.emit("onboarding", "AX granted; advancing to notif step (notif=\(status))")
            state = .notifCheck(status: status)
        }
    }

    /// User clicked the active "Continue" button on the AX step after
    /// being sent to System Settings. This is the affirmative
    /// "I enabled it" path. The 1.5s poll already auto-advances when
    /// macOS reports the grant, so on the clean path the user never
    /// needs this. It exists for the case the user reported: the grant
    /// is enabled in System Settings but macOS does not report it back
    /// to this process (the known ad-hoc-signed-app pattern, where a
    /// binary swap leaves a stale Accessibility entry bound to the old
    /// signature). In that case the poll never fires, and without this
    /// button the only way forward is "Skip" — which wrongly frames a
    /// granted permission as skipped. Continue advances the flow and
    /// trusts the user's grant. The runtime PermissionMonitor re-checks
    /// AX when an inject actually needs it, so nothing is lost if the
    /// grant resolves later.
    public func confirmAX() async {
        guard case .axCheck = state else { return }
        let detected = permissions.isAXGranted()
        // The user asserts AX is enabled — treat this as a grant, not a skip.
        // Clear any stale skip marker so the app runs (and re-onboards on a
        // real future revoke) rather than latching notify-only forever.
        clearAXSkip()
        let status = await permissions.notificationStatus()
        trace.emit("onboarding", "AX confirmed by user (macOS reported granted=\(detected)); advancing to notif step (notif=\(status))")
        state = .notifCheck(status: status)
    }

    /// User clicked "Skip for now" on the AX step. Matches the §6.6
    /// proceed-with-degradation philosophy (same shape as the Notifications
    /// step's denied → continue-anyway path). v0.1.0 has no Inject
    /// intervention so AX isn't actually used at runtime; for v0.1.1+ a
    /// PermissionMonitor event will re-surface the popover when the user
    /// triggers an action that needs AX.
    public func skipAX() async {
        guard case .axCheck = state else { return }
        // F5: persist the deliberate skip so the launch gate treats this
        // notify-only setup as onboarded and never re-runs the full wizard.
        persistAXSkip()
        let status = await permissions.notificationStatus()
        trace.emit("onboarding", "AX skipped by user (persisted); advancing to notif step (notif=\(status))")
        state = .notifCheck(status: status)
    }

    /// Write the ax-skip marker (empty file — presence is the signal).
    /// Best-effort: a failed write only costs a re-shown wizard next launch.
    private func persistAXSkip() {
        let url = axSkippedMarkerURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
            trace.emit("onboarding", "persisted ax-skipped marker at \(url.path)")
        } catch {
            trace.emit("onboarding", "ERROR persist ax-skip marker: \(error)")
        }
    }

    /// Remove the ax-skip marker once AX is actually granted, so the marker's
    /// meaning stays precise ("the user's last AX decision was to skip").
    private func clearAXSkip() {
        guard FileManager.default.fileExists(atPath: axSkippedMarkerURL.path) else { return }
        try? FileManager.default.removeItem(at: axSkippedMarkerURL)
        trace.emit("onboarding", "cleared ax-skipped marker (AX now granted)")
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
