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
    var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "xmark.octagon.fill"
        }
    }
    var menuTitle: String {
        switch self {
        case .green: return "Supervisor: running"
        case .amber: return "Supervisor: heartbeat stale"
        case .red(let r): return "Supervisor: \(r)"
        }
    }
    // SF Symbols are tinted via template image mode + accessibility tint.
    // For unsigned dev builds we also emit a plain-text label as a robust
    // fallback when the symbol is unavailable.
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
        button.image = NSImage(systemSymbolName: current.symbolName, accessibilityDescription: "Supervisor")
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

    @objc private func openNotifications() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }
}

// Wire it up.
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let controller = StatusBarController(statusItem: statusItem)
_ = controller  // keep alive

app.run()
