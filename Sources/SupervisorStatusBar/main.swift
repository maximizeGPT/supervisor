// SupervisorStatusBar — companion menu-bar process.
//
// Reads the heartbeat file every 2s and sets the menu-bar icon color based on
// heartbeat freshness:
//   fresh (< 10s)  → green  "Supervisor: running"
//   stale (10-30s) → amber  "Supervisor: heartbeat stale"
//   stale (> 30s)  → red    "Supervisor: disconnected"
//
// WHY THIS IS A SEPARATE PROCESS (the honest-health guarantee): the icon MUST
// survive a crash of the main app. If the menu-bar item lived inside
// SupervisorApp (as it briefly did in the v0.3.0 RC fold-in), a crash of the
// main process takes the NSStatusItem down with it — the icon vanishes rather
// than turning red, and a HUNG (not crashed) engine keeps a static green icon
// forever because nothing re-reads liveness. Out-of-process + heartbeat-driven
// is the only design where a dead/hung supervisor honestly shows red/amber.
//
// This process does no LLM calls and no file tailing — its only job is
// reporting whether the supervisor stack is alive, and offering the two
// remedies that actually help when it is not: Restart and Open Trace Log.

import AppKit
import Darwin  // POSIX kill/errno/ESRCH for the authoritative pid-liveness probe
import Foundation
import SupervisorCore
import SupervisorUI

let paths = ConfigPaths()
try paths.ensureDirectoriesExist()

let trace = TraceLog(path: paths.traceLogPath)
let heartbeat = HeartbeatFile(path: paths.heartbeatPath)
// FIX 4: the ENGINE-liveness token, written by the main app's TriageEngine on
// each run-loop tick. Read alongside the process heartbeat so a hung engine
// (fresh process beat, stale engine token) shows amber/red — see evaluate below.
let engineProgress = HeartbeatFile(path: paths.engineProgressPath)

trace.emit("statusbar", "boot pid=\(ProcessInfo.processInfo.processIdentifier) heartbeat=\(paths.heartbeatPath.path)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar-only; no dock icon

// MARK: - Branded-asset lookup (non-trapping Bundle.module replacement)

/// Name of the resource bundle SwiftPM synthesizes for this target's
/// `resources:` declaration (PackageName_TargetName.bundle).
let statusBarResourceBundleName = "Supervisor_SupervisorStatusBar.bundle"

/// Candidate directories that may contain the resource bundle, in priority
/// order. Mirrors the locations the SwiftPM-synthesized `Bundle.module`
/// accessor probes (Bundle.main resourceURL / bundleURL), plus the two
/// layouts this companion actually ships in:
///   - dev: bare binary in .build/<config>/ with the bundle sitting next
///     to it (covered by bundleURL and the executable's directory)
///   - packaged: binary in Supervisor.app/Contents/MacOS/, bundle in
///     Contents/Resources/ (laid down by Scripts/build-app.sh; covered by
///     resourceURL and the executable-relative ../Resources probe, so the
///     lookup works even if Bundle.main fails to infer the enclosing .app)
/// A pure function over its inputs so the search order stays explicit and
/// hand-verifiable (this executable target has no test target).
func resourceBundleCandidateDirectories(
    resourceURL: URL?,
    bundleURL: URL,
    executableURL: URL?
) -> [URL] {
    var dirs: [URL] = []
    if let resourceURL {
        dirs.append(resourceURL)
    }
    dirs.append(bundleURL)
    if let execDir = executableURL?.deletingLastPathComponent() {
        dirs.append(execDir)
        dirs.append(
            execDir
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
        )
    }
    return dirs
}

/// The resolved resource bundle, or nil when it is absent. CRITICAL: this
/// must never trap. The synthesized `Bundle.module` accessor calls
/// fatalError when Supervisor_SupervisorStatusBar.bundle is missing — which
/// is exactly the packaged-app case if the bundle was not copied into
/// Contents/Resources/ — and a fatalError here kills the ONE process whose
/// whole job is surviving failures elsewhere. A missing bundle only means
/// "no branded icon": configureButton falls back to SF Symbols.
let statusBarResourceBundle: Bundle? = {
    for dir in resourceBundleCandidateDirectories(
        resourceURL: Bundle.main.resourceURL,
        bundleURL: Bundle.main.bundleURL,
        executableURL: Bundle.main.executableURL
    ) {
        let candidate = dir.appendingPathComponent(statusBarResourceBundleName, isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path),
           let bundle = Bundle(url: candidate) {
            return bundle
        }
    }
    return nil
}()

if let resolved = statusBarResourceBundle {
    trace.emit("statusbar", "branded resource bundle resolved: \(resolved.bundlePath)")
} else {
    trace.emit("statusbar", "branded resource bundle not found — SF Symbol fallback in use")
}

/// Branded-image lookup that degrades to nil (→ SF Symbol fallback at the
/// call site) instead of trapping when the resource bundle is missing.
func brandedImage(named name: String) -> NSImage? {
    statusBarResourceBundle?.image(forResource: name)
}

extension HeartbeatHealth {
    /// SF-symbol fallback name. Used for amber/red since "warning triangle"
    /// and "error octagon" carry stronger universal semantics than the brand
    /// mark would. The healthy state uses the branded V1 symbol (see
    /// `brandedImageName`) rather than this fallback.
    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "xmark.octagon.fill"
        }
    }
    /// Branded asset name in Resources/. Currently only the healthy state has a
    /// brand-mark image; amber/red fall back to SF Symbols. nil = "use the SF
    /// Symbol".
    var brandedImageName: String? {
        switch self {
        case .green: return "StatusBarIcon"
        case .amber, .red: return nil
        }
    }
    var menuTitle: String {
        switch self {
        case .green: return "Supervisor: running"
        case .amber: return "Supervisor: heartbeat stale"
        case .red(let r): return "Supervisor: \(r)"
        }
    }
    // Plain-text fallback when both the branded asset and the SF Symbol are
    // unavailable (very early boot, or a Resources-stripped build). The
    // button.title is always set so something visible is in the menu bar even
    // if image rendering fails.
    var fallbackLabel: String {
        switch self {
        case .green: return "●"
        case .amber: return "⚠"
        case .red:   return "✕"
        }
    }
}

