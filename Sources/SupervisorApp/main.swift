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

        // v0.8.1: single-instance guard. Kill any prior Supervisor
        // instance so we don't get duplicate hover windows after a
        // self-rebuild/relaunch.
        terminatePriorInstances()

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
        installAppMenu()

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

    /// Onboarding runs while the app is `.regular`, which surfaces a menu
    /// bar. Without a main menu there's no Edit menu, so the standard
    /// editing shortcuts (Cmd+V/C/X/A) have no action to route to the
    /// focused control — a user can TYPE their API key but not PASTE it.
    /// Since keys are 50+ char strings, that silently blocks the whole
    /// first-run flow. Install a minimal main menu whose Edit submenu is
    /// wired to the responder-chain editing selectors (nil target → reaches
    /// the focused SecureField's field editor).
    private func installAppMenu() {
        let mainMenu = NSMenu()

        // AppKit treats the first submenu as the application menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Supervisor",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu — the load-bearing part for paste support.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
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
        // Seed the badge with the CURRENT WORK WINDOW's flag count, not the
        // all-time total. The all-time count (13k+ after months of use) is not
        // a useful "what just happened" badge; the work-window count resets
        // after an idle gap so a fresh launch shows a sane number (often 0).
        // All-time data stays in the DB — this scopes the DISPLAY, not the data.
        let historicFlagCount = (try? flagStore?.countCurrentWorkWindow(now: Date())) ?? 0
        // v0.1.7: pass stores + model name for the expanded panel.
        let activeProviderForHover = (try? activeProviderStore.read()) ?? .anthropic
        let hoverVM = HoverViewModel(
            bus: bus,
            trace: trace,
            initialFlagCount: historicFlagCount,
            costStore: costStore,
            flagStore: flagStore,
            modelName: activeProviderForHover.defaultTriageModel
        )
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

        // Self-rebuild announcement: if the deploy step left a marker, the
        // app was just rebuilt and relaunched over a running instance.
        // Announce it on the hover so the user sees Supervisor updated
        // itself, then delete the marker so it only shows once.
        let marker = paths.selfRebuildMarkerPath
        if let version = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            hoverVM.announceSelfRebuild(version: trimmed.isEmpty ? nil : trimmed)
            try? FileManager.default.removeItem(at: marker)
            trace.emit("app", "self-rebuild marker found; announced and cleared")
        }

        // Debug affordance: SUPERVISOR_DEBUG_FLASH=1 fires a sample action
        // flash every few seconds after launch, so the action-flash
        // animation can be verified on screen without waiting for a real
        // pause/kill. Inert unless the env var is set. This is how to
        // confirm the flash that "kept getting shipped but was never seen."
        if ProcessInfo.processInfo.environment["SUPERVISOR_DEBUG_FLASH"] == "1" {
            trace.emit("app", "DEBUG_FLASH enabled; holding a continuous sample flash")
            Task { @MainActor [weak hoverVM] in
                // Re-trigger faster than the 2.5s auto-off so the flash stays
                // lit continuously for ~90s, making on-screen verification
                // timing-independent (any capture in the window shows it).
                for i in 0..<60 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let vm = hoverVM else { return }
                    vm.recordAction(
                        action: .pause,
                        description: "Paused Claude Code. Needs your attention."
                    )
                    if i == 0 { trace.emit("app", "DEBUG_FLASH holding continuous flash") }
                }
            }
        }

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
        // v0.9.0 (integrity): the hover action log + live label must report the
        // REAL inject result, not intent. Wire the Notifier's result hook to the
        // hover so every recorded action is driven by what actually happened
        // (answered vs "couldn't place it, here it is to paste"). Hops to the
        // main actor for the @MainActor hover.
        let notifier = Notifier(trace: trace, onResult: { decision, outcome in
            // [weak hoverVM] on the Task, NOT the outer @Sendable closure:
            // capturing the weak var in the nested concurrently-executing Task
            // is the Swift-5.10 "capture of var in concurrently-executing code"
            // error CI flags (6.2.x doesn't, so it builds clean locally). This
            // mirrors the working DEBUG_FLASH Task pattern above. hoverVM is a
            // @MainActor view model (Sendable), so the @Sendable closure may
            // hold it; the Task takes it weakly so async work doesn't extend its life.
            Task { @MainActor [weak hoverVM] in hoverVM?.recordInterventionOutcome(decision, outcome) }
        })
        self.notifier = notifier
        let recoveryWriter = RecoveryDocWriter(
            directory: paths.recoveryDir,
            trace: trace
        )
        let locator = LiveProcessLocator(trace: trace)
        let signalSender = DarwinSignalSender()
        // Self-authorization gap (the impersonation gap): one ledger, shared by
        // the router (which records every inject + continue-dispatch at type
        // time) and the engine (which reads it to label injected turns), so the
        // triage never reads Supervisor's own injected text back as the owner's
        // authorization for a destructive action.
        let injectionLedger = InjectionLedger()
        let router = InterventionRouter(
            notifier: notifier,
            locator: locator,
            signalSender: signalSender,
            injector: CGEventInjector(trace: trace, llm: client),
            recoveryDocWriter: recoveryWriter,
            // Count sessions seen in the last 10 minutes — the concurrency
            // window for "is more than one Claude Code session live right now."
            // Gates desktop-app inject delivery so a dispatch for one session
            // can't be typed into another (the 2026-06-04 misroute).
            activeSessionCount: { [weak self] in
                guard let store = self?.sessionStore else { return 1 }
                let cutoff = Date().addingTimeInterval(-600)
                let n = (try? store.all().filter { $0.lastSeenAt >= cutoff }.count) ?? 1
                return max(n, 1)
            },
            injectionLedger: injectionLedger,
            trace: trace
        )
        self.router = router

        // v0.1.7: wire the resume handler for the expanded panel's
        // Resume button. Uses the same locator + signal sender as the
        // router's pause path, but sends SIGCONT instead of SIGSTOP.
        hoverVM.resumeHandler = { [weak self] cwd in
            guard let self else { return false }
            guard let handle = locator.locate(targetCwd: cwd) else {
                self.trace.emit("hover", "resume: locator returned nil for cwd=\(cwd)")
                return false
            }
            do {
                try signalSender.send(SIGCONT, to: handle.pid)
                self.trace.emit("hover", "resume: SIGCONT sent pid=\(handle.pid) cwd=\(cwd)")
                return true
            } catch {
                self.trace.emit("hover", "resume: SIGCONT failed pid=\(handle.pid) error=\(error)")
                return false
            }
        }

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
        let dispatcher = loadDispatcher(client: client, trace: trace, dispatchHistory: loopDispatchStore)
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
            // cwd-exclusivity gate: count live sessions (last 10 min) sharing a
            // cwd, so repo grounding is omitted when this isn't the sole worker
            // in that dir — prevents one session's git state bleeding into a
            // co-located session's answer/dispatch (2026-06-13 tweet-engine bleed).
            liveSessionsSharingCwd: { [weak self] cwd in
                guard let store = self?.sessionStore else { return 1 }
                let cutoff = Date().addingTimeInterval(-600)
                let n = (try? store.all().filter { $0.cwd == cwd && $0.lastSeenAt >= cutoff }.count) ?? 1
                return max(n, 1)
            },
            injectionLedger: injectionLedger,
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

        // The menu-bar health icon (green check / red glyph) lives only in
        // SupervisorStatusBar.app, and the main app runs as .accessory with no
        // Dock icon, status item, or Quit. Launch the companion now so a fresh
        // user always sees the health indicator and has an honest quit path,
        // even if they never opened SupervisorStatusBar.app from the DMG.
        // Degrades silently — the harness is fully functional without it.
        launchStatusBarCompanion()

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

        // Screen Recording: the desktop conversation targeter screenshots the
        // Claude desktop window to read its sidebar and pick the right
        // conversation before injecting. Without the grant, desktop targeting
        // falls back to notify. Request once on entry so Supervisor appears in
        // System Settings > Privacy > Screen Recording for the user to enable;
        // macOS only surfaces the prompt the first time per app identity and
        // never blocks on the user's choice.
        if !permissions.isScreenRecordingGranted() {
            trace.emit("app", "screen recording not granted — requesting once (needed for desktop conversation targeting)")
            let granted = CGRequestScreenCaptureAccess()
            trace.emit("app", "screen recording request returned: \(granted)")
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

        // 2b. Pause/kill HOLDS the drive loop for this session, so the worker
        //     going idle right after the interrupt isn't immediately re-driven
        //     (the "it stopped and then Supervisor injected something else" case,
        //     2026-06-16). pause = transient hold (clears when the worker resumes
        //     with a tool call → clearPause); kill = sticky stop (the worker is
        //     gone). Held on the DECISION: correct when the interrupt lands, and
        //     harmless when it degrades — a still-running worker's next tool call
        //     clears the pause on its own.
        switch candidate.action {
        case .pause:
            Task { [weak self] in
                await self?.loopController?.notePause(sessionId: decision.sessionId, reason: .safetyPause)
            }
        case .kill:
            Task { [weak self] in
                await self?.loopController?.stop(sessionId: decision.sessionId, reason: .killFired)
            }
        default:
            break
        }

        // 3. v0.9.0 (integrity): do NOT record the action here. The old eager
        //    record fired at DECISION time with the INTENT label ("Answered a
        //    question") — before the inject ran, and it stayed even when the
        //    inject degraded to nothing. That was the "claims an action it
        //    didn't take" bug. The action log + live label are now recorded
        //    from the REAL outcome via the Notifier's onResult hook
        //    (recordInterventionOutcome), so Supervisor only ever claims an
        //    inject/pause/kill/continue it actually performed.
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

    /// Launch the SupervisorStatusBar.app companion, which owns the menu-bar
    /// health icon and the Quit affordance. Unlike the embedded heartbeat
    /// binary (Process-spawned above), this is a full .app bundle that owns an
    /// NSStatusBar item, so it must launch as an app via NSWorkspace.
    ///
    /// Intentionally one-way: we never terminate it on our own exit. That is
    /// the two-process health design — if the main app dies, the companion
    /// stays alive and turns the icon red.
    private func launchStatusBarCompanion() {
        // Already open (e.g. the user launched it from the DMG)? Do nothing,
        // so we never end up with two status items.
        if !NSRunningApplication
            .runningApplications(withBundleIdentifier: "live.supervisor.statusbar")
            .isEmpty {
            trace.emit("app", "status-bar companion already running — not launching a second")
            return
        }

        // It ships as a SIBLING of Supervisor.app (both dragged from the DMG to
        // /Applications; both under build/ in dev). bundleURL is Supervisor.app
        // itself, so its parent is the directory that contains both bundles.
        let companion = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("SupervisorStatusBar.app")

        guard FileManager.default.fileExists(atPath: companion.path) else {
            trace.emit("app", "status-bar companion not found at \(companion.path) — menu-bar icon will be absent (harness still functional)")
            return
        }

        NSWorkspace.shared.openApplication(
            at: companion,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] app, error in
            if let error = error {
                self?.trace.emit("app", "ERROR failed to launch status-bar companion: \(error)")
            } else {
                self?.trace.emit("app", "launched status-bar companion pid=\(app?.processIdentifier ?? -1) path=\(companion.path)")
            }
        }
    }

    // MARK: - Single-instance guard

    /// Kill any prior Supervisor.app instances so we don't get duplicate
    /// hover windows after a self-rebuild/relaunch. Identifies siblings by
    /// bundle identifier, terminates any with a different PID than ours.
    private func terminatePriorInstances() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier ?? "live.supervisor.app"
        let siblings = NSRunningApplication.runningApplications(
            withBundleIdentifier: myBundle
        ).filter { $0.processIdentifier != myPID }

        for app in siblings {
            trace.emit("app", "terminating prior instance pid=\(app.processIdentifier)")
            app.terminate()
        }
        if !siblings.isEmpty {
            trace.emit("app", "terminated \(siblings.count) prior instance(s)")
        }
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

