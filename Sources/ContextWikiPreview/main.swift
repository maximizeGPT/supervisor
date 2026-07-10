// ContextWikiPreview — a tiny AppKit host to render Context Wiki UI without the
// whole Supervisor app (and its permission dance). Not shipped.
//
//   ContextWikiPreview [<root>]        opens the full Context Health WINDOW
//   ContextWikiPreview panel [<root>]  renders the expanded PANEL with the
//                                       Context Health line wired in
//
// Real deterministic audit on appear; no network, nothing written to the tree.

import AppKit
import SwiftUI
import SupervisorCore
import SupervisorUI

let arguments = CommandLine.arguments
let panelMode = arguments.contains("panel")
let rootArg = arguments.dropFirst().first(where: { $0 != "panel" })
let rootPath = rootArg ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills").path
let root = URL(fileURLWithPath: rootPath, isDirectory: true)

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let root: URL
    private let panelMode: Bool
    private var controller: ContextWikiWindowController?
    private var window: NSWindow?
    private var monitor: ContextHealthMonitor?

    init(root: URL, panelMode: Bool) { self.root = root; self.panelMode = panelMode }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if panelMode {
            // Open the collapsible footer groups so the previously-clipping case
            // (several expanded at once) is what we render.
            UserDefaults.standard.set(true, forKey: "panel.controlsExpanded")
            UserDefaults.standard.set(true, forKey: "panel.sensitivityExpanded")
            UserDefaults.standard.set(true, forKey: "panel.multiModelExpanded")
            let vm = HoverViewModel(bus: EventBus())
            let monitor = ContextHealthMonitor(root: root)
            vm.contextHealth = monitor
            vm.onOpenContextHealth = { NSSound.beep() }   // preview: just confirm the tap fires
            self.monitor = monitor
            monitor.refresh()
            let host = NSHostingController(rootView: ExpandedPanelView(vm: vm))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 480, height: 360))
            window.center()
            window.title = "Expanded panel"
            window.isReleasedWhenClosed = false
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let controller = ContextWikiWindowController(vm: ContextWikiViewModel(root: root))
            self.controller = controller
            controller.present()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// AppKit bootstrap is main-actor work; top-level code isn't statically isolated
// under Swift 6, and we ARE on the main thread at process start, so assert it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PreviewDelegate(root: root, panelMode: panelMode)
    app.delegate = delegate
    app.run()   // blocks; `delegate` stays retained for the process lifetime
}
