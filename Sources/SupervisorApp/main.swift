// SupervisorApp main entry — Phase C lifecycle.
//
// Boots SupervisorCore, runs onboarding if needed, then enters the
// running state:
//
//   - Spawns SupervisorHeartbeat (writes heartbeat.txt) and
//     SupervisorStatusBar (reads it, owns the menu-bar health icon) as
//     child processes
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
import UserNotifications

@MainActor
final class SupervisorAppDelegate: NSObject, NSApplicationDelegate {

    private let paths = ConfigPaths()
    private let trace: TraceLog
    private let permissions: any PermissionChecker
    private let keyStore: any ProviderKeyStore
    private let activeProviderStore: any ActiveProviderStore

    // Onboarding
    private var onboarding: OnboardingWindowController?
    /// Main-run-loop liveness beat (see startAppAliveBeat).
    private var appAliveTimer: Timer?
    /// Small floating panel shown when the launch keychain probe exceeds
    /// its watchdog (a SecurityAgent prompt is likely up, possibly hidden).
    private var keychainWaitPanel: NSPanel?

    // Running state
    private var hoverVM: HoverViewModel?
    /// Ambient Context Health monitor — retained for the app's lifetime; feeds the
    /// panel's Context Health line and re-audits in the background on demand.
    private var contextHealthMonitor: ContextHealthMonitor?
    /// Opens the Context Health window; shared by the panel line, the menu item,
    /// and the nudge notification's "Show me" action.
    private var openContextHealthWindow: (() -> Void)?
    private var hoverWindow: HoverWindowController?
    private var database: SupervisorDatabase?
    private var sessionStore: SessionStore?
    private var flagStore: FlagStore?
    private var costStore: CostStore?
    private var loopDispatchStore: LoopDispatchStore?
    private var planStore: PlanStore?
    private var auditStore: AuditStore?
    private var loopController: LoopController?
    private var configWatcher: ConfigWatcher?
    private var llm: LLMClient?
    private var triageEngine: TriageEngine?
    private var reviewFindingStore: ReviewFindingStore?
    private var reviewEngine: ReviewEngine?
    private var discovery: SessionDiscovery?
    private var codexDiscovery: CodexSessionDiscovery?
    private var notifier: Notifier?
    private var router: InterventionRouter?
    private var bus: EventBus?

    // Menu-bar status item lives in the SupervisorStatusBar COMPANION process,
    // not here. An in-process NSStatusItem dies with the app — a crash makes
    // the icon vanish instead of turning red, and a hung engine keeps a static
    // green icon forever because nothing re-reads liveness. The companion polls
    // heartbeat.txt and honestly shows red/amber when supervision is dead/hung.
    // Spawned in step 7 (startStatusBar), torn down at teardown (stopStatusBar).
    private var statusBarProcess: Process?

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
        // v0.2.0's one-shot legacy-key migration used to run right here,
        // synchronously, before applicationDidFinishLaunching. It now runs
        // inside routeAfterKeychainProbe, off the main thread: it is a
        // Keychain read, and a Keychain read on the main thread before any
        // UI exists can park the whole launch on an invisible SecurityAgent
        // prompt (trial-notes 2026-06: the ACL'd-to-old-signature hang).
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace.emit("app", "applicationDidFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")