/// Ordered search path for PRINCIPLES.md, most-specific first:
///   1. user override — ~/Library/Application Support/Supervisor/PRINCIPLES.md
///      (a user drops their own here to make Supervisor answer their way)
///   2. the generic default that ships embedded in the app bundle
///   3. dev convenience — the repo root, when running the unbundled binary
///      from .../build/ (never present on a shipped install)
/// The old hard-coded /Users/main/supervisor path is intentionally gone:
/// a shipped user only ever sees their own override or the bundled default,
/// never Mohammed's dev manual.
private func principlesURLCandidates() -> [URL] {
    let override = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Supervisor/PRINCIPLES.md")
    return [
        override,
        Bundle.main.url(forResource: "PRINCIPLES", withExtension: "md"),
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PRINCIPLES.md"),
    ].compactMap { $0 }
}

/// Load PRINCIPLES.md (see `principlesURLCandidates` for the search order)
/// and construct a `QuestionAnswerer`. Returns nil — silently — if no
/// PRINCIPLES.md is found anywhere; the engine treats nil as "no secondary
/// call," which degrades user_question_pending flags to plain notify
/// without breaking the primary triage path.
@MainActor
private func loadQuestionAnswerer(client: LLMClient, trace: TraceLog) -> QuestionAnswerer? {
    let candidates = principlesURLCandidates()

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
private func loadDispatcher(
    client: LLMClient,
    trace: TraceLog,
    dispatchHistory: (any DispatchHistoryReading)? = nil
) -> Dispatcher? {
    let candidates = principlesURLCandidates()

    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            trace.emit("app", "loaded PRINCIPLES.md for Dispatcher from \(url.path) (\(text.count) chars)")
            return Dispatcher(
                client: client,
                principlesText: text,
                principlesPath: url,
                issueFetcher: GitHubIssueFetcher(trace: trace),
                commitFetcher: GitBranchCommitFetcher(trace: trace),
                dispatchHistory: dispatchHistory,
                grounder: RepoProposalGrounder(trace: trace),
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
