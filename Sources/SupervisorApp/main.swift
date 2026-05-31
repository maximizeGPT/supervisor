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
    private let keyStore: any ProviderKeyStore
    private let activeProviderStore: any ActiveProviderStore

    // Onboarding
    private var onboarding: OnboardingWindowController?

    // Running state
    private var hoverVM: HoverViewModel?
    private var hoverWindow: HoverWindowController?
    private var database: SupervisorDatabase?
    private var sessionStore: SessionStore?
    private var flagStore: FlagStore?
    private var costStore: CostStore?
    private var loopDispatchStore: LoopDispatchStore?
    private var loopController: LoopController?
    private var configWatcher: ConfigWatcher?
    private var llm: LLMClient?
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
        self.keyStore = KeychainProviderKeyStore()
        self.activeProviderStore = FileActiveProviderStore(path: paths.activeProviderPath)
        super.init()
        // v0.2.0: one-shot migration of the v0.1.x single-key Keychain
        // item into the per-provider layout. Idempotent — every launch
        // after the first is a no-op.
        migrateLegacyKeyIfPresent(keys: keyStore, active: activeProviderStore, trace: trace)
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace.emit("app", "applicationDidFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")

        // v0.2.0: "has key" now means a key exists for whatever provider
        // the user marked as active. Falls back to .anthropic for fresh
        // installs so the v0.1.x logic still holds.
        let activeProvider = (try? activeProviderStore.read()) ?? .anthropic
        let hasKey: Bool = ((try? keyStore.read(activeProvider)) ?? nil)?.isEmpty == false
        let axOK = permissions.isAXGranted()

        if !hasKey || !axOK {
            trace.emit("app", "onboarding needed (provider=\(activeProvider.rawValue) hasKey=\(hasKey) axOK=\(axOK))")
            presentOnboarding()
        } else {
            trace.emit("app", "onboarding skipped; entering running state (provider=\(activeProvider.rawValue))")
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
            activeProviderStore: activeProviderStore,
            clientFactory: { [trace] provider, key in
                LLMClient(
                    provider: provider,
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
            // v0.4.0 Part C/D: continuous-loop dispatch ledger lives in
            // the same SQLite DB. Migration v3 (loop_dispatches table)
            // ran during the SupervisorDatabase init above.
            self.loopDispatchStore = LoopDispatchStore(database: db)
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
        // v0.1.4 Gap 8: hover visibility depends on whether Supervisor
        // is actually tailing a session. discovery is constructed later
        // (step 6) so we read it lazily via a closure capturing self.
        // Load user config (Issue #3: additional host apps from config.yaml).
        let userConfig = UserConfig.load(from: paths.configPath)
        let hoverWindow = HoverWindowController(
            vm: hoverVM,
            isAnySessionActive: { [weak self] in
                (self?.discovery?.activeSessions().isEmpty == false)
            },
            additionalHostApps: userConfig.additionalHostApps
        )
        self.hoverWindow = hoverWindow
        hoverWindow.present()

        // Watch config.yaml for live changes — FSEvents fires on write/rename.
        let watcher = ConfigWatcher(configPath: paths.configPath, trace: trace) { [weak hoverWindow] config in
            hoverWindow?.mergeUserConfig(additionalHostApps: config.additionalHostApps)
        }
        watcher.start()
        self.configWatcher = watcher

        // 3. LLM client (key required — should be present post-onboarding).
        // v0.2.0: provider is whatever the user picked in onboarding (or
        // the legacy-migrated .anthropic on first run after upgrade).
        let activeProvider = (try? activeProviderStore.read()) ?? .anthropic
        guard let key = (try? keyStore.read(activeProvider)) ?? nil, !key.isEmpty else {
            trace.emit("app", "FATAL: no API key for provider=\(activeProvider.rawValue) after onboarding; aborting")
            return
        }
        let client = LLMClient(
            provider: activeProvider,
            apiKey: key,
            redactor: DefaultRedactor(),
            traceLog: trace
        )
        self.llm = client
        trace.emit("app", "LLM client ready provider=\(activeProvider.rawValue) model=\(activeProvider.defaultTriageModel)")

        // 4. Notifier + Intervention router (v0.1.4 Part A3) + v0.1.6
        // RecoveryDocWriter (writes handoff markdown before SIGSTOP/SIGTERM).
        let notifier = Notifier(trace: trace)
        self.notifier = notifier
        let recoveryWriter = RecoveryDocWriter(
            directory: paths.recoveryDir,
            trace: trace
        )
        let router = InterventionRouter(
            notifier: notifier,
            locator: LiveProcessLocator(trace: trace),
            signalSender: DarwinSignalSender(),
            injector: CGEventInjector(trace: trace),
            recoveryDocWriter: recoveryWriter,
            trace: trace
        )
        self.router = router

        // 5. Triage engine. v0.2.0: model comes from the active provider.
        // v0.3.0: optional QuestionAnswerer for the user_question_pending
        // secondary call. v0.4.0: optional Dispatcher + LoopController
        // + LoopDispatchStore for the worker_idle_post_completion
        // dispatch loop. Both PRINCIPLES.md-loading paths use the
        // three-candidate-URL pattern; if the file isn't found the
        // corresponding component stays nil and the engine degrades
        // (QuestionAnswerer nil → plain notify on user_question_pending;
        // Dispatcher nil → plain notify on worker_idle_post_completion).
        let questionAnswerer = loadQuestionAnswerer(client: client, trace: trace)
        let dispatcher = loadDispatcher(client: client, trace: trace)
        // LoopController is always constructed (loop hard stops are
        // pure logic — no external deps). LoopDispatchStore was set up
        // in step 1 above. Both are passed into the engine; tests
        // bypass them by passing nil.
        let loopController = LoopController(trace: trace, loopStore: loopDispatchStore)
        self.loopController = loopController
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: activeProvider.defaultTriageModel,
            windowSize: 30,
            costStore: costStore,
            redactor: DefaultRedactor(),
            questionAnswerer: questionAnswerer,
            dispatcher: dispatcher,
            loopController: loopController,
            loopStore: loopDispatchStore,
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
            case .idle:                                self?.hoverVM?.triageFinishedNoFlag()
            case .flagged(let sev, let action, let plain): self?.hoverVM?.flagRaised(severity: sev, action: action, reasoningPlain: plain)
            }
        }
        engine.onDecision = { [weak self] decision in
            guard let self else { return }
            Task { @MainActor in self.handle(decision: decision) }
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

// MARK: - QuestionAnswerer bootstrap helper

/// Load PRINCIPLES.md from a stable location and construct a
/// `QuestionAnswerer`. Tries (in order): the build's bundle resources,
/// the running app's parent directory, and `/Users/main/supervisor/`
/// (the dev path). Returns nil — silently — if the file can't be
/// found anywhere; the engine treats nil as "no secondary call,"
/// which degrades user_question_pending flags to plain notify
/// without breaking the primary triage path.
@MainActor
private func loadQuestionAnswerer(client: LLMClient, trace: TraceLog) -> QuestionAnswerer? {
    let candidates: [URL] = [
        // Bundle resource (when PRINCIPLES.md ships embedded).
        Bundle.main.url(forResource: "PRINCIPLES", withExtension: "md"),
        // Dev path: the bundle lives at .../build/Supervisor.app — go up to repo root.
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PRINCIPLES.md"),
        // Hard-coded dev path as last-resort fallback. This is correct on
        // Mohammed's machine and harmless to try anywhere else (returns
        // nil if absent).
        URL(fileURLWithPath: "/Users/main/supervisor/PRINCIPLES.md"),
    ].compactMap { $0 }

    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            trace.emit("app", "loaded PRINCIPLES.md for QuestionAnswerer from \(url.path) (\(text.count) chars)")
            return QuestionAnswerer(client: client, principlesText: text, trace: trace)
        }
    }
    trace.emit("app", "no PRINCIPLES.md found; QuestionAnswerer disabled — user_question_pending flags will surface as plain notify")
    return nil
}

