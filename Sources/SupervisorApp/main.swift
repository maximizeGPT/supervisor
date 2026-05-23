// SupervisorApp main entry — Phase C lifecycle.
//
// Boots SupervisorCore, runs onboarding if needed, then enters the
// running state:
//
//   - Spawns SupervisorHeartbeat as a child process
//   - Starts PermissionMonitor (AX revoke → popover)
//   - Opens SupervisorDatabase (sessions / flags / cost)
//   - Constructs AnthropicClient with key from Keychain + DefaultRedactor
//   - Constructs HoverViewModel + HoverWindowController
//   - Starts TriageEngine, wires onDecision to FlagStore + Notifier +
//     HoverViewModel.flagRaised
//   - Starts SessionDiscovery on ~/.claude/projects/ — sessions arrive
//     into EventBus, TriageEngine pulls them and flags
//
// On clean exit: teardown is the reverse. Crash-survival of the
// heartbeat companion is Phase C.x — for v0.1.0 a crash of main leaks
// the child until the user kills it manually.

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

    // Onboarding
    private var onboarding: OnboardingWindowController?

    // Running state
    private var hoverVM: HoverViewModel?
    private var hoverWindow: HoverWindowController?
    private var database: SupervisorDatabase?
    private var sessionStore: SessionStore?
    private var flagStore: FlagStore?
    private var costStore: CostStore?
    private var anthropic: AnthropicClient?
    private var triageEngine: TriageEngine?
    private var discovery: SessionDiscovery?
    private var notifier: Notifier?
    private var router: InterventionRouter?
    private var bus: EventBus?

    // Permission monitor
    private var permissionMonitor: PermissionMonitor?
    private var permissionPopover: PermissionLostPopover?
    private var permissionCancellable: AnyCancellable?

    // Heartbeat child
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
        triageEngine?.stop()
        discovery?.stop()
        permissionMonitor?.stop()
        hoverWindow?.dismiss()
        stopHeartbeat()
        trace.sync()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await permissionMonitor?.probeNow() }
    }

    // MARK: - Onboarding

    private func presentOnboarding() {
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
        NSApp.setActivationPolicy(.accessory)
        enterRunningState(notifDegraded: notifDegraded)
    }

    // MARK: - Running state

    private func enterRunningState(notifDegraded: Bool) {
        // 1. Storage
        do {
            let db = try SupervisorDatabase(path: paths.databasePath)
            self.database = db
            self.sessionStore = SessionStore(database: db)
            self.flagStore = FlagStore(database: db)
            self.costStore = CostStore(database: db)
            trace.emit("app", "storage opened at \(paths.databasePath.path)")
        } catch {
            trace.emit("app", "FATAL: storage open failed: \(error)")
            return
        }

        // 2. Bus + Hover
        let bus = EventBus(trace: trace)
        self.bus = bus
        let hoverVM = HoverViewModel(bus: bus, trace: trace)
        self.hoverVM = hoverVM
        let hoverWindow = HoverWindowController(vm: hoverVM)
        self.hoverWindow = hoverWindow
        hoverWindow.present()

        // 3. Anthropic client (key required — should be present post-onboarding)
        guard let key = (try? keyStore.read()) ?? nil else {
            trace.emit("app", "FATAL: no API key after onboarding; aborting")
            return
        }
        let client = AnthropicClient(
            apiKey: key,
            redactor: DefaultRedactor(),
            traceLog: trace
        )
        self.anthropic = client

        // 4. Notifier + Intervention router (v0.1.4 Part A3)
        let notifier = Notifier(trace: trace)
        self.notifier = notifier
        let router = InterventionRouter(
            notifier: notifier,
            locator: LiveProcessLocator(trace: trace),
            signalSender: DarwinSignalSender(),
            trace: trace
        )
        self.router = router

        // 5. Triage engine
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: Config.defaults.triageModel,
            windowSize: 30,
            costStore: costStore,
            redactor: DefaultRedactor(),
            trace: trace
        )
        engine.onActivityChange = { [weak self] activity in
            // No pre-acknowledge: triageFinishedNoFlag already sets idle,
            // and unconditional acknowledgeFlag floods the trace log
            // with "flag acknowledged" on every transition (caught during
            // the Checkpoint C smoke — was producing ~3500 false-trace
            // lines in 20s of light activity).
            switch activity {
            case .triaging:           self?.hoverVM?.triageStarted()
            case .idle:               self?.hoverVM?.triageFinishedNoFlag()
            case .flagged(let sev):   self?.hoverVM?.flagRaised(severity: sev)
            }
        }
        engine.onDecision = { [weak self] decision in
            Task { @MainActor in self?.handle(decision: decision) }
        }
        engine.start()
        self.triageEngine = engine

        // 6. Discovery (kicks off tails for every Claude Code session)
        let discovery = SessionDiscovery(
            claudeProjectsDir: paths.claudeProjectsDir,
            bus: bus,
            sessionStore: sessionStore,
            trace: trace
        )
        discovery.start()
        self.discovery = discovery

        // 7. Companions: heartbeat + permission monitor
        startHeartbeat()
        startPermissionMonitor()

        if notifDegraded {
            trace.emit("app", "running with notification degradation (banner suppressed; flags still appear in Notification Center)")
        }

        // Catch users who skipped onboarding (key + AX already present in
        // Keychain from a previous run) but whose notification permission
        // was never requested. Without this, `getNotificationSettings`
        // stays at .notDetermined forever and flags land silently in
        // Notification Center rather than as banners. Fires once on entry;
        // macOS shows the prompt only the first time per app identity.
        Task { [weak self] in
            guard let self = self else { return }
            let status = await self.permissions.notificationStatus()
            if status == .notDetermined {
                self.trace.emit("app", "notification status notDetermined on running-state entry — requesting once")
                _ = try? await self.permissions.requestNotifications()
                let after = await self.permissions.notificationStatus()
                self.trace.emit("app", "notification status after request: \(after)")
            }
        }

        trace.emit("app", "running state ready — watching \(paths.claudeProjectsDir.path)")
    }

    // MARK: - Flag routing

    private func handle(decision: TriageDecision) {
        // 1. Persist to flags table. v0.1.2: Haiku's recommended_action
        // lands on flag.action; the pause/kill router (deferred) will
        // be the actual executor of pause/kill recommendations. Until
        // that ships, every action — including pause and kill — still
        // surfaces as a notify banner via Notifier.post below. The
        // banner copy makes the difference visible because Haiku writes
        // the recommendation into reasoning_plain.
        let candidate = decision.candidate
        let flag = StoredFlag(
            sessionId: decision.sessionId,
            category: candidate.category,
            severity: candidate.severity,
            action: candidate.action,
            reasoningPlain: candidate.reasoningPlain,
            reasoningTechnical: candidate.reasoningTechnical,
            asymmetryNote: candidate.asymmetryNote,
            evidenceUuids: [decision.triggeringEvent.toolUseId],
            haikuInputTokens: decision.usage.input_tokens,
            haikuOutputTokens: decision.usage.output_tokens
        )
        do {
            try flagStore?.insert(flag)
            trace.emit("flag", "persisted id=\(flag.id) severity=\(flag.severity.rawValue) action=\(flag.action.rawValue) session=\(flag.sessionId)")
        } catch {
            trace.emit("flag", "ERROR persist failed: \(error)")
        }

        // 2. Dispatch via router (v0.1.4: handles notify / pause / kill;
        //    inject queued, routed to notify for now). Router internally
        //    handles every locator + signal failure by degrading to a
        //    notify banner — never crashes on a bad PID or revoked perm.
        Task { [weak self] in
            await self?.router?.dispatch(decision: decision)
        }

        // 3. Hover view already updated by engine.onActivityChange.
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

    private func locateHeartbeatExecutable() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("SupervisorHeartbeat"))
        }
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent().appendingPathComponent("SupervisorHeartbeat"))
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

MainActor.assumeIsolated {
    let delegate = SupervisorAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