        // Gatekeeper App Translocation: launched straight from the mounted
        // dmg (or an unstripped quarantine copy), macOS runs the app from a
        // randomized read-only path that CHANGES between launches. That
        // breaks the Keychain ACL each time (fresh "allow keychain" prompt
        // per launch, the pre-UI hang above) and generally produces the
        // "works one launch, not the next" reports. Say so, up front, once.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            trace.emit("app", "translocated launch detected at \(Bundle.main.bundlePath)")
            let alert = NSAlert()
            alert.messageText = "Move Supervisor to Applications"
            alert.informativeText = "Supervisor is running from a temporary location (macOS App Translocation), usually because it was opened straight from the downloaded dmg. Drag Supervisor.app into your Applications folder and open it from there — otherwise macOS re-asks Keychain permission on every launch and launches can appear to do nothing."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit and Move Manually")
            alert.addButton(withTitle: "Continue Anyway")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                trace.sync()
                exit(0)
            }
        }

        // Single-instance guard. If another Supervisor is already
        // watching, this duplicate quits instead of fighting it.
        // Returns early when we decided to quit so we never enter the
        // running state as a second band.
        guard enforceSingleInstance() else { return }

        // Main-run-loop liveness beat: touch app-alive.txt now and every 5s
        // from a main-run-loop Timer. A duplicate launch reads this file's
        // age to tell a healthy incumbent (activate it) from a hung one
        // (take over) — see DuplicateLaunchPolicy. The first touch happens
        // before anything that can block, so a racing loser sees a fresh
        // marker within milliseconds of us winning the lock.
        startAppAliveBeat()

        // The winner listens for a duplicate launch's "surface yourself"
        // signal, so double-clicking Supervisor.app while it is already
        // running re-presents the UI instead of doing visibly nothing (the
        // duplicate exits either way; see handleDuplicateLaunch).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(DuplicateLaunchPolicy.activateNotification),
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.surfaceForUserAttention() }
        }

        routeAfterKeychainProbe()
    }

    /// Decide onboarding-vs-running WITHOUT touching the Keychain on the
    /// main thread. With a signature/ACL mismatch (new certificate,
    /// re-downloaded or translocated copy), a Keychain read parks the calling
    /// thread on a SecurityAgent "Always Allow / Deny" prompt — and that
    /// prompt can sit behind other windows. On the main thread before any UI
    /// exists, that is indistinguishable from "the app didn't open". Off the
    /// main thread, the run loop stays alive and a watchdog makes the wait
    /// visible in the trace instead of silent.
    private func routeAfterKeychainProbe() {
        let keyStore = self.keyStore
        let activeProviderStore = self.activeProviderStore
        let trace = self.trace

        let watchdog = DispatchWorkItem { [weak self] in
            let msg = "keychain probe still pending after 10s — a macOS Keychain permission prompt (SecurityAgent) is likely waiting for the user; launch continues when it is answered"
            trace.emit("app", msg)
            FileHandle.standardError.write(Data("Supervisor: \(msg)\n".utf8))
            // Trace lines don't help the user staring at "nothing opened":
            // put a small panel on screen saying what to look for.
            self?.showKeychainWaitPanel()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: watchdog)

        DispatchQueue.global(qos: .userInitiated).async {
            // v0.2.0: one-shot migration of the v0.1.x single-key Keychain
            // item into the per-provider layout. Idempotent — every launch
            // after the first is a no-op. Runs here (not in init) because it
            // is also a Keychain read.
            migrateLegacyKeyIfPresent(keys: keyStore, active: activeProviderStore, trace: trace)

            // v0.2.0: "has key" now means a key exists for whatever provider
            // the user marked as active. Falls back to .anthropic for fresh
            // installs so the v0.1.x logic still holds.
            let activeProvider = (try? activeProviderStore.read()) ?? .anthropic
            let hasKey: Bool = ((try? keyStore.read(activeProvider)) ?? nil)?.isEmpty == false

            DispatchQueue.main.async { [weak self] in
                watchdog.cancel()
                guard let self else { return }
                self.dismissKeychainWaitPanel()
                let axOK = self.permissions.isAXGranted()
                if !hasKey || !axOK {
                    self.trace.emit("app", "onboarding needed (provider=\(activeProvider.rawValue) hasKey=\(hasKey) axOK=\(axOK))")
                    self.presentOnboarding()
                } else {
                    self.trace.emit("app", "onboarding skipped; entering running state (provider=\(activeProvider.rawValue))")
                    self.enterRunningState(notifDegraded: false)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trace.emit("app", "applicationWillTerminate; tearing down")
        // Stop the alive beat and DELETE the marker: a clean quit must not
        // leave a fresh-looking marker behind, or a relaunch-within-30s that
        // hangs pre-UI would read as a live incumbent to the next duplicate
        // (which would then activate a corpse and exit silently — the
        // original bug, back through a side door).
        appAliveTimer?.invalidate()
        appAliveTimer = nil
        try? FileManager.default.removeItem(at: paths.appAlivePath)
        triageEngine?.stop()
        reviewEngine?.stop()
        discovery?.stop()
        codexDiscovery?.stop()
        permissionMonitor?.stop()
        hoverWindow?.dismiss()
        stopStatusBar()
        stopHeartbeat()
        // Release the single-instance lock so the next launch claims it
        // cleanly. Only removes the pidfile if it still records our pid.
        SingleInstanceGuard.releaseLock(
            at: paths.pidfilePath,
            myPID: ProcessInfo.processInfo.processIdentifier
        )
        trace.sync()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await permissionMonitor?.probeNow() }
    }

    // MARK: - Onboarding

    /// The user tried to open Supervisor while this instance already runs
    /// (dock/Finder reopen event, or a second process that bowed out and
    /// pinged us): surface whatever UI this instance owns so the click did
    /// something visible. The hover is FORCE-shown briefly — its normal
    /// visibility gate requires a terminal frontmost, and the user who just
    /// clicked in Finder fails that gate, which made the old present() call
    /// a silent no-op.
    private func surfaceForUserAttention() {
        trace.emit("app", "user-attention event (reopen or duplicate launch); surfacing UI")
        NSApp.activate(ignoringOtherApps: true)
        if let onboarding {
            onboarding.present()
        } else {
            hoverWindow?.surfaceBriefly()
        }
    }

    /// Dock-icon click / Finder double-click on the already-running app.
    /// Without this, LaunchServices activates the process, no window
    /// appears (accessory app), and the user concludes "it didn't open".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        surfaceForUserAttention()
        return false
    }

    // MARK: - Keychain-wait panel

    private func showKeychainWaitPanel() {
        guard keychainWaitPanel == nil else { return }
        let text = NSTextField(wrappingLabelWithString:
            "Supervisor is waiting on a macOS Keychain permission prompt.\n\nLook for a dialog asking to allow access to \"Supervisor\" (it can be behind other windows) and click Always Allow.")
        text.frame = NSRect(x: 16, y: 14, width: 328, height: 92)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Supervisor is starting"
        panel.level = .floating
        panel.contentView?.addSubview(text)
        panel.center()
        panel.orderFrontRegardless()
        keychainWaitPanel = panel
    }

    private func dismissKeychainWaitPanel() {
        keychainWaitPanel?.orderOut(nil)
        keychainWaitPanel = nil
    }

    // MARK: - App-alive beat (main-run-loop liveness marker)

    private func startAppAliveBeat() {
        touchAppAlive()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.touchAppAlive()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        appAliveTimer = timer
    }

    private func touchAppAlive() {
        // mtime is the signal; the content is a debugging courtesy.
        try? "\(ProcessInfo.processInfo.processIdentifier) \(Date().timeIntervalSince1970)\n"
            .write(to: paths.appAlivePath, atomically: true, encoding: .utf8)
    }

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
            // v0.2.0 M2a: plan state lives in the same SQLite DB.
            // Migration v4 (plans + plan_steps tables) ran during the
            // SupervisorDatabase init above. The store is constructed
            // here; the Planner/Evaluator/loop lifecycle that uses it
            // lands in later v0.2.0 milestones.
            self.planStore = PlanStore(database: db)
            // v0.2.0 observability (Reddit feedback A): the unified audit log
            // lives in the same SQLite DB. Migration v5 (audit_entries table)
            // ran during the SupervisorDatabase init above. The store is
            // recorded into ADDITIVELY from the existing decision hooks
            // (QuestionAnswerer auto-answer, the DeterministicCatch block, the
            // stall watchdog nudge, and PlanLoop/Evaluator) and read back by
            // SessionReportExporter (PART C).
            self.auditStore = AuditStore(database: db)
            // v0.3.x REVIEW dimension: the code-review finding ledger (dedup +
            // durable record). Migration v6 (review_findings) ran during the
            // SupervisorDatabase init above. Written into only when the REVIEW
            // feature is opted in; empty otherwise.
            self.reviewFindingStore = ReviewFindingStore(database: db)
            trace.emit("app", "storage opened at \(paths.databasePath.path)")
        } catch {
            trace.emit("app", "FATAL: storage open failed: \(error)")
            // Be loud, then die. The old `return` left a zombie: no UI, but
            // the single-instance lock already claimed — so every relaunch
            // silently exited as a "duplicate" of a process showing nothing.
            let alert = NSAlert()
            alert.messageText = "Supervisor can't open its local database"
            alert.informativeText = "The database at \(paths.databasePath.path) failed to open:\n\n\(error.localizedDescription)\n\nIf this repeats, quit Supervisor, move that file aside, and relaunch — Supervisor will start fresh (past flags and cost history stay in the old file)."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            trace.sync()
            exit(1)
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
            // v0.2.0 M3: the panel's live Plan view reads the watched session's
            // current plan from here. Additive — nil-safe in the planner-off path.
            planStore: planStore,
            // v0.2.0 observability (Reddit feedback D): the panel's Activity view
            // reads the watched session's audit entries from here. Additive +
            // read-only; nil-safe when no audit log exists.
            auditStore: auditStore,
            // v0.3.x REVIEW dimension: the panel's Review tab reads the watched
            // session's code-review findings from here. Additive + read-only;
            // nil-safe when the feature is off / no findings exist.
            reviewStore: reviewFindingStore,
            modelName: activeProviderForHover.defaultTriageModel
        )
        self.hoverVM = hoverVM

        // Context Health (ambient audit surface): a cheap deterministic audit of
        // the owner's skills setup runs in the background, feeds the panel's quiet
        // Context Health line, and opens the full window on tap. Additive + on
        // demand — the auditor never runs in the triage loop, and if unwired the
        // panel section simply doesn't render.
        let chRoot = paths.home.appendingPathComponent(".claude/skills", isDirectory: true)
        let chStore = self.database.map { ContextAuditStore(database: $0) }
        let chTrace = trace   // local binding: no self-capture in the stored closure below
        let healthMonitor = ContextHealthMonitor(root: chRoot, store: chStore, trace: chTrace)
        // The single earned nudge: post ONE notification the first time a
        // background audit finds notable drift (the monitor guarantees once-ever).
        // Captures self weakly (no cycle); `notifier` is set just below and the
        // audit completes async, so it exists by the time this fires. Returns
        // whether the post ACTUALLY landed — the monitor persists its once-ever
        // flag only on success, so a failed center.add (or a race where the
        // notifier isn't wired yet) doesn't silently burn the one nudge.
        healthMonitor.onFirstNotable = { [weak self] count, lines in
            chTrace.emit("context-health", "first notable crossing: \(count) cleanups (~\(lines) lines) — posting nudge")
            guard let notifier = self?.notifier else { return false }
            return await notifier.postContextHealth(count: count, lines: lines) == .posted
        }
        hoverVM.contextHealth = healthMonitor
        // One window, many doors: the panel line, the menu item, and the nudge's
        // "Show me" action all open this.
        let openContextHealth = { ContextHealthPresenter.shared.present(root: chRoot, store: chStore) }
        hoverVM.onOpenContextHealth = openContextHealth
        self.openContextHealthWindow = openContextHealth
        self.contextHealthMonitor = healthMonitor
        healthMonitor.refresh()   // warm the verdict so the line is ready on first expand

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
            // Live session count from discovery: lets the one hover band read
            // "Watching N sessions. All clear" when Supervisor is busy, instead
            // of the label flipping between project names per session event.
            activeSessionCount: { [weak self] in
                self?.discovery?.activeSessions().count ?? 0
            },
            additionalHostApps: userConfig.additionalHostApps
        )
        self.hoverWindow = hoverWindow
        hoverWindow.present()

        // Menu-bar health icon is owned by the SupervisorStatusBar companion,
        // spawned in step 7 (startStatusBar) so it reads the heartbeat this app
        // + its heartbeat child keep fresh. Not created in-process: an
        // in-process icon can't honestly report a crash or a hang (see the
        // statusBarProcess property comment).

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
        // v0.3.0 (P0-4): both LLMClient hooks are wired HERE, on the one client
        // instance every model call flows through — TriageEngine,
        // QuestionAnswerer, Dispatcher, and the injector's conversation matcher
        // all share `client` — so every createMessage is recorded exactly once
        // and gated by the daily cap. TriageEngine still HAS per-call-site
        // recordHaiku sites (owned by the engine agent), so to avoid
        // double-counting we pass `costStore: nil` into the engine below and
        // let the choke-point recorder here be the single source of spend. (The
        // onboarding clientFactory stays unhooked on purpose: it runs before the
        // DB opens, and its 1-token key-validation call must not be refused by a
        // spent cap.)
        guard let hookCostStore = self.costStore else {
            trace.emit("app", "FATAL: costStore missing before LLM client construction")
            return
        }
        let configPath = paths.configPath
        let client = LLMClient(
            provider: activeProvider,
            apiKey: key,
            redactor: DefaultRedactor(),
            traceLog: trace,
            costRecorder: { model, usage in
                try? hookCostStore.recordHaiku(
                    inputTokens: usage.input_tokens,
                    outputTokens: usage.output_tokens,
                    costUSD: TokenAccounting.costUSD(model: model, usage: usage)
                )
            },
            capCheck: {
                // Re-read config.yaml at each gate so a cap edit takes effect
                // without a restart (same live-config posture as ConfigWatcher).
                // The file is tiny; model calls are network-bound and seconds apart.
                guard let cap = UserConfig.load(from: configPath).dailyCostCapUSD else { return nil }
                let spent = (try? hookCostStore.todayTotalUSD()) ?? 0
                return (cap: cap, spent: spent)
            }
        )
        self.llm = client
        trace.emit("app", "LLM client ready provider=\(activeProvider.rawValue) model=\(activeProvider.defaultTriageModel) costRecorder=on capCheck=on")

        // Multi-model panel ("Second opinion"): wire the hover's panel handler to
        // a PanelCoordinator built from ALL configured provider keys, with the
        // SAME cost recorder + daily-cap gate as the main client so panel spend
        // counts against one budget. Rebuilt per request so a mode switch (DIY /
        // Fusion) takes effect without a relaunch. `panelReady` gates the
        // affordance so it only appears when a panel can actually run: two or more
        // non-OpenRouter providers (a cross-provider DIY panel), or an OpenRouter
        // key (Fusion). Off by default regardless — the owner opts in in the panel.
        let panelKeyStore = self.keyStore
        let panelCostStore = hookCostStore
        let panelConfigPath = configPath
        let panelTrace = trace
        let panelCostRecorder: @Sendable (String, AnthropicUsage) -> Void = { model, usage in
            try? panelCostStore.recordHaiku(
                inputTokens: usage.input_tokens,
                outputTokens: usage.output_tokens,
                costUSD: TokenAccounting.costUSD(model: model, usage: usage)
            )
        }
        let panelCapCheck: @Sendable () -> (cap: Double, spent: Double)? = {
            guard let cap = UserConfig.load(from: panelConfigPath).dailyCostCapUSD else { return nil }
            let spent = (try? panelCostStore.todayTotalUSD()) ?? 0
            return (cap: cap, spent: spent)
        }
        let panelAvailable = panelKeyStore.availableProviders()
        hoverVM.setConfiguredProviders(panelAvailable)
        // Let the user add more provider keys from the panel settings without
        // re-onboarding. Writes through the SAME per-provider Keychain store
        // triage uses (correct account/ACL, so the app reads it immediately),
        // and returns the refreshed availability so `panelReady` flips on.
        // The write THROWS through to the VM on Keychain failure so the panel
        // surfaces the error — the old `try?` swallowed it and the UI claimed
        // the key was saved when nothing was stored.
        hoverVM.addProviderKeyHandler = { provider, key in
            try panelKeyStore.write(key, for: provider)
            return panelKeyStore.availableProviders()
        }
        hoverVM.secondOpinionHandler = { decision in
            guard let coordinator = PanelCoordinator.live(
                keyStore: panelKeyStore,
                mode: MultiModelPanelStore.mode(),
                redactor: DefaultRedactor(),
                traceLog: panelTrace,
                costRecorder: panelCostRecorder,
                capCheck: panelCapCheck
            ) else { return nil }
            return try? await coordinator.secondOpinion(on: decision)
        }
        trace.emit("app", "multi-model panel wired panelReady=\(hoverVM.panelReady) providers=[\(panelAvailable.map(\.rawValue).joined(separator: ","))]")

        // 4. Notifier + Intervention router (v0.1.4 Part A3) + v0.1.6
        // RecoveryDocWriter (writes handoff markdown before SIGSTOP/SIGTERM).
        // v0.9.0 (integrity): the hover action log + live label must report the
        // REAL inject result, not intent. Wire the Notifier's result hook to the
        // hover so every recorded action is driven by what actually happened
        // (answered vs "couldn't place it, here it is to paste"). Hops to the
        // main actor for the @MainActor hover.
        // Notifier.ifAvailable, never the bare init: UNUserNotificationCenter
        // .current() abort()s in a process without a bundle identifier, and it
        // did — three identical launch SIGABRTs on 2026-07-05 died on this very
        // construction. Without a center the app still launches; the router
        // gets a trace-only stand-in and banners are the one thing lost.
        let notifier = Notifier.ifAvailable(trace: trace, onResult: { decision, outcome in
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
        // Notification-category plumbing: register the Context Health "Show me"
        // category AND the flag category (issue #60 follow-up: the flag category
        // requests .customDismissAction so an explicitly dismissed flag banner
        // reaches didReceive and lands as flags.user_response = dismissed), and
        // make this delegate handle both. A plain tap on a flag banner is
        // engagement, not a response, and is deliberately not recorded.
        if let notifier {
            notifier.registerNotificationCategories()
            UNUserNotificationCenter.current().delegate = self
        }
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
            notifier: notifier ?? TraceOnlyNotifier(trace: trace),
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
        let loopController = LoopController(trace: trace, loopStore: loopDispatchStore, planStore: planStore)
        self.loopController = loopController
        // v0.2.0 M2d-2: the Planner/Evaluator harness driver. Constructed when
        // PRINCIPLES.md + the PlanStore are available, but INERT until the owner
        // flips the planner-enabled marker on (RuntimeToggles.plannerEnabled).
        // With the marker OFF (the default) the engine's idle path is the
        // unchanged Dispatcher path; passing this in changes nothing until opt-in.
        let planLoop = loadPlanLoop(
            client: client, planStore: planStore, loopController: loopController,
            dispatchHistory: loopDispatchStore, auditStore: auditStore, trace: trace
        )
        let engine = TriageEngine(
            client: client,
            bus: bus,
            model: activeProvider.defaultTriageModel,
            windowSize: 30,
            // Single-source-of-spend invariant: the shared `client` above
            // records every createMessage via its costRecorder hook. Passing
            // the engine a nil costStore keeps its own per-call recordHauku
            // sites inert (they are `if let costStore`-guarded) so triage spend
            // is counted exactly once, not twice. NOTE for the engine agent:
            // TriageEngine's recordHaiku sites are now dead in production —
            // they can be removed when the engine is next touched; recording
            // lives at the LLMClient choke point.
            costStore: nil,
            redactor: DefaultRedactor(),
            questionAnswerer: questionAnswerer,
            dispatcher: dispatcher,
            loopController: loopController,
            loopStore: loopDispatchStore,
            auditStore: auditStore,
            planLoop: planLoop,
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
            case .flagged(let sev, let action, let plain, let sid, let cwd): self?.hoverVM?.flagRaised(severity: sev, action: action, reasoningPlain: plain, flaggedSessionId: sid, flaggedSessionCwd: cwd)
            }
        }
        engine.onDecision = { [weak self] decision in
            guard let self else { return }
            Task { @MainActor in self.handle(decision: decision) }
        }
        engine.start()
        self.triageEngine = engine

        // 5b. Review engine (v0.3.x REVIEW dimension) — a SECOND observer that
        // reviews the code a worker writes and surfaces substantive quality
        // issues in the hover panel's Activity tab. It shares the one cost-gated
        // `client` (so review spend rides the same daily cap + recorder as
        // triage) and the same EventBus, but is otherwise independent of the
        // safety path: it consumes only the additive `.fileEdit` event (which
        // TriageEngine ignores) and never pauses/kills/injects. INERT by default
        // — with the `review-enabled.marker` OFF it short-circuits on every event
        // and spends nothing (RuntimeToggles.reviewEnabled), so wiring it in
        // changes no shipped behavior until the owner opts in. Reviews surface as
        // calm Activity-tab entries (pull), never banners (push).
        let reviewEngine = ReviewEngine(
            client: client,
            bus: bus,
            model: activeProvider.defaultTriageModel,
            reviewStore: reviewFindingStore,
            auditStore: auditStore,
            redactor: DefaultRedactor(),
            onFinding: { [weak hoverVM] surfaced in
                hoverVM?.noteReviewFinding(title: surfaced.title)
            },
            trace: trace
        )
        reviewEngine.start()
        self.reviewEngine = reviewEngine
        trace.emit("app", "review engine wired (INERT until review-enabled.marker is set)")

        // v0.2.0 M3: wire the panel's "Approve plan" button to the engine's
        // approval path — the SAME marked + ledgered approvePlan(planId:) the
        // approve-plan marker drives, so the human gate has one implementation.
        // [weak engine] on the Task (not the @Sendable closure) mirrors the
        // Notifier onResult pattern above for the Swift-5.10 capture rule.
        hoverVM.approvePlanHandler = { planId in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { @MainActor [weak engine] in
                    await engine?.approvePlan(planId: planId)
                    cont.resume()
                }
            }
        }

        // v0.2.0 observability (Reddit feedback D): wire the panel's "Export
        // session report" button to SessionReportExporter. It gathers the
        // session's audit log + flags + plan + verdicts and writes a JSON +
        // Markdown bundle into ~/Downloads/Supervisor Reports/ (a stable,
        // user-reachable location), returning the file paths so the VM can reveal
        // the file in Finder. The exporter only READS the stores + WRITES two
        // files; it changes nothing in the engine. Built lazily inside the
        // handler from the same stores so it always reflects the live DB.
        if let auditStore, let flagStore, let planStore, let sessionStore {
            let exporter = SessionReportExporter(
                auditStore: auditStore,
                flagStore: flagStore,
                planStore: planStore,
                sessionStore: sessionStore
            )
            // paths.home (the SUPERVISOR_HOME-aware root), not the raw home:
            // an isolated E2E instance must export reports into ITS fake home,
            // not litter the live user's Downloads.
            let reportsDir = paths.home
                .appendingPathComponent("Downloads/Supervisor Reports", isDirectory: true)
            hoverVM.exportReportHandler = { [trace] sessionId in
                do {
                    let out = try exporter.export(sessionId: sessionId, to: reportsDir)
                    trace.emit("app", "session report exported session=\(sessionId) -> \(out.markdownPath.path)")
                    return out
                } catch {
                    trace.emit("app", "session report export FAILED session=\(sessionId): \(error)")
                    return nil
                }
            }
        }

        // 6. Discovery (kicks off tails for every Claude Code session)
        let discovery = SessionDiscovery(
            claudeProjectsDir: paths.claudeProjectsDir,
            bus: bus,
            sessionStore: sessionStore,
            trace: trace
        )
        discovery.start()
        self.discovery = discovery

        // 6b. Codex discovery — the second agent. Additive: a separate watcher on
        // ~/.codex/sessions feeding the SAME EventBus, so Codex sessions are
        // triaged by the identical rubric. Auto-enabled when Codex is installed
        // (~/.codex/sessions exists) unless `supervise_codex: false` in config.
        // paths.home, not the raw home: honors SUPERVISOR_HOME so the E2E
        // harness can plant fake Codex rollouts under its fake home.
        let codexSessionsDir = paths.home
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let codexEnabled = (userConfig.superviseCodex ?? true)
            && FileManager.default.fileExists(atPath: codexSessionsDir.path)
        if codexEnabled {
            let codexDiscovery = CodexSessionDiscovery(
                codexSessionsDir: codexSessionsDir,
                bus: bus,
                sessionStore: sessionStore,
                trace: trace
            )
            codexDiscovery.start()
            self.codexDiscovery = codexDiscovery
            trace.emit("app", "codex supervision ON — watching \(codexSessionsDir.path)")
        } else {
            trace.emit("app", "codex supervision OFF (superviseCodex=\(String(describing: userConfig.superviseCodex)), dirExists=\(FileManager.default.fileExists(atPath: codexSessionsDir.path)))")
        }

        // 7. Companions: heartbeat + status-bar health icon + permission monitor
        startHeartbeat()
        startStatusBar()
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

        // The E2E harness's abort-gate greps this line: it echoes the resolved
        // home and the RESOLVED keychain service base so a scenario script can
        // PROVE isolation took effect — the fake home actually resolved and
        // keychain writes are namespaced — before driving any UI. The resolved
        // base (not the raw env var) on purpose: an empty/unset
        // SUPERVISOR_KEYCHAIN_PREFIX silently resolves to live.supervisor.api,
        // and a gate matching the raw env would pass vacuously while the app
        // wrote live items. Keep the `home=` / `keychainBase=` tokens stable;
        // Scripts/e2e/common.sh matches on them.
        trace.emit("app", "running state ready — watching \(paths.claudeProjectsDir.path) home=\(paths.home.path) keychainBase=\(LLMProvider.keychainServiceBase)")
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

        // issue #60 follow-up: stamp the persisted row's id onto the decision
        // BEFORE the router dispatch, so (a) the Notifier's result hook can
        // write the REAL InterventionOutcome back onto this exact flags row
        // (HoverViewModel.recordInterventionOutcome -> markInterventionOutcome)
        // and (b) the banner carries the id for the dismiss-response delegate
        // path below. A `let` copy, not the mutated `var`, goes into the Task:
        // capturing a var in concurrently-executing code is the Swift-5.10
        // error CI flags (same rule as the Notifier onResult wiring above).
        var stamped = decision
        stamped.flagId = flag.id
        let routedDecision = stamped

        // 2. Dispatch via router (v0.1.4: handles notify / pause / kill;
        //    inject queued, routed to notify for now). Router internally
        //    handles every locator + signal failure by degrading to a
        //    notify banner — never crashes on a bad PID or revoked perm.
        Task { [weak self] in
            await self?.router?.dispatch(decision: routedDecision)
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

    /// Bounded respawn budget for the heartbeat child, same shape as the
    /// status bar's. Without a respawn, a crashed heartbeat child leaves a
    /// permanently stale heartbeat.txt under a perfectly healthy app — the
    /// menu-bar icon reads dead forever and honest-health becomes a lie in
    /// the pessimistic direction.
    private var heartbeatRespawnCount = 0
    private let heartbeatRespawnLimit = 3

    private func startHeartbeat() {
        stopHeartbeat()
        guard let url = locateHeartbeatExecutable() else {
            trace.emit("app", "ERROR cannot locate SupervisorHeartbeat executable")
            return
        }
        let proc = Process()
        proc.executableURL = url
        // Installed BEFORE run() so an instantly-exiting child cannot slip
        // past it (same rule as the status bar's handler).
        proc.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.heartbeatDidExit(process, status: status)
            }
        }
        do {
            try proc.run()
            heartbeatProcess = proc
            trace.emit("app", "spawned heartbeat pid=\(proc.processIdentifier) path=\(url.path)")
        } catch {
            trace.emit("app", "ERROR failed to spawn heartbeat: \(error)")
        }
    }

    /// Unexpected heartbeat exit (crash / external kill — deliberate stops
    /// clear the terminationHandler first): bounded respawn, then an honest
    /// give-up trace.
    private func heartbeatDidExit(_ proc: Process, status: Int32) {
        guard proc === heartbeatProcess else { return }
        heartbeatProcess = nil
        heartbeatRespawnCount += 1
        guard heartbeatRespawnCount <= heartbeatRespawnLimit else {
            trace.emit("app", "ERROR heartbeat exited (status=\(status)) after \(heartbeatRespawnLimit) respawns — giving up; menu-bar health will read stale for the rest of this run")
            return
        }
        trace.emit("app", "heartbeat exited unexpectedly status=\(status) — respawning (\(heartbeatRespawnCount)/\(heartbeatRespawnLimit)) in 2s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.startHeartbeat()
        }
    }

    private func stopHeartbeat() {
        guard let proc = heartbeatProcess, proc.isRunning else { return }
        trace.emit("app", "terminating heartbeat pid=\(proc.processIdentifier)")
        proc.terminationHandler = nil  // deliberate stop, not a crash: no respawn
        proc.terminate()
        heartbeatProcess = nil
    }

    private func locateHeartbeatExecutable() -> URL? {
        locateCompanionExecutable(named: "SupervisorHeartbeat")
    }

    // MARK: - Status-bar companion (owns the menu-bar health icon)

    /// Bounded respawn budget for the status-bar companion. If the companion
    /// dies UNEXPECTEDLY (crash, external kill — never a deliberate stop, see
    /// stopStatusBar), it is respawned after a short delay up to this many
    /// times per app run, then we give up with an honest trace ERROR. The
    /// bound is the point: a companion that crashes on every boot must not
    /// become a spawn loop.
    private var statusBarRespawnCount = 0
    private let statusBarRespawnLimit = 3

    /// Spawn the SupervisorStatusBar companion. It is a direct child of this
    /// process, so its own getppid()-style watching (and the heartbeat child's)
    /// hangs off the same parent. It reads heartbeat.txt and drives the menu-bar
    /// icon red/amber/green — the honest-health surface that must survive a
    /// crash of THIS app (which an in-process NSStatusItem could not).
    private func startStatusBar() {
        stopStatusBar()
        guard let url = locateStatusBarExecutable() else {
            trace.emit("app", "ERROR cannot locate SupervisorStatusBar executable — menu-bar health icon unavailable")
            return
        }
        let proc = Process()
        proc.executableURL = url
        // Supervise the health surface itself: without this handler a crashed
        // companion stays dead for the rest of the app run — no icon, no
        // honest red later, no Quit/Restart affordance. The handler runs on a
        // background thread, so hop to the main actor before touching any
        // delegate state (same Task { @MainActor } idiom as the engine wiring
        // above). Installed BEFORE run() so an instantly-exiting child cannot
        // slip past it.
        proc.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.statusBarDidExit(process, status: status)
            }
        }
        do {
            try proc.run()
            statusBarProcess = proc
            trace.emit("app", "spawned status-bar pid=\(proc.processIdentifier) path=\(url.path)")
        } catch {
            trace.emit("app", "ERROR failed to spawn status-bar: \(error)")
        }
    }

    /// Unexpected status-bar exit. Deliberate stops never land here (they
    /// clear the terminationHandler first), so this is a crash or an external
    /// kill: respawn with a bounded per-app-run budget, and past the budget
    /// trace an honest ERROR and give up rather than spin.
    private func statusBarDidExit(_ proc: Process, status: Int32) {
        // Ignore stale notifications: only the currently-tracked companion
        // counts. Belt-and-suspenders against a late handler firing after a
        // newer instance was already spawned.
        guard proc === statusBarProcess else { return }
        statusBarProcess = nil
        statusBarRespawnCount += 1
        guard statusBarRespawnCount <= statusBarRespawnLimit else {
            trace.emit("app", "ERROR status-bar exited (status=\(status)) after \(statusBarRespawnLimit) respawns — giving up; menu-bar health icon unavailable for the rest of this run")
            return
        }
        trace.emit("app", "status-bar exited unexpectedly status=\(status) — respawning (\(statusBarRespawnCount)/\(statusBarRespawnLimit)) in 2s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.startStatusBar()
        }
    }

    private func stopStatusBar() {
        guard let proc = statusBarProcess, proc.isRunning else { return }
        trace.emit("app", "terminating status-bar pid=\(proc.processIdentifier)")
        // Deliberate stop: clear the crash-respawn handler FIRST so this
        // expected termination is never mistaken for a crash and respawned.
        proc.terminationHandler = nil
        proc.terminate()
        statusBarProcess = nil
    }

    private func locateStatusBarExecutable() -> URL? {
        locateCompanionExecutable(named: "SupervisorStatusBar")
    }

    /// Find a sibling companion executable next to this app's binary or in its
    /// Resources/ (build-app.sh lays both companions down in both spots). Shared
    /// by the heartbeat + status-bar spawns so the lookup rules stay identical.
    private func locateCompanionExecutable(named name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(name))
        }
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent().appendingPathComponent(name))
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Single-instance guard

    /// Hard single-instance guard. The OLD guard killed every sibling
    /// with a different pid, which made two app bundles sharing one
    /// bundle id ping-pong (A kills B, a relauncher starts B, B kills A,
    /// repeat). This flips the rule: a pidfile under appSupportDir is the
    /// source of truth, and if a LIVE incumbent already owns it the
    /// newcomer surfaces a clear error and quits. The incumbent keeps
    /// running. A stale pidfile (recorded pid dead, or it is us) does not
    /// block launch: we take over the lock.
    ///
    /// Returns true if this instance may continue (and has claimed the
    /// lock); false if it is a duplicate that has been told to quit.
    private func enforceSingleInstance() -> Bool {
        let pidfile = paths.pidfilePath
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Atomic claim (O_CREAT|O_EXCL) instead of read → decide → writePID:
        // closes the check-then-write TOCTOU where two near-simultaneous
        // launches both saw "no incumbent" and both entered the running state
        // (two hover bands, two engines). Exactly one racer wins the create.
        // The default probe (pidIsAliveSupervisor) also closes the PID-reuse
        // hole: a stale pid the OS reused for an unrelated process is verified
        // by executable identity, so it is NOT treated as an incumbent — a
        // legit launch takes over instead of quitting silently as a duplicate
        // of a stranger.
        switch SingleInstanceGuard.claim(at: pidfile, myPID: myPID) {
        case .incumbentAlive(let incumbentPID):
            return handleDuplicateLaunch(incumbentPID: incumbentPID, pidfile: pidfile, myPID: myPID)
        case .claimed:
            trace.emit("app", "single-instance: claimed lock at \(pidfile.path) pid=\(myPID)")
            return true
        }
    }

    /// A live incumbent holds the flock. Healthy incumbent: tell it to
    /// surface its UI and exit quietly (a second click on the app icon is
    /// never a silent no-op). Hung incumbent (stale/missing heartbeat, the
    /// "restart my laptop to open it" report): terminate it and take over —
    /// the user's launch intent wins over a wedged invisible process.
    /// Returns true only when this instance took over and now owns the lock.
    private func handleDuplicateLaunch(incumbentPID: Int32, pidfile: URL, myPID: Int32) -> Bool {
        func appAliveAge() -> TimeInterval? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: paths.appAlivePath.path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return Date().timeIntervalSince(mtime)
        }

        var decision = DuplicateLaunchPolicy.decide(appAliveAge: appAliveAge())
        if case .takeOver = decision {
            // Grace re-check: a winner that claimed the lock microseconds ago
            // touches the marker immediately after claiming, but this loser
            // may have raced ahead of that first write. Two seconds is orders
            // of magnitude more than the winner needs; a genuinely hung
            // incumbent is still hung after it.
            usleep(2_000_000)
            decision = DuplicateLaunchPolicy.decide(appAliveAge: appAliveAge())
        }

        switch decision {
        case .activateIncumbentAndQuit:
            trace.emit("app", "duplicate launch: incumbent pid=\(incumbentPID) alive (app-alive \(appAliveAge().map { String(Int($0)) } ?? "?")s); asking it to surface, then exiting")
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(DuplicateLaunchPolicy.activateNotification),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            quitAsDuplicate(incumbentPID: incumbentPID)  // never returns

        case .takeOver(let reason):
            // Identity check before signaling: never SIGTERM a pid we cannot
            // confirm is a Supervisor. If unverifiable, fall back to the old
            // quiet exit rather than risk killing a stranger.
            guard incumbentPID > 0, SingleInstanceGuard.pidIsAliveSupervisor(incumbentPID) else {
                trace.emit("app", "duplicate launch: takeover indicated (\(reason)) but incumbent pid=\(incumbentPID) is not a verifiable Supervisor; exiting instead")
                quitAsDuplicate(incumbentPID: incumbentPID)  // never returns
            }
            let msg = "duplicate launch: taking over from hung incumbent pid=\(incumbentPID) (\(reason))"
            trace.emit("app", msg)
            FileHandle.standardError.write(Data("Supervisor: \(msg)\n".utf8))
            if kill(incumbentPID, SIGTERM) != 0 {
                trace.emit("app", "takeover kill(SIGTERM) failed errno=\(errno) — falling through to the reclaim poll / stuck alert")
            }

            // The kernel releases the incumbent's flock the moment it dies;
            // poll the claim briefly rather than assuming timing.
            for _ in 0..<20 {  // up to ~5s
                usleep(250_000)
                if case .claimed = SingleInstanceGuard.claim(at: pidfile, myPID: myPID) {
                    trace.emit("app", "single-instance: reclaimed lock after takeover pid=\(myPID)")
                    return true
                }
            }

            // SIGTERM didn't free the lock (wedged with a handler installed).
            // Be loud and actionable instead of silently vanishing.
            trace.emit("app", "ERROR takeover failed: incumbent pid=\(incumbentPID) survived SIGTERM and still holds the lock")
            let alert = NSAlert()
            alert.messageText = "Supervisor is stuck"
            alert.informativeText = "A previous copy of Supervisor (process \(incumbentPID)) is running but not responding, and it wouldn't exit. Force-quit it in Activity Monitor (search for Supervisor), then open Supervisor again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            trace.sync()
            exit(1)
        }
    }

    /// A duplicate was launched while another instance already holds the lock.
    /// Exit IMMEDIATELY so this instance never reaches the running state and
    /// therefore never draws a second hover band or menu-bar item. The earlier
    /// version showed a blocking `alert.runModal()`, which left the duplicate
    /// parked on the modal loop, alive, instead of quitting: that was the
    /// two-bands bug. This instance owns no state to tear down (it never claimed
    /// the lock and never started the engine), so a hard `exit(0)` is correct
    /// and certain. No modal: a duplicate vanishes silently, the incumbent keeps
    /// running.
    private func quitAsDuplicate(incumbentPID: Int32) -> Never {
        let msg = "another Supervisor is already running (pid=\(incumbentPID)); this duplicate exits immediately"
        trace.emit("app", msg)
        // Also surface a one-line signal on stderr (Console.app / launchd log)
        // so a misfire — e.g. the identity check wrongly matching, or a genuine
        // double-launch — is visible without grepping the trace file. The
        // substantive PID-reuse fix is the identity-aware probe in the claim;
        // this is the belt-and-suspenders visibility the audit asked for.
        FileHandle.standardError.write(Data("Supervisor: \(msg)\n".utf8))
        trace.sync()
        exit(0)
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

    // MARK: - Menu-bar status item
    //
    // Intentionally NOT owned here. The menu-bar health icon lives in the
    // SupervisorStatusBar companion (spawned by startStatusBar), which polls
    // heartbeat.txt and shows red/amber/green + a working Restart / Quit
    // Supervisor / Open Trace Log. An in-process NSStatusItem could not survive
    // this app crashing (the icon would vanish rather than turn red) or report a
    // hang (a static green icon would keep lying), which is exactly the
    // honest-health regression the v0.3.0 fold-in introduced. The companion's
    // "Recent Flags / Open Recovery Folder / Open Trace Log" items replace the
    // in-process menu that used to live here.
}