final class StatusBarController: NSObject {

    /// Bundle id of the MAIN Supervisor.app — the process this companion can
    /// quit / restart. Mirrors the id the app's own single-instance guard and
    /// signing identity use (live.supervisor.app).
    private let mainBundleID = "live.supervisor.app"

    private let statusItem: NSStatusItem
    private var current: HeartbeatHealth = .red(reason: "starting")
    /// True while the owner has globally PAUSED Supervisor. A live-but-paused
    /// process must NOT read as green "running" — paused is a deliberate "not
    /// watching", shown with a distinct pause glyph + tooltip.
    private var paused = false
    private var timer: DispatchSourceTimer?

    /// True only when the process is alive (green heartbeat) and the owner has
    /// paused. A dead/stale heartbeat (the bigger truth) outranks paused.
    private var isPausedDisplay: Bool {
        if case .green = current, paused { return true }
        return false
    }

    private var displayTitle: String {
        if case .green = current, paused { return "Supervisor: paused (not watching)" }
        return current.menuTitle
    }

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        configureButton()
        rebuildMenu()
        startPolling()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        // Paused gets its own pause glyph + tooltip — distinct from the amber
        // "warning" (something is wrong) and the green "all clear". A pause icon
        // reads as an intentional, benign off-state.
        if isPausedDisplay {
            button.title = "⏸"
            button.image = NSImage(
                systemSymbolName: "pause.circle.fill",
                accessibilityDescription: "Supervisor paused"
            )
            button.toolTip = displayTitle
            return
        }

        button.title = current.fallbackLabel

        // Prefer the branded V1 symbol when one is wired up for this state. The
        // Resources/ PNG is loaded via the non-trapping brandedImage resolver
        // above (NOT the synthesized Bundle.module accessor, which fatalErrors
        // when the resource bundle is missing — e.g. a packaged build that did
        // not embed it); mark template = true so the menu-bar foreground color
        // is applied automatically (light vs dark mode). If the asset lookup
        // fails for any reason (resource stripped, bundle missing), fall
        // through to the SF Symbol so we never go iconless — and never crash.
        if let assetName = current.brandedImageName,
           let branded = brandedImage(named: assetName) {
            branded.isTemplate = true
            button.image = branded
        } else {
            button.image = NSImage(
                systemSymbolName: current.symbolName,
                accessibilityDescription: "Supervisor"
            )
        }
        button.toolTip = displayTitle
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: displayTitle, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Context Health: audit this machine's Claude context setup (CLAUDE.md /
        // skills / commands) and open the Context Health window with the results.
        // Non-destructive: it only recommends; nothing is changed without sign-off.
        let contextHealth = NSMenuItem(
            title: "Context Health…",
            action: #selector(openContextHealth),
            keyEquivalent: ""
        )
        contextHealth.target = self
        menu.addItem(contextHealth)
        menu.addItem(NSMenuItem.separator())

