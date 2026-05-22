// SupervisorApp main entry — Phase B.5.
//
// Lifecycle:
//   1. Boot SupervisorCore: ConfigPaths, TraceLog, PermissionChecker.
//   2. Decide whether onboarding is needed (key missing OR AX missing).
//      - Needed → present OnboardingWindowController; the window owns the
//        view model and signals completion via callback.
//      - Not needed → straight to running state.
//   3. Running state:
//        - Spawn the SupervisorHeartbeat companion as a child process.
//        - Start PermissionMonitor; subscribe to its events.
//        - On axRevoked → show PermissionLostPopover.
//        - On axRegranted → dismiss the popover.
//   4. On `applicationWillTerminate` → terminate the heartbeat child so
//      the status bar transitions to red without lag.
//
// Phase C will add the hover window. Phase B is "main app comes up and
// stays up; status bar goes green; AX revocation triggers the popover."

import AppKit
import Combine
import Foundation
import SupervisorCore
import SupervisorUI

@MainActor
final class SupervisorAppDelegate: NSObject, NSApplicationDelegate {

    private let paths = ConfigPaths()
    private let trace: TraceLog
    private let permissions: any PermissionChecker
    private let keyStore: any APIKeyStore

    private var onboarding: OnboardingWindowController?
    private var permissionMonitor: PermissionMonitor?
    private var permissionPopover: PermissionLostPopover?
    private var permissionCancellable: AnyCancellable?
    private var heartbeatProcess: Process?

    override init() {
        try? paths.ensureDirectoriesExist()
        self.trace = TraceLog(path: paths.traceLogPath)
        self.permissions = LivePermissionChecker()
        self.keyStore = KeychainAPIKeyStore()
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace.emit("app", "applicationDidFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")

        // Determine entry point.
        let hasKey: Bool = ((try? keyStore.read()) ?? nil) != nil
        let axOK = permissions.isAXGranted()

        if !hasKey || !axOK {
            trace.emit("app", "onboarding needed (hasKey=\(hasKey) axOK=\(axOK))")
            presentOnboarding()
        } else {
            trace.emit("app", "onboarding skipped; entering running state")
            enterRunningState(notifDegraded: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trace.emit("app", "applicationWillTerminate; tearing down")
        stopHeartbeat()
        permissionMonitor?.stop()
        trace.sync()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Hot-probe permissions so a user touching System Settings is
        // reflected immediately when they come back to Supervisor.
        Task { await permissionMonitor?.probeNow() }
    }

    // MARK: - Onboarding

    private func presentOnboarding() {
        // Force activation policy to .regular while onboarding is up so the
        // window can become key & accept input. We drop back to .accessory
        // once onboarding completes (no dock icon, menu-bar-app shape).
        NSApp.setActivationPolicy(.regular)

        let vm = OnboardingViewModel(
            permissions: permissions,
            keyStore: keyStore,
            clientFactory: { [trace] key in
                AnthropicClient(
                    apiKey: key,
                    redactor: DefaultRedactor(),
                    traceLog: trace
                )
            },
            trace: trace
        )
        let controller = OnboardingWindowController(vm: vm) { [weak self] notifDegraded in
            self?.onboardingCompleted(notifDegraded: notifDegraded)
        }
        self.onboarding = controller
        controller.present()
    }

    private func onboardingCompleted(notifDegraded: Bool) {
        trace.emit("app", "onboarding complete notifDegraded=\(notifDegraded)")
        onboarding?.dismiss()
        onboarding = nil
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        enterRunningState(notifDegraded: notifDegraded)
    }

    // MARK: - Running state

    private func enterRunningState(notifDegraded: Bool) {
        startHeartbeat()
        startPermissionMonitor()

        if notifDegraded {
            trace.emit("app", "running with notif degradation (banners suppressed)")
            // Phase C will surface this in the hover window. For Phase B
            // it's only in the trace log.
        }
    }

    // MARK: - Heartbeat child

    private func startHeartbeat() {
        stopHeartbeat()

        guard let url = locateHeartbeatExecutable() else {
            trace.emit("app", "ERROR cannot locate SupervisorHeartbeat executable")
            return
        }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = []
        do {
            try proc.run()
            heartbeatProcess = proc
            trace.emit("app", "spawned heartbeat pid=\(proc.processIdentifier) path=\(url.path)")
        } catch {
            trace.emit("app", "ERROR failed to spawn heartbeat: \(error)")
        }
    }

    private func stopHeartbeat() {
        guard let proc = heartbeatProcess, proc.isRunning else { return }
        trace.emit("app", "terminating heartbeat pid=\(proc.processIdentifier)")
        proc.terminate()
        heartbeatProcess = nil
    }

    /// Search candidates in bundle Resources, alongside the main executable,
    /// and in the SwiftPM .build tree. Whichever exists wins.
    private func locateHeartbeatExecutable() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("SupervisorHeartbeat"))
        }
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent().appendingPathComponent("SupervisorHeartbeat"))
        }
        // Dev-build fallback. Walk up from the running executable looking
        // for a sibling SupervisorHeartbeat binary in the SwiftPM layout.
        if let exec = Bundle.main.executableURL {
            let buildDir = exec.deletingLastPathComponent()
            candidates.append(buildDir.appendingPathComponent("SupervisorHeartbeat"))
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Permission monitor

    private func startPermissionMonitor() {
        let monitor = PermissionMonitor(checker: permissions, trace: trace)
        self.permissionMonitor = monitor
        self.permissionPopover = PermissionLostPopover()
        permissionCancellable = monitor.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePermissionEvent(event)
            }
        monitor.start()
    }

    private func handlePermissionEvent(_ event: PermissionEvent) {
        switch event {
        case .axRevoked:
            trace.emit("app", "AX revoked — presenting popover")
            permissionPopover?.present(reason: .accessibilityRevoked)
        case .axRegranted:
            trace.emit("app", "AX regranted — dismissing popover")
            permissionPopover?.dismiss()
        case .notificationsRevoked:
            trace.emit("app", "notifications revoked — presenting popover")
            permissionPopover?.present(reason: .notificationsRevoked)
        case .notificationsRegranted:
            trace.emit("app", "notifications regranted — dismissing popover")
            permissionPopover?.dismiss()
        }
    }
}

// MARK: - Bootstrap
//
// Top-level main.swift runs in a nonisolated context, but the delegate is
// @MainActor-isolated. Bootstrap is single-threaded on the main thread,
// so `MainActor.assumeIsolated` is the correct bridge.

MainActor.assumeIsolated {
    let delegate = SupervisorAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    // Start as .accessory; onboarding flips to .regular while needed.
    app.setActivationPolicy(.accessory)
    app.run()
}
