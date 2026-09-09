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

    /// Set true once Screen Recording has been granted during onboarding. macOS
    /// requires the app to be QUIT AND RELAUNCHED before a freshly-granted Screen
    /// Recording permission actually takes effect for capture — until then the
    /// grant reads as "on" in System Settings but `CGDisplayStream`/screenshots
    /// still fail. The UI surfaces a "Quit & relaunch Supervisor" affordance off
    /// this so the user is not left with a granted-but-not-effective permission
    /// (RC fix #6). Latches true; a relaunch clears it (a fresh process starts
    /// with this false).
    @Published public private(set) var screenRecordingNeedsRelaunch: Bool = false

    /// First run, or a returning user whose grant macOS dropped on upgrade.
    /// The UI branches its copy on this; the state machine branches its route.
    public let flow: OnboardingFlow

    /// On a `.regrant`, the system permissions that were actually missing when
    /// the window opened, in presentation order. Empty on a first run. This is
    /// what makes the short path short: a permission that is already granted
    /// never becomes a step, so it can neither be shown nor (in the case of
    /// Screen Recording) trigger a spurious "quit and relaunch" prompt.
    public let regrantPlan: [OnboardingPermissionStep]

    /// Position in the running flow, for the step indicator.
    public var progress: OnboardingProgress {
        switch flow {
        case .firstRun:
            return OnboardingProgress(index: state.step, total: 5)
        case .regrant:
            let total = max(regrantPlan.count, 1)
            let index: Int
            switch state {
            case .axCheck:
                index = (regrantPlan.firstIndex(of: .accessibility) ?? 0) + 1
            case .screenRecordingCheck:
                index = (regrantPlan.firstIndex(of: .screenRecording) ?? total - 1) + 1
            default:
                index = total
            }
            return OnboardingProgress(index: min(index, total), total: total)
        }
    }

    // MARK: - Dependencies

    private let permissions: any PermissionChecker
    private let keyStore: any ProviderKeyStore
    private let activeProviderStore: any ActiveProviderStore
    private let clientFactory: @Sendable (LLMProvider, String) -> LLMClient
    private let trace: TraceLog

    // MARK: - Init

    /// Construct a view model that resumes at the right step based on what
    /// state is already on disk. A key already in Keychain for the active
    /// provider means we skip step 1; AX already granted means we skip
    /// step 2; both means we go straight to step 3 (or to .complete if
    /// notifications are good too).
    /// - Parameter priorInstall: the record a previously completed onboarding
    ///   left behind, or nil on a machine that has never finished one. When it
    ///   is present AND a key is already stored, this is an upgrade that lost a
    ///   permission, not a first run, and the flow shrinks to the permissions
    ///   that are actually missing. Defaults to nil so every existing caller
    ///   and test keeps the full first-run behavior.
    public init(
        permissions: any PermissionChecker,
        keyStore: any ProviderKeyStore,
        activeProviderStore: any ActiveProviderStore,
        clientFactory: @escaping @Sendable (LLMProvider, String) -> LLMClient,
        priorInstall: OnboardingRecord? = nil,
        trace: TraceLog = .shared
    ) {
        self.permissions = permissions
        self.keyStore = keyStore
        self.activeProviderStore = activeProviderStore
        self.clientFactory = clientFactory
        self.trace = trace

        // Pick the resume provider: whatever's marked active, falling back
        // to .anthropic for a clean install.
        let resumeProvider = (try? activeProviderStore.read()) ?? .anthropic
        self.selectedProvider = resumeProvider

        // Resume point: lets a user who already onboarded skip past steps.
        // "Has key" means: a key exists for the resume provider.
        let hasKey = (try? keyStore.read(resumeProvider))?.isEmpty == false
        let axOK = permissions.isAXGranted()

        // A stored key AND a record of a completed onboarding is the upgrade
        // signature: the Keychain item survives a signing-identity change,
        // the TCC grant does not. Anything else is a first run, including a
        // returning user who deleted their key (they have to enter one, so
        // they get the full flow).
        if let prior = priorInstall, hasKey {
            self.flow = .regrant(previousVersion: prior.completedVersion)
            var plan: [OnboardingPermissionStep] = []
            if !axOK { plan.append(.accessibility) }
            // Reached when Screen Recording is the only thing that went: the
            // launch gate opens the window for a user who had the grant and
            // lost it, and the plan then holds this step alone.
            if !permissions.isScreenRecordingGranted() { plan.append(.screenRecording) }
            self.regrantPlan = plan
            switch plan.first {
            case .accessibility:
                self.state = .axCheck()
            case .screenRecording:
                self.state = .screenRecordingCheck()
            case .none:
                // Nothing is missing. Unreachable from the app, because
                // `OnboardingLaunchGate` opens this window only when the key,
                // Accessibility, or a previously-granted Screen Recording is
                // absent, and each of those puts a step in the plan. Kept
                // total anyway, and deliberately NOT `.complete`: the window
                // controller's Combine sink fires on subscribe, so completing
                // during init would call back before the controller is
                // assigned. Fall through to the normal axCheck resume and let
                // the tick advance.
                self.state = .axCheck()
            }
        } else {
            self.flow = .firstRun
            self.regrantPlan = []
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
        }
        trace.emit("onboarding", "viewmodel init state=\(state) provider=\(resumeProvider.rawValue) flow=\(flow) plan=\(regrantPlan)")
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

    // MARK: - Routing

    /// Where the flow goes once Accessibility is satisfied.
    ///
    /// First run: on to Screen Recording, then notifications, then the
    /// customization explainer. A re-grant skips straight past everything the
    /// user has already been shown and already granted: if Screen Recording
    /// was not in the plan it is already granted, so there is nothing left to
    /// ask for and onboarding is done.
    private func stateAfterAX() -> OnboardingState {
        guard flow.isRegrant else { return .screenRecordingCheck() }
        return regrantPlan.contains(.screenRecording)
            ? .screenRecordingCheck()
            : .complete(notifDegraded: false)
    }

    /// Where the flow goes once Screen Recording is satisfied. A re-grant ends
    /// here: notification authorization is stored per bundle id and is not
    /// affected by the signing-identity change that dropped the TCC grants,
    /// and the customization explainer is information the user already has.
    private func stateAfterScreenRecording() async -> OnboardingState {
        guard flow.isRegrant else {
            return .notifCheck(status: await permissions.notificationStatus())
        }
        return .complete(notifDegraded: false)
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

    /// Re-probe AX. If granted, advance to the screen-recording step.
    public func recheckAX() async {
        guard case .axCheck = state else { return }
        if permissions.isAXGranted() {
            let next = stateAfterAX()
            trace.emit("onboarding", "AX granted; advancing to \(next)")
            state = next
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
        let next = stateAfterAX()
        trace.emit("onboarding", "AX confirmed by user (macOS reported granted=\(detected)); advancing to \(next)")
        state = next
    }

    /// User clicked "Skip for now" on the AX step. Matches the §6.6
    /// proceed-with-degradation philosophy (same shape as the Notifications
    /// step's denied → continue-anyway path). v0.1.0 has no Inject
    /// intervention so AX isn't actually used at runtime; for v0.1.1+ a
    /// PermissionMonitor event will re-surface the popover when the user
    /// triggers an action that needs AX.
    public func skipAX() async {
        guard case .axCheck = state else { return }
        let next = stateAfterAX()
        trace.emit("onboarding", "AX skipped by user; advancing to \(next)")
        state = next
    }

    // MARK: - Screen Recording step

    /// Prompt for Screen Recording (triggers the macOS request on first call)
    /// and mark the step as prompted. Called by the screen-recording step's
    /// "Open System Settings" CTA. Mirrors `promptForAX`: it fires the request
    /// once per onboarding session so Supervisor appears in the Screen
    /// Recording list for the user to enable.
    public func promptForScreenRecording() {
        guard case .screenRecordingCheck(let prompted) = state else { return }
        if !prompted {
            _ = permissions.requestScreenRecording()
            trace.emit("onboarding", "screen recording request fired")
            state = .screenRecordingCheck(prompted: true)
        }
    }

    /// Re-probe Screen Recording. If granted, advance to the notification
    /// step. Mirrors `recheckAX`; called by the periodic tick so an
    /// out-of-band grant in System Settings advances the flow.
    public func recheckScreenRecording() async {
        guard case .screenRecordingCheck = state else { return }
        if permissions.isScreenRecordingGranted() {
            // Granted-but-not-effective until relaunch (RC fix #6): latch the
            // relaunch-needed flag so the UI can prompt a quit & relaunch.
            screenRecordingNeedsRelaunch = true
            let next = await stateAfterScreenRecording()
            trace.emit("onboarding", "screen recording granted; advancing to \(next); relaunch required for capture")
            state = next
        }
    }

    /// User clicked the active "Continue" button on the screen-recording step
    /// after being sent to System Settings. The affirmative "I enabled it"
    /// path, mirroring `confirmAX`: the 1.5s poll already auto-advances when
    /// macOS reports the grant, but for self built apps macOS can fail to
    /// report it back, so Continue advances either way and trusts the user.
    /// The runtime re-checks Screen Recording when a desktop inject actually
    /// needs it, so nothing is lost if the grant resolves later.
    public func confirmScreenRecording() async {
        guard case .screenRecordingCheck = state else { return }
        let detected = permissions.isScreenRecordingGranted()
        // If macOS reports the grant, capture still needs a relaunch to take
        // effect (RC fix #6): latch the relaunch-needed flag so the UI prompts a
        // quit & relaunch. When NOT detected we can't assert the grant, so we
        // don't claim a relaunch is needed — Continue still advances, trusting
        // the user, and the runtime re-checks when a desktop inject needs it.
        if detected { screenRecordingNeedsRelaunch = true }
        let next = await stateAfterScreenRecording()
        trace.emit("onboarding", "screen recording confirmed by user (macOS reported granted=\(detected)); advancing to \(next); relaunchNeeded=\(screenRecordingNeedsRelaunch)")
        state = next
    }

    /// User clicked "Skip for now" on the screen-recording step. Same
    /// proceed-with-degradation shape as `skipAX`: desktop driving and
    /// answering degrade to a notify without it, but the user can proceed and
    /// is told. Advances to the notification step.
    public func skipScreenRecording() async {
        guard case .screenRecordingCheck = state else { return }
        let next = await stateAfterScreenRecording()
        trace.emit("onboarding", "screen recording skipped by user; advancing to \(next)")
        state = next
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
    /// `denied` carries the degradation flag forward to the customization
    /// step (and ultimately to `.complete`).
    public func finishNotificationStep() {
        guard case .notifCheck(let status) = state else { return }
        let degraded: Bool = (status == .denied)
        trace.emit("onboarding", "notif step done notifDegraded=\(degraded) status=\(status); advancing to customization")
        state = .customization(notifDegraded: degraded)
    }

    /// User clicked Done on the customization explanation step. Advances
    /// to `.complete`, preserving the notification-degradation flag.
    public func finishCustomizationStep() {
        guard case .customization(let degraded) = state else { return }
        trace.emit("onboarding", "complete notifDegraded=\(degraded)")
        state = .complete(notifDegraded: degraded)
    }

    /// Periodic refresh while window is up. Called every ~2s by the view's
    /// timer. Advances state if the user granted AX out-of-band in System
    /// Settings (which they always do — macOS has no in-app AX grant).
    public func tick() async {
        switch state {
        case .axCheck:
            await recheckAX()
        case .screenRecordingCheck:
            await recheckScreenRecording()
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
