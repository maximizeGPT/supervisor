// ContextWikiWindowController.swift
//
// NSWindowController hosting the SwiftUI `ContextWikiView` — the "Context Health"
// window. Mirrors OnboardingWindowController: a transparent, full-size-content
// title bar so the traffic lights float over the branded header, no system title.
// Unlike onboarding it is resizable (the recommendations list can grow), with a
// comfortable default and a sensible minimum.
//
// Inert by default: the shipping app does not open this yet (the whole feature
// is opt-in / explicitly invoked). This controller is what a menu item or the
// preview harness constructs to present the window.

import AppKit
import SwiftUI
import SupervisorCore

@MainActor
public final class ContextWikiWindowController: NSWindowController {

    private let vm: ContextWikiViewModel

    public init(vm: ContextWikiViewModel) {
        self.vm = vm

        let host = NSHostingController(rootView: ContextWikiView(vm: vm))
        let window = NSWindow(contentViewController: host)

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Context Health"
        window.isMovableByWindowBackground = true

        window.setContentSize(NSSize(width: 760, height: 660))
        window.contentMinSize = NSSize(width: 620, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Kick off the first audit as the window appears if we have no report yet.
        if vm.report == nil { vm.runAudit() }
    }
}