// MARK: - QuestionAnswerer bootstrap helper

/// PRINCIPLES.md candidate locations, in priority order:
///   1. the user's own copy in Application Support. This is the file the
///      onboarding customization step points at, so edits there actually
///      take effect (it is checked FIRST, ahead of the bundled default).
///   2. the repo file, when a dev build runs in place from build/.
///   3. the generic default bundled inside the app (the safety-net fallback
///      a fresh install ships with).
/// compactMap drops the bundle URL on builds that do not embed the resource.
/// A user's edits always win over the bundled default; the bundled default
/// is what makes the answer + dispatch features work out of the box.
private func principlesCandidateURLs() -> [URL] {
    [
        ConfigPaths().appSupportDir.appendingPathComponent("PRINCIPLES.md"),
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PRINCIPLES.md"),
        Bundle.main.url(forResource: "PRINCIPLES", withExtension: "md"),
    ].compactMap { $0 }
}

/// Load PRINCIPLES.md (see principlesCandidateURLs for the priority order:
/// the user's Application Support copy, then the in-place repo file, then the
/// bundled generic default) and construct a `QuestionAnswerer`. Returns nil,
/// silently, if every candidate is missing or a stub; the engine treats nil
/// as "no secondary call," which degrades user_question_pending flags to plain
/// notify without breaking the primary triage path.
@MainActor
private func loadQuestionAnswerer(client: LLMClient, trace: TraceLog) -> QuestionAnswerer? {
    let candidates = principlesCandidateURLs()

    guard let resolved = PrinciplesResolver.resolve(
        candidates: candidates,
        read: { try? String(contentsOf: $0, encoding: .utf8) },
        onStub: { url, count in
            trace.emit("app", "PRINCIPLES candidate at \(url.path) is only \(count) chars (looks like a stub, below \(PrinciplesResolver.stubThreshold)); skipping")
        }
    ) else {
        trace.emit("app", "no real PRINCIPLES.md found (all candidates missing or stub); QuestionAnswerer disabled — user_question_pending flags will surface as plain notify")
        return nil
    }
    trace.emit("app", "loaded PRINCIPLES.md for QuestionAnswerer from \(resolved.path.path) (\(resolved.text.count) chars)")
    return QuestionAnswerer(client: client, principlesText: resolved.text, trace: trace)
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
    let candidates = principlesCandidateURLs()

    guard let resolved = PrinciplesResolver.resolve(
        candidates: candidates,
        read: { try? String(contentsOf: $0, encoding: .utf8) },
        onStub: { url, count in
            trace.emit("app", "PRINCIPLES candidate at \(url.path) is only \(count) chars (looks like a stub, below \(PrinciplesResolver.stubThreshold)); skipping")
        }
    ) else {
        trace.emit("app", "no real PRINCIPLES.md found (all candidates missing or stub); Dispatcher disabled — worker_idle_post_completion flags will surface as plain notify (no auto-dispatch)")
        return nil
    }
    trace.emit("app", "loaded PRINCIPLES.md for Dispatcher from \(resolved.path.path) (\(resolved.text.count) chars)")
    return Dispatcher(
        client: client,
        principlesText: resolved.text,
        principlesPath: resolved.path,
        issueFetcher: GitHubIssueFetcher(trace: trace),
        commitFetcher: GitBranchCommitFetcher(trace: trace),
        prFetcher: GitHubPRFetcher(trace: trace),
        dispatchHistory: dispatchHistory,
        grounder: RepoProposalGrounder(trace: trace),
        trace: trace
    )
}