        if case .red = current {
            // The red state is EXACTLY when the user needs a working remedy:
            // relaunch Supervisor, and read the trace log to see why it died.
            let restart = NSMenuItem(
                title: "Restart Supervisor",
                action: #selector(restartMain),
                keyEquivalent: ""
            )
            restart.target = self
            menu.addItem(restart)
            let openLogRemedy = NSMenuItem(
                title: "Open Trace Log",
                action: #selector(openTraceLog),
                keyEquivalent: ""
            )
            openLogRemedy.target = self
            menu.addItem(openLogRemedy)
            menu.addItem(NSMenuItem.separator())
        }
        // A persistent-history surface for past flags: dumps the last 20 rows
        // from the `flags` table as pretty-printed JSON to /tmp and reveals the
        // file in Finder. JSON over SQLite because it is human-readable without
        // installing anything.
        let recentFlags = NSMenuItem(
            title: "Recent Flags…",
            action: #selector(openRecentFlags),
            keyEquivalent: ""
        )
        recentFlags.target = self
        menu.addItem(recentFlags)

        // Reveal the recovery-doc directory (handoff markdown from pause/kill).
        let openRecovery = NSMenuItem(
            title: "Open Recovery Folder",
            action: #selector(openRecoveryFolder),
            keyEquivalent: ""
        )
        openRecovery.target = self
        menu.addItem(openRecovery)

        let openLog = NSMenuItem(
            title: "Open Trace Log",
            action: #selector(openTraceLog),
            keyEquivalent: ""
        )
        openLog.target = self
        menu.addItem(openLog)