/// v0.4.0 Part D: construct the Dispatcher used by the worker-idle
/// dispatch loop. Same three-candidate-URL pattern as
/// loadQuestionAnswerer — PRINCIPLES.md is the dispatch contract;
/// without it the Dispatcher would be guessing per §1d.
///
/// Two real GH/git fetchers attached: GitHubIssueFetcher (60s
/// per-cwd cache) + GitBranchCommitFetcher (30s per-(cwd, branch)
/// cache). Both degrade silently to empty arrays on shell-out
/// failure — Dispatcher MUST work without gh per the v0.4.0 Part B
/// spec.
@MainActor
private func loadDispatcher(client: LLMClient, trace: TraceLog) -> Dispatcher? {
    let candidates: [URL] = [
        Bundle.main.url(forResource: "PRINCIPLES", withExtension: "md"),
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PRINCIPLES.md"),
        URL(fileURLWithPath: "/Users/main/supervisor/PRINCIPLES.md"),
    ].compactMap { $0 }

    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            trace.emit("app", "loaded PRINCIPLES.md for Dispatcher from \(url.path) (\(text.count) chars)")
            return Dispatcher(
                client: client,
                principlesText: text,
                issueFetcher: GitHubIssueFetcher(trace: trace),
                commitFetcher: GitBranchCommitFetcher(trace: trace),
                trace: trace
            )
        }
    }
    trace.emit("app", "no PRINCIPLES.md found; Dispatcher disabled — worker_idle_post_completion flags will surface as plain notify (no auto-dispatch)")
    return nil
}

// MARK: - Bootstrap

MainActor.assumeIsolated {
    let delegate = SupervisorAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