/// v0.2.0 M2d-2: build the Planner/Evaluator harness driver, or nil if the
/// PlanStore / PRINCIPLES.md aren't available. Always constructed when possible;
/// it is INERT until the owner flips the planner-enabled marker on (the
/// RuntimeToggles.plannerEnabled opt-in gate), so wiring it in changes no default
/// behavior. The Planner mirrors the Dispatcher's grounding (same fetchers +
/// grounder); the Evaluator inherits the shared client's redaction.
private func loadPlanLoop(
    client: LLMClient,
    planStore: PlanStore?,
    loopController: LoopController,
    dispatchHistory: (any DispatchHistoryReading)? = nil,
    auditStore: AuditStore? = nil,
    trace: TraceLog
) -> PlanLoop? {
    guard let planStore else {
        trace.emit("app", "no PlanStore; PlanLoop disabled (planner harness unavailable)")
        return nil
    }
    let candidates = principlesCandidateURLs()

    guard let resolved = PrinciplesResolver.resolve(
        candidates: candidates,
        read: { try? String(contentsOf: $0, encoding: .utf8) },
        onStub: { url, count in
            trace.emit("app", "PRINCIPLES candidate at \(url.path) is only \(count) chars (looks like a stub, below \(PrinciplesResolver.stubThreshold)); skipping")
        }
    ) else {
        trace.emit("app", "no real PRINCIPLES.md found (all candidates missing or stub); PlanLoop disabled (planner harness unavailable)")
        return nil
    }
    let planner = Planner(
        client: client,
        store: planStore,
        principlesText: resolved.text,
        principlesPath: resolved.path,
        issueFetcher: GitHubIssueFetcher(trace: trace),
        commitFetcher: GitBranchCommitFetcher(trace: trace),
        dispatchHistory: dispatchHistory,
        grounder: RepoProposalGrounder(trace: trace),
        trace: trace
    )
    // v0.2.0 (Reddit feedback E): the Evaluator pass threshold follows
    // the owner's decision-sensitivity setting. At .balanced (the
    // default) this resolves to 0.8 == Evaluator.defaultThreshold, so
    // the grader is unchanged unless the owner moves the dial; Cautious
    // raises the bar (redirect/retry more), Decisive lowers it.
    let evaluator = Evaluator(
        client: client,
        store: planStore,
        threshold: DecisionSensitivityStore.current().evaluatorPassThreshold,
        trace: trace
    )
    trace.emit("app", "PlanLoop ready (planner harness wired, INERT until planner-enabled marker is set) PRINCIPLES from \(resolved.path.path)")
    return PlanLoop(
        planner: planner,
        evaluator: evaluator,
        planStore: planStore,
        loopController: loopController,
        auditStore: auditStore,
        trace: trace
    )
}