        menu.addItem(NSMenuItem.separator())
        // A working "Quit Supervisor" that actually stops the harness. Because
        // the main app is .accessory (no Dock, no menu), this companion is the
        // only place a user can honestly quit — so it must terminate the main
        // app (which tears down the triage engine, discovery, and the heartbeat
        // child), then terminate this process. Quitting just the icon would
        // leave the main app running and spending.
        let quitSupervisorItem = NSMenuItem(
            title: "Quit Supervisor",
            action: #selector(quitSupervisor),
            keyEquivalent: "q"
        )
        quitSupervisorItem.target = self
        menu.addItem(quitSupervisorItem)
        // An explicit "just this icon" escape hatch, clearly labelled so it is
        // never mistaken for stopping supervision.
        let quitItem = NSMenuItem(
            title: "Quit Status Bar Only",
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func startPolling() {
        let q = DispatchQueue(label: "supervisor.statusbar.poll")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        self.timer = t
    }

    private func tick() {
        // Parent-liveness, same rule as the heartbeat child: spawned as a
        // direct child of Supervisor.app, so a dead/killed parent reparents
        // us to launchd (getppid()==1). Without this, a taken-over or
        // SIGKILLed main app leaves an orphaned second menu-bar icon that
        // reads the NEW instance's heartbeat, shows green, and whose Quit
        // targets the wrong process. Exit; the replacement instance spawns
        // its own icon.
        if getppid() == 1 {
            trace.emit("statusbar", "parent gone (getppid=1) — exiting so a replacement instance owns the icon")
            trace.sync()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        let age = (try? heartbeat.ageSeconds()) ?? .infinity
        // FIX 4: fold in the engine-progress token. A read failure or a missing
        // file both surface as .infinity → engine-stale, so a live process over a
        // hung (or never-started) engine can never read green. The main app writes
        // this file from the engine's run-loop tick before spawning this companion,
        // so in a healthy run it is always present and fresh.
        let engineAge = (try? engineProgress.ageSeconds()) ?? .infinity
        let new = HeartbeatHealth.evaluate(age: age, engineAge: engineAge)
        // The global-pause marker is owner-facing state the status bar must
        // reflect honestly — a paused engine is not "running/all clear".
        let newPaused = RuntimeToggles.supervisorPaused
        if new != current || newPaused != paused {
            current = new
            paused = newPaused
            trace.emit("statusbar", "health -> \(displayTitle)")
            DispatchQueue.main.async { [weak self] in
                self?.configureButton()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: - Actions

    @objc private func quit() {
        trace.emit("statusbar", "quit status-bar only requested by user")
        NSApp.terminate(nil)
    }

    /// Stop the WHOLE harness. Terminate the main Supervisor.app (its
    /// applicationWillTerminate tears down the triage engine, discovery, and the
    /// heartbeat child), then terminate this companion.
    @objc private func quitSupervisor() {
        trace.emit("statusbar", "quit-supervisor requested — terminating main app + self")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID)
        for app in running {
            trace.emit("statusbar", "terminating main app pid=\(app.processIdentifier)")
            app.terminate()
        }
        // Give the main app a moment to run its teardown before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// A working Restart. The flagship failure this remedy exists for is a
    /// HUNG-but-alive main app (wedged MainActor): the red icon is showing
    /// precisely because the engine-progress token went stale while the process
    /// is still alive. `terminate()` alone is a POLITE quit AppleEvent that the
    /// target's main run loop must process — a hung app never does, so it
    /// no-ops and the corpse stays alive. If we then relaunched, the new
    /// instance's SingleInstanceGuard would see the still-alive pid and bow out
    /// silently as a duplicate, leaving the user's only remedy doing nothing.
    ///
    /// So: terminate politely, VERIFY the incumbent actually died (bounded poll),
    /// escalate to `forceTerminate()` (SIGKILL-equivalent, needs no cooperation
    /// from the wedged thread) if it is still alive, and relaunch ONLY after the
    /// old instance is confirmed gone. If even a force-terminate can't clear it
    /// (e.g. an EPERM permission edge), surface an honest error rather than
    /// relaunching into a guaranteed duplicate-bow-out.
    @objc private func restartMain() {
        trace.emit("statusbar", "restart-supervisor requested")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID)
        let bundleURL = running.first?.bundleURL ?? siblingMainAppURL()
        guard let url = bundleURL else {
            trace.emit("statusbar", "restart: no Supervisor.app URL found — cannot relaunch")
            return
        }
        // Do the terminate → verify → relaunch off the main thread. Two reasons:
        // (1) the verification uses short polled waits, which must never freeze
        // the menu bar's run loop; (2) keeping the main run loop free lets it
        // deliver the app-termination notifications that flip
        // NSRunningApplication.isTerminated. This replaces the old fixed 1.0s
        // main-queue delay, which never checked whether the app actually exited.
        let targets = running
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.terminateThenRelaunch(targets: targets, url: url)
        }
    }

    /// Confirm every incumbent is truly gone, then relaunch the sibling bundle.
    /// Runs on a background queue. Crash case (no running app) → straight to
    /// relaunch. Runs synchronously here because it is already off-main.
    private func terminateThenRelaunch(targets: [NSRunningApplication], url: URL) {
        // Crash / never-running case: nothing to kill, just launch the sibling.
        guard targets.isEmpty == false else {
            relaunchMain(url: url)
            return
        }
        var allGone = true
        for app in targets where ensureTerminated(app) == false {
            allGone = false
        }
        guard allGone else {
            // At least one incumbent survived even a force-terminate. Relaunching
            // now would just hand the new instance's single-instance guard a live
            // pid to bow out to — so report honestly and do NOT relaunch.
            trace.emit("statusbar", "restart: ERROR incumbent still alive after forceTerminate — NOT relaunching (would bow out to the corpse). Manual intervention needed.")
            return
        }
        relaunchMain(url: url)
    }

    /// Politely terminate `app`, then verify. Escalate to `forceTerminate()` if
    /// the target (e.g. a wedged MainActor that never processes the polite quit)
    /// is still alive after a bounded grace. Returns true only once the process
    /// is CONFIRMED gone.
    private func ensureTerminated(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        trace.emit("statusbar", "restart: terminating main app pid=\(pid)")
        _ = app.terminate()  // polite quit AppleEvent; a hung app will ignore it
        if waitUntilGone(app, timeout: 1.5) {
            trace.emit("statusbar", "restart: pid=\(pid) exited after polite terminate")
            return true
        }
        trace.emit("statusbar", "restart: pid=\(pid) still alive after terminate — escalating to forceTerminate")
        _ = app.forceTerminate()  // SIGKILL-equivalent; needs no target cooperation
        if waitUntilGone(app, timeout: 1.5) {
            trace.emit("statusbar", "restart: pid=\(pid) exited after forceTerminate")
            return true
        }
        trace.emit("statusbar", "restart: pid=\(pid) STILL alive after forceTerminate")
        return false
    }

    /// Poll up to `timeout` for the target to disappear. Considers it gone when
    /// NSRunningApplication reports `isTerminated`, OR when the kernel no longer
    /// knows its pid. The kill(pid,0) probe is authoritative and independent of
    /// notification delivery; isTerminated is a fast path once the workspace
    /// notification lands. Polls in 0.1s slices so the wait is strictly bounded.
    private func waitUntilGone(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let pid = app.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.isTerminated { return true }
            if pidIsGone(pid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return app.isTerminated || pidIsGone(pid)
    }

    /// Authoritative liveness probe, mirroring SingleInstanceGuard.pidIsAlive:
    /// `kill(pid, 0)` == 0 means the process exists and we may signal it; ESRCH
    /// means no such process (gone). EPERM means it exists but is owned by
    /// another user — treated as STILL ALIVE (not gone) so we never relaunch
    /// over a process we merely failed to reach.
    private func pidIsGone(_ pid: pid_t) -> Bool {
        if pid <= 0 { return true }
        if kill(pid, 0) == 0 { return false }  // signallable → alive
        return errno == ESRCH                   // ESRCH → gone; EPERM → still alive
    }

    /// Relaunch a fresh main instance from `url`. Called only after the old
    /// instance is confirmed gone, so the new instance's single-instance guard
    /// has no live incumbent to bow out to.
    private func relaunchMain(url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
            if let error = error {
                trace.emit("statusbar", "restart: relaunch failed: \(error)")
            } else {
                trace.emit("statusbar", "restart: relaunched main app pid=\(app?.processIdentifier ?? -1)")
            }
        }
    }

    /// Sibling Supervisor.app next to this companion. Both bundles ship side by
    /// side (dragged from the DMG to /Applications; both under build/ in dev),
    /// so the parent of this bundle contains the main app.
    private func siblingMainAppURL() -> URL? {
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Supervisor.app")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    @objc private func openTraceLog() {
        NSWorkspace.shared.open(paths.traceLogPath)
    }

    /// Open the Context Health window (Context Wiki). Menu actions run on the main
    /// thread, so `assumeIsolated` is valid; the window + audit are constructed
    /// on demand so the always-present status icon stays light until asked.
    @objc private func openContextHealth() {
        trace.emit("statusbar", "context health requested")
        MainActor.assumeIsolated {
            let root = paths.home.appendingPathComponent(".claude/skills", isDirectory: true)
            let store: ContextAuditStore? = {
                try? paths.ensureDirectoriesExist()
                guard let db = try? SupervisorDatabase(path: paths.databasePath) else { return nil }
                return ContextAuditStore(database: db)
            }()
            ContextHealthPresenter.shared.present(root: root, store: store)
        }
    }

    /// Reveal the recovery-doc directory in Finder. Creates the directory first
    /// if it does not exist yet (typical on a clean install before any
    /// pause/kill has fired), so the user does not see a Finder error.
    @objc private func openRecoveryFolder() {
        try? FileManager.default.createDirectory(at: paths.recoveryDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.recoveryDir])
        trace.emit("statusbar", "open recovery folder requested → \(paths.recoveryDir.path)")
    }

    /// Write the last 20 `flags` rows to a pretty-printed JSON file under /tmp
    /// and reveal it in Finder. Each invocation gets its own timestamped file so
    /// repeated clicks do not overwrite a file the user might be inspecting.
    @objc private func openRecentFlags() {
        trace.emit("statusbar", "recent flags requested")
        let db: SupervisorDatabase
        do {
            db = try SupervisorDatabase(path: paths.databasePath)
        } catch {
            trace.emit("statusbar", "ERROR open DB for recent-flags failed: \(error)")
            return
        }
        let flagStore = FlagStore(database: db)
        let flags = (try? flagStore.recent(limit: 20)) ?? []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(flags)
        } catch {
            trace.emit("statusbar", "ERROR encode flags as JSON failed: \(error)")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let path = "/tmp/supervisor-recent-flags-\(stamp).json"
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            trace.emit("statusbar", "recent flags exported \(flags.count) rows → \(path)")
        } catch {
            trace.emit("statusbar", "ERROR write recent flags failed: \(error)")
        }
    }
}

// (ContextHealthPresenter moved to SupervisorUI so the status bar, the main app's
// panel line, and the notification all share one window presenter.)

// Wire it up.
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let controller = StatusBarController(statusItem: statusItem)
_ = controller  // keep alive

app.run()
