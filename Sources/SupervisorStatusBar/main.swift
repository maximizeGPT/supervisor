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
// It carries ONE sanctioned network path: on a health transition (engine
// stopped / hung / recovered) it delivers a page through the owner's remote
// escalation webhook, because the dead main app cannot page about its own
// death and this companion is the survivor. See deliverHealthPage and the
// Package.swift build-graph note.

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
    /// Remote-page transition ledger (CompanionHealthPager). Fed every poll
    /// tick; pages the owner's webhook on sustained red, on a >2min degraded
    /// run, and once on recovery. Lives here (not in the main app) because
    /// the main app cannot page about its own death — this companion is the
    /// survivor. Touched only on the poll queue.
    private var pagerState = CompanionHealthPager.State()
    /// When the previous poll tick ran. A gap far past the 2s cadence means
    /// the machine slept, and every wall-clock age is briefly a lie.
    private var lastTickAt: Date?
    /// Verdicts are held until this deadline after a detected wake, so the
    /// heartbeat writers can catch up before anything is called stopped.
    private var wakeSuppressUntil: Date?
    /// The ONE long-lived notifier every health page rides (C2c). One
    /// instance, not one per page: its in-flight reservation and per-kind
    /// dedupe stamps only work if consecutive pages share them.
    private var healthNotifier: RemoteNotifier?
    /// Tail of the strictly-serial delivery chain: each page's Task awaits
    /// the previous one, so "recovered" can never overtake "stopped" no
    /// matter how the transport retries land.
    private var deliveryChain: Task<Void, Never>?
    /// True while the owner has globally PAUSED Supervisor. A live-but-paused
    /// process must NOT read as green "running" — paused is a deliberate "not
    /// watching", shown with a distinct pause glyph + tooltip.
    private var paused = false
    private var timer: DispatchSourceTimer?
    /// The poll queue. Held so boot work (the webhook cache warm-up) can be
    /// serialized ahead of the first tick.
    private var pollQueue: DispatchQueue?
    /// Webhook URL cache, warmed once on the poll queue before the first
    /// tick. The Keychain item was written by a DIFFERENT binary (the main
    /// app), so this process's first read can raise a SecurityAgent prompt —
    /// acceptable at boot (launch and onboarding happen with the owner
    /// present), never acceptable on the reparent-death exit path, where a
    /// prompt would block the page AND the exit. Death paging reads only
    /// this cache. Touched only on the poll queue.
    private var cachedWebhookRaw: String?
    private var webhookCacheWarmed = false
    /// Poll ticks since boot; every 150th (~5 minutes at the 2s cadence)
    /// kicks a cache refresh so a webhook stored or rotated while the
    /// companion runs reaches it without a relaunch. The Keychain read runs
    /// on a utility queue and only its RESULT hops back to the poll queue,
    /// so a slow or prompting read can never stall a tick.
    private var tickCount = 0
    private var webhookRefreshInFlight = false
    /// One-shot guard for the startup recovery check. Set only when the check
    /// actually RUNS, not merely when the first green tick arrives.
    private var startupRecoveryChecked = false
    /// Green ticks spent waiting for the webhook cache to resolve before
    /// startup recovery consumes its markers. Bounded by
    /// `CompanionHealthPager.startupRecoveryMaxWaitTicks`.
    private var greenTicksAwaitingRecovery = 0

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
        self.pollQueue = q
        // Warm the webhook cache BEFORE the timer starts: the queue is
        // serial, so this runs ahead of the first tick, and a death on the
        // very first tick already has a cache to page from.
        q.async { [weak self] in self?.warmWebhookCache() }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        self.timer = t
    }

    /// How long the boot warm may hold the poll queue. Long enough for a
    /// slow Keychain, far short of forever: the cross-binary read can raise
    /// a SecurityAgent prompt, and an owner who is AWAY (a respawned
    /// companion after a crash) never answers it.
    private let webhookWarmTimeout: TimeInterval = 10
    /// One Keychain read at boot, BOUNDED. See `cachedWebhookRaw`. The read
    /// itself runs on a utility queue and its result hops back to the poll
    /// queue (same pattern as `refreshWebhookCacheAsync`); this poll-queue
    /// slot waits at most `webhookWarmTimeout` for it. If the read is stuck
    /// behind a Keychain prompt nobody is present to answer, the first tick
    /// proceeds with an empty cache — the hop-back still lands whenever the
    /// read returns, and the 5-minute refresh covers the rest. The first
    /// tick must never be delayed unboundedly.
    private func warmWebhookCache() {
        let queue = pollQueue
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var readValue: String?
            var readSucceeded = true
            do {
                readValue = try KeychainRemoteNotifyURLStore().read()
            } catch {
                // The error is never traced: Keychain errors can quote the
                // item, and the URL is a bearer credential (same as the app).
                readSucceeded = false
            }
            semaphore.signal()
            queue?.async {
                guard let self else { return }
                self.webhookCacheWarmed = true
                if !readSucceeded {
                    trace.emit("statusbar", "webhook cache warm-up failed: keychain read error")
                }
                self.cachedWebhookRaw = CompanionHealthPager.refreshedWebhookCache(
                    readSucceeded: readSucceeded, readValue: readValue, current: self.cachedWebhookRaw
                )
                trace.emit("statusbar", "webhook cache warmed stored=\(self.cachedWebhookRaw?.isEmpty == false)")
                // A late warm (past the bound below) may arrive after pages
                // already rode an endpoint-less notifier: complete it live,
                // same rule as the periodic refresh.
                if let raw = self.cachedWebhookRaw,
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let endpoint = try? RemoteWebhookURL(validating: raw) {
                    self.healthNotifier?.apply(endpoint: endpoint)
                }
            }
        }
        if semaphore.wait(timeout: .now() + webhookWarmTimeout) == .timedOut {
            trace.emit("statusbar", "webhook cache warm-up exceeded \(Int(webhookWarmTimeout))s (keychain prompt?) — first tick proceeds without it")
        }
    }

    /// Periodic cache refresh (C3a). The read happens on a utility queue —
    /// never on the poll queue, whose 2s tick must stay prompt-proof — and
    /// only the result hops back to update the cache and complete the
    /// long-lived notifier's endpoint live. A FAILED read keeps the current
    /// cache (a transient Keychain error must not wipe a working URL); a
    /// successful nil replaces it (the owner deleted the URL, and the cache
    /// must not resurrect it for the death page).
    private func refreshWebhookCacheAsync() {
        guard !webhookRefreshInFlight else { return }
        webhookRefreshInFlight = true
        let queue = pollQueue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var readValue: String?
            var readSucceeded = true
            do {
                readValue = try KeychainRemoteNotifyURLStore().read()
            } catch {
                // Never trace the error: Keychain errors can quote the item.
                readSucceeded = false
            }
            queue?.async {
                guard let self else { return }
                self.webhookRefreshInFlight = false
                // A refresh that came back is a resolved cache too, whatever
                // happened to the boot warm. Startup recovery waits on this
                // flag, so a warm stuck behind a Keychain prompt must not be
                // the only thing that can ever set it.
                self.webhookCacheWarmed = true
                let old = self.cachedWebhookRaw
                self.cachedWebhookRaw = CompanionHealthPager.refreshedWebhookCache(
                    readSucceeded: readSucceeded, readValue: readValue, current: old
                )
                guard self.cachedWebhookRaw != old else { return }
                trace.emit("statusbar", "webhook cache refreshed stored=\(self.cachedWebhookRaw?.isEmpty == false)")
                // Complete or update the running notifier. apply(endpoint:)
                // only takes a valid URL; a now-empty cache leaves the old
                // endpoint in place, and the config switch stays the off
                // ramp for an owner tearing the channel down.
                if let raw = self.cachedWebhookRaw,
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let endpoint = try? RemoteWebhookURL(validating: raw) {
                    self.healthNotifier?.apply(endpoint: endpoint)
                }
            }
        }
    }

    private func tick() {
        // Parent-liveness, same rule as the heartbeat child: spawned as a
        // direct child of Supervisor.app, so a dead/killed parent reparents
        // us to launchd (getppid()==1). Without this, a taken-over or
        // SIGKILLed main app leaves an orphaned second menu-bar icon that
        // reads the NEW instance's heartbeat, shows green, and whose Quit
        // targets the wrong process. Exit — but reparenting is ALSO the
        // definitive "the app died" signal, and it lands within 2s, long
        // before heartbeat staleness (30s) could page. So an unexpected
        // death pages once on the way out (deploys, which pkill on purpose,
        // are exempted by their marker); see handleParentDeath.
        if getppid() == 1 {
            handleParentDeath()
            return
        }
        // C3a: keep the boot-warmed webhook cache fresh off the page path,
        // so page time (and the reparent exit path) only ever reads memory.
        tickCount += 1
        if tickCount % 150 == 0 { refreshWebhookCacheAsync() }
        let age = (try? heartbeat.ageSeconds()) ?? .infinity
        // FIX 4: fold in the engine-progress token. A read failure or a missing
        // file both surface as .infinity → engine-stale, so a live process over a
        // hung (or never-started) engine can never read green. The main app writes
        // this file from the engine's run-loop tick before spawning this companion,
        // so in a healthy run it is always present and fresh.
        let engineAge = (try? engineProgress.ageSeconds()) ?? .infinity
        let new = HeartbeatHealth.evaluate(age: age, engineAge: engineAge)
        // Close a previous instance's death incident: the companion that
        // paged "Supervisor stopped" exited in the same breath, so the
        // recovery page is THIS instance's job. First green tick only — the
        // marker means a stopped page went out, and green means the
        // replacement app is genuinely up.
        if case .green = new, !startupRecoveryChecked {
            // NOT unconditionally on the first green tick. The boot warm hops
            // its Keychain result back onto this same serial queue, and FIFO
            // puts tick #1 ahead of that hop — so recovery used to run with an
            // empty cache, find no endpoint, and delete the markers with no
            // retry, losing the one page that says Supervisor was down.
            switch CompanionHealthPager.startupRecoveryReadiness(
                webhookCacheResolved: webhookCacheWarmed,
                greenTicksWaited: greenTicksAwaitingRecovery
            ) {
            case .waitForWebhookCache:
                greenTicksAwaitingRecovery += 1
            case .proceed(let cacheResolved):
                startupRecoveryChecked = true
                handleStartupRecovery(webhookCacheResolved: cacheResolved)
            }
        }
        // Sleep/wake grace (C2a): every health age above is a wall-clock
        // mtime, so the first ticks after a wake see both files "stale" and
        // would page "stopped" + "recovered" seconds apart for a Mac that
        // merely closed its lid. A tick gap far past the 2s cadence is the
        // wake tell: reset the pager's run clocks (continuity across sleep
        // is fiction) and hold verdicts for one refresh cycle so the
        // writers stamp fresh times first. The icon keeps updating — it
        // self-corrects in seconds and lies to nobody's phone.
        let tickNow = Date()
        if let deadline = CompanionHealthPager.wakeSuppressionDeadline(lastTickAt: lastTickAt, now: tickNow) {
            wakeSuppressUntil = deadline
            pagerState = CompanionHealthPager.wakeReset(pagerState)
            trace.emit("statusbar", "wake detected (tick gap) — pager verdicts held for \(Int(CompanionHealthPager.wakeGraceSeconds))s")
        }
        lastTickAt = tickNow
        let verdictsHeld = wakeSuppressUntil.map { tickNow < $0 } ?? false
        // Remote paging on health transitions: the pure pager decides (one
        // page per transition, armed only after a first green), this tick
        // only executes its verdict. Runs on the poll queue, so the config
        // read a page needs never touches the main thread.
        if !verdictsHeld {
            let (nextPagerState, page) = CompanionHealthPager.step(state: pagerState, health: new, now: tickNow)
            pagerState = nextPagerState
            if let page { deliverHealthPage(page) }
        }
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

    // MARK: - Reparent death paging (C1)

    /// One-shot outcome box for the exit-path page: written once by the
    /// posting task before it signals, read only after the semaphore wait
    /// succeeds (which establishes the ordering).
    private final class DeathPageOutcomeBox: @unchecked Sendable {
        var posted = false
    }

    /// True once the death handling CONCLUDED (delivered, unconfirmed/hung,
    /// suppressed, or a quiet deploy exit). The exit races the poll timer —
    /// NSApp.terminate is asynchronous — so a coalesced tick can land after
    /// a full 8s attempt already ran; without this guard it would re-enter
    /// and could page the owner twice about one death. A CLEAN failure
    /// leaves it false: nothing left the machine, so the pure
    /// `deathAttemptConcluded` grants that case one free retry per
    /// remaining tick. Touched only on the poll queue.
    private var parentDeathConcluded = false

    /// The parent (main app) is gone. Decide via the pure `reparentAction`
    /// whether this is a deploy relaunch (exit quietly, as before) or a real
    /// death (attempt ONE bounded page), leave the marker the pure
    /// `deathMarker` picks — incident on confirmed delivery, failed-page
    /// when the owner never confirmably heard (so the NEXT instance can
    /// close the loop either way) — then exit so the replacement owns the
    /// icon. Runs on the poll queue; the page uses only the boot-warmed
    /// webhook cache, so no Keychain prompt can ever block the exit.
    private func handleParentDeath() {
        guard !parentDeathConcluded else { return }
        let deployMarkerPresent = FileManager.default.fileExists(atPath: paths.selfRebuildMarkerPath.path)
        let restartMarkerPresent = FileManager.default.fileExists(atPath: paths.intentionalRestartMarkerPath.path)
        switch CompanionHealthPager.reparentAction(
            deployMarkerPresent: deployMarkerPresent,
            restartMarkerPresent: restartMarkerPresent
        ) {
        case .exitQuietly(let reason):
            trace.emit("statusbar", "parent gone (getppid=1) — exiting without page: \(reason)")
            parentDeathConcluded = true
        case .pageStoppedThenExit:
            trace.emit("statusbar", "parent gone (getppid=1) — unexpected death, attempting one page before exit")
            let attempt = deliverDeathPage()
            parentDeathConcluded = CompanionHealthPager.deathAttemptConcluded(attempt)
            let contents = CompanionHealthPager.incidentMarkerContents(
                kind: CompanionHealthPager.deathPageKind, at: Date()
            )
            switch CompanionHealthPager.deathMarker(after: attempt) {
            case .incident:
                try? contents.write(to: paths.companionIncidentMarkerPath, atomically: true, encoding: .utf8)
                // A failed marker from an earlier coalesced attempt is
                // obsolete: the page landed after all.
                try? FileManager.default.removeItem(at: paths.companionFailedPageMarkerPath)
            case .failedPage:
                try? contents.write(to: paths.companionFailedPageMarkerPath, atomically: true, encoding: .utf8)
            case .none:
                break
            }
        }
        trace.sync()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// One synchronous, bounded attempt at the "Supervisor stopped" page.
    /// Same gates as every other page (config switch, https-validated URL),
    /// but sourced from the boot cache instead of a live Keychain read, one
    /// transport attempt with a short timeout, and a hard wall-clock bound
    /// on the wait — the process is exiting and must not hang doing it.
    /// The returned `DeathPageAttempt` drives which marker is left behind
    /// and whether a coalesced tick may retry (see handleParentDeath):
    /// `.suppressed` only for the owner's own off switch; a missing or
    /// invalid webhook is `.failed`, because the owner may well have a URL
    /// stored that simply never reached the boot cache — an outage they
    /// never heard about, which the failed-page marker reports later.
    private func deliverDeathPage() -> CompanionHealthPager.DeathPageAttempt {
        let config = UserConfig.load(from: paths.configPath)
        guard config.remoteNotifyEnabled else {
            trace.emit("statusbar", "death page suppressed (remote_notify disabled)")
            return .suppressed
        }
        guard let raw = cachedWebhookRaw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trace.emit("statusbar", "death page skipped: no webhook in boot cache (warmed=\(webhookCacheWarmed))")
            return .failed
        }
        let endpoint: RemoteWebhookURL
        do {
            endpoint = try RemoteWebhookURL(validating: raw)
        } catch {
            trace.emit("statusbar", "death page skipped: invalid webhook")
            return .failed
        }
        let notifier = RemoteNotifier(
            endpoint: endpoint,
            configuration: .init(
                enabled: true,
                detail: config.remoteNotifyDetail,
                maxAttempts: 1,
                formatOverride: config.remoteNotifyFormat
            ),
            transport: URLSessionRemoteNotifyTransport(timeout: 5),
            trace: trace
        )
        let host = ProcessInfo.processInfo.hostName
        let (title, body) = CompanionHealthPager.deathMessage(hostname: host)
        let semaphore = DispatchSemaphore(value: 0)
        // nonisolated(unsafe) box: written once by the task, read after the
        // semaphore wait establishes happens-before.
        let box = DeathPageOutcomeBox()
        Task.detached {
            let outcome = await notifier.postSystemMessage(
                title: title, body: body, kind: CompanionHealthPager.deathPageKind
            )
            box.posted = (outcome == .posted)
            semaphore.signal()
        }
        // Transport timeout is 5s with a single attempt; 8s covers it plus
        // scheduling slack. A timeout here means the page may or may not
        // have landed — UNCONFIRMED: no incident marker (a recovery page
        // for a stop nobody confirmed would confuse), no retry (it may
        // have landed, and a second send would double-page one death), but
        // the failed-page marker still records that the owner has no
        // confirmed word of the outage.
        let waited = semaphore.wait(timeout: .now() + 8)
        let attempt: CompanionHealthPager.DeathPageAttempt
        switch (waited, box.posted) {
        case (.success, true):  attempt = .delivered
        case (.success, false): attempt = .failed
        case (.timedOut, _):    attempt = .unconfirmed
        }
        trace.emit("statusbar", "death page result attempt=\(attempt)")
        return attempt
    }

    /// First green tick: close a previous instance's death out. The incident
    /// marker (death page delivered) gets the recovery page; the failed-page
    /// marker (death page never confirmed — the owner never heard about the
    /// outage) gets the one combined "stopped earlier and has recovered"
    /// page instead. Both markers are deleted even when the page is gated
    /// off (channel disabled since) — a stale marker firing days later
    /// would be worse than a missing one.
    private func handleStartupRecovery(webhookCacheResolved: Bool) {
        let incidentPath = paths.companionIncidentMarkerPath
        let failedPath = paths.companionFailedPageMarkerPath
        let page = CompanionHealthPager.startupRecoveryPage(
            incidentMarkerPresent: FileManager.default.fileExists(atPath: incidentPath.path),
            failedPageMarkerPresent: FileManager.default.fileExists(atPath: failedPath.path)
        )
        guard let page else { return }
        if !webhookCacheResolved {
            // Proceeding on the timeout arm. Say so: the markers are about to
            // be consumed against a cache that never arrived, so a page that
            // does not land here is not going to land later either.
            trace.emit("statusbar", "startup recovery proceeding without a resolved webhook cache (waited \(CompanionHealthPager.startupRecoveryMaxWaitTicks) green ticks)")
        }
        trace.emit("statusbar", "startup recovery: previous instance died — sending \(page.kind) page")
        try? FileManager.default.removeItem(at: incidentPath)
        try? FileManager.default.removeItem(at: failedPath)
        deliverHealthPage(page)
    }

    // MARK: - Remote health paging

    /// The one long-lived notifier every health page rides. Built lazily on
    /// the poll queue from the boot-warmed webhook cache; the caller applies
    /// the CURRENT config before each page, so a toggle flipped in the panel
    /// takes effect without a companion relaunch. Long-lived on purpose
    /// (C2c): a fresh notifier per page has empty dedupe stamps and an empty
    /// in-flight set, so consecutive pages could neither collapse a flap nor
    /// share ordering.
    private func ensureHealthNotifier() -> RemoteNotifier {
        if let existing = healthNotifier { return existing }
        var endpoint: RemoteWebhookURL?
        if let raw = cachedWebhookRaw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Invalid stored URLs degrade to an endpoint-less notifier
            // (every post skips with its own trace reason), same as the app.
            endpoint = try? RemoteWebhookURL(validating: raw)
        }
        let notifier = RemoteNotifier(
            endpoint: endpoint,
            configuration: .init(enabled: false),  // armed per page from config.yaml
            trace: trace
        )
        healthNotifier = notifier
        return notifier
    }

    /// Deliver one health-transition page through the owner's remote
    /// escalation channel. This is the ONE sanctioned network path in a
    /// companion (see Package.swift): the dead main app cannot page itself,
    /// so the survivor must, and it uses the exact same gates the app does —
    /// `remote_notify.enabled` in config.yaml, then the https-validated
    /// webhook (from the boot cache; the Keychain is never read at page
    /// time, so no SecurityAgent prompt can block the poll queue). Delivery
    /// is strictly serial: each page awaits the previous one, so ordering on
    /// the owner's phone matches the order the verdicts were made.
    private func deliverHealthPage(_ page: CompanionHealthPager.Page) {
        let config = UserConfig.load(from: paths.configPath)
        let notifier = ensureHealthNotifier()
        notifier.apply(.init(
            enabled: config.remoteNotifyEnabled,
            detail: config.remoteNotifyDetail,
            formatOverride: config.remoteNotifyFormat
        ))
        // hostName, not a user-facing pretty name: it needs no extra
        // permission, and the owner with two Macs just needs to tell them
        // apart. Nothing else about the machine or its sessions is sent —
        // the status bar stays database-blind, so the watched-session count
        // (which lives in SQLite) is deliberately absent from the page.
        let host = ProcessInfo.processInfo.hostName
        let (title, body) = CompanionHealthPager.message(for: page, hostname: host)
        let kind = page.kind
        trace.emit("statusbar", "health page sending kind=\(kind)")
        let previous = deliveryChain
        let queue = pollQueue
        deliveryChain = Task { [weak self] in
            await previous?.value
            let outcome = await notifier.postSystemMessage(
                title: title, body: body, kind: kind,
                dedupeWindow: CompanionHealthPager.healthPageDedupeWindow
            )
            trace.emit("statusbar", "health page result kind=\(kind) outcome=\(outcome)")
            // Report the outcome back into the pager on the poll queue (its
            // state is only ever touched there). Only a confirmed delivery
            // stamps the incident; failures retry on later ticks with the
            // pager's bounded backoff. A gate-skip counts as completed
            // because the only gate that still skips is the owner's own
            // switch, and retrying cannot change that. An endpoint slot not
            // yet filled comes back as .failed("no_endpoint") instead, so
            // the retry ladder keeps the page alive until the 5-minute
            // cache refresh applies a stored URL.
            queue?.async {
                guard let self else { return }
                switch outcome {
                case .posted, .skippedDeniedSilently:
                    self.pagerState = CompanionHealthPager.delivered(state: self.pagerState, page: page)
                case .failed:
                    self.pagerState = CompanionHealthPager.deliveryFailed(state: self.pagerState, page: page, now: Date())
                }
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
        // Mark the kill as INTENTIONAL before anything is terminated, not
        // after. Restart escalates to forceTerminate() for the hung app this
        // remedy exists for, so no SIGTERM handler runs and this companion is
        // orphaned; within one tick the reparent check would see getppid()==1
        // with no marker and page "Supervisor stopped", then "recovered". The
        // owner would get a false outage report for doing exactly what the
        // hung-engine page told them to do. Written synchronously and first,
        // for the same reason the deploy marker has to precede its pkill: a
        // marker written after the window in which it is read is not a marker.
        // The relaunched app clears it at startup.
        let restartMarker = paths.intentionalRestartMarkerPath
        do {
            try CompanionHealthPager.incidentMarkerContents(kind: "menu_bar_restart", at: Date())
                .write(to: restartMarker, atomically: true, encoding: .utf8)
        } catch {
            // Never traced with the error: it can quote the path, which
            // carries the account name. A failed write only costs one false
            // page, so it must not stop the restart the owner asked for.
            trace.emit("statusbar", "restart: could not write the intentional-restart marker; a false 'stopped' page may follow")
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
            // No relaunch means no startup to clear the marker, and a stale
            // one would silently exempt a genuine death later. The restart
            // did not happen, so neither should its exemption.
            try? FileManager.default.removeItem(at: paths.intentionalRestartMarkerPath)
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