// MARK: - Bootstrap

// --print-paths: the E2E harness's PRE-LAUNCH gate. Prints where this binary
// would put its world and exits before NSApplication (or anything with side
// effects — no trace file, no dirs, no keychain, no single-instance claim)
// spins up. The harness runs this FIRST and refuses to launch unless the
// output shows the fake home and a non-live keychain base: an abort-gate
// that only greps the post-launch trace can't stop a STALE binary that
// predates the seams from booting against the real home — where the
// duplicate-launch takeover path could SIGTERM the live Supervisor. Echoes
// the RESOLVED values (same rationale as the running-state ready line).
if CommandLine.arguments.contains("--print-paths") {
    let paths = ConfigPaths()
    print("home=\(paths.home.path)")
    print("keychainBase=\(LLMProvider.keychainServiceBase)")
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = SupervisorAppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

// MARK: - Notification response handling (Context Health + flag banners)

/// Opens the Context Health window when the owner taps the one earned nudge (or
/// its "Show me" action), and — issue #60 follow-up — records an EXPLICIT flag-
/// banner dismissal as `flags.user_response = dismissed`. The flag category
/// requests `.customDismissAction`, so a swiped-away banner arrives here as
/// UNNotificationDismissActionIdentifier with the flag row id in userInfo.
/// Honesty rule: only the unambiguous dismiss is recorded — a plain tap
/// (default action) opens the app, which is engagement, not approval, so it is
/// deliberately NOT written. The write goes through markUserResponseIfUnset so
/// a banner dismissal never overwrites an explicit panel response. `nonisolated`
/// + hop-to-MainActor is the standard way to satisfy the SDK's nonisolated
/// delegate requirement from a main-actor app delegate (PR #45's pattern).
extension SupervisorAppDelegate: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if content.categoryIdentifier == Notifier.contextHealthCategoryID {
            Task { @MainActor in self.openContextHealthWindow?() }
        } else if content.categoryIdentifier == Notifier.flagCategoryID,
                  response.actionIdentifier == UNNotificationDismissActionIdentifier,
                  let flagId = content.userInfo[Notifier.flagIdUserInfoKey] as? String {
            Task { @MainActor in
                guard let store = self.flagStore else { return }
                do {
                    try store.markUserResponseIfUnset(flagId: flagId, response: .dismissed)
                    self.trace.emit("app", "flag banner dismissed -> user_response=dismissed (if unset) flagId=\(flagId)")
                } catch {
                    self.trace.emit("app", "ERROR flag banner dismiss persist failed flagId=\(flagId): \(error)")
                }
            }
        }
        completionHandler()
    }
}
