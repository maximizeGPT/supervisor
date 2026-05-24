// SupervisorStatusBar — companion menu-bar process.
//
// Reads the heartbeat file every 2s. Sets the menu-bar icon color based on
// heartbeat freshness:
//   fresh (< 10s)  → green
//   stale (10-30s) → amber
//   stale (> 30s)  → red — "Supervisor: disconnected"
//
// This process MUST survive a crash of the main app (and of
// SupervisorHeartbeat). It does no LLM calls, no file tailing — its only
// job is honestly reporting whether the supervisor stack is alive.

import AppKit
import Foundation
import SupervisorCore

let paths = ConfigPaths()
try paths.ensureDirectoriesExist()

let trace = TraceLog(path: paths.traceLogPath)
let heartbeat = HeartbeatFile(path: paths.heartbeatPath)

trace.emit("statusbar", "boot pid=\(ProcessInfo.processInfo.processIdentifier) heartbeat=\(paths.heartbeatPath.path)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar-only; no dock icon

extension HeartbeatHealth {
    /// SF-symbol fallback name. Used for amber/red since "warning triangle"
    /// and "error octagon" carry stronger universal semantics than the
    /// brand mark would. The healthy state uses the branded V1 symbol
    /// (see `brandedImageName`) rather than this fallback.
    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "xmark.octagon.fill"
        }
    }
    /// Branded asset name in Assets.xcassets. Currently only the healthy
    /// state has a brand-mark image; amber/red fall back to SF Symbols.
    /// Returning nil means "use the SF Symbol".
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
    // Plain-text fallback when both branded asset and SF Symbol are
    // unavailable (e.g. very early boot, or a Resources-stripped build).
    // The button.title is always set so something visible is in the menu
    // bar even if image rendering fails.
    var fallbackLabel: String {
        switch self {
        case .green: return "●"
        case .amber: return "⚠"
        case .red:   return "✕"
        }
    }
}

final class StatusBarController: NSObject {

    private let statusItem: NSStatusItem
    private var current: HeartbeatHealth = .red(reason: "starting")
    private var timer: DispatchSourceTimer?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        configureButton()
        rebuildMenu()
        startPolling()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = current.fallbackLabel

        // Prefer the branded V1 symbol when one is wired up for this state.
        // Asset Catalog SVG is honored by NSImage(named:) on macOS 12+;
        // we mark template = true so the menu-bar foreground color is
        // applied automatically (light vs dark mode). If the asset lookup
        // fails for any reason (resource stripped, bundle not yet loaded),
        // fall through to the SF Symbol so we never go iconless.
        if let assetName = current.brandedImageName,
           let branded = Bundle.module.image(forResource: assetName) {
            branded.isTemplate = true
            button.image = branded
        } else {
            button.image = NSImage(
                systemSymbolName: current.symbolName,
                accessibilityDescription: "Supervisor"
            )
        }
        button.toolTip = current.menuTitle
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: current.menuTitle, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        if case .red = current {
            let openNotif = NSMenuItem(
                title: "Open System Settings → Notifications",
                action: #selector(openNotifications),
                keyEquivalent: ""
            )
            openNotif.target = self
            menu.addItem(openNotif)
            let restart = NSMenuItem(
                title: "Restart Supervisor",
                action: #selector(restartMain),
                keyEquivalent: ""
            )
            restart.target = self
            menu.addItem(restart)
            menu.addItem(NSMenuItem.separator())
        }
        // v0.1.4 Gap 4: a persistent-history surface for past flags. Until
        // the v0.1.7 expanded panel ships, this dumps the last 20 rows
        // from the `flags` table as pretty-printed JSON to /tmp and
        // reveals the file in Finder. JSON over SQLite because human-
        // readable without installing anything.
        let recentFlags = NSMenuItem(
            title: "Recent Flags…",
            action: #selector(openRecentFlags),
            keyEquivalent: ""
        )
        recentFlags.target = self
        menu.addItem(recentFlags)

        // v0.1.6: every pause/kill writes a markdown handoff to
        // ~/Library/Application Support/Supervisor/recovery/. This menu
        // item reveals that folder in Finder so the user can browse the
        // history of interventions and their handoff docs.
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
        let quitItem = NSMenuItem(
            title: "Quit Status Bar",
            action: #selector(quit),
            keyEquivalent: "q"
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
        let age = (try? heartbeat.ageSeconds()) ?? .infinity
        let new = HeartbeatHealth.evaluate(age: age)
        if new != current {
            current = new
            trace.emit("statusbar", "health -> \(new.menuTitle)")
            DispatchQueue.main.async { [weak self] in
                self?.configureButton()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: - Actions

    @objc private func quit() {
        trace.emit("statusbar", "quit requested by user")
        NSApp.terminate(nil)
    }

    @objc private func restartMain() {
        trace.emit("statusbar", "restart-main requested (Phase B+ will wire this)")
        // Phase B/C will spawn Supervisor.app here.
    }

    @objc private func openTraceLog() {
        NSWorkspace.shared.open(paths.traceLogPath)
    }

    /// v0.1.6: reveal the recovery-doc directory in Finder. Creates the
    /// directory first if it doesn't exist yet (typical on a clean install
    /// before any pause/kill has fired), so the user doesn't see a
    /// "folder not found" error from Finder.
    @objc private func openRecoveryFolder() {
        try? FileManager.default.createDirectory(at: paths.recoveryDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.recoveryDir])
        trace.emit("statusbar", "open recovery folder requested → \(paths.recoveryDir.path)")
    }

    @objc private func openNotifications() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    /// v0.1.4 Gap 4: write the last 20 `flags` rows to a pretty-printed
    /// JSON file under /tmp and reveal it in Finder. Each invocation
    /// gets its own file (timestamped) so repeated clicks don't
    /// overwrite a file the user might be inspecting. The format is
    /// `StoredFlag`'s Codable shape — every column including
    /// reasoning_plain, reasoning_technical, asymmetry_note, and the
    /// recommended_action — which gives the user everything the
    /// banner had to skip.
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

// Wire it up.
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let controller = StatusBarController(statusItem: statusItem)
_ = controller  // keep alive

app.run()
