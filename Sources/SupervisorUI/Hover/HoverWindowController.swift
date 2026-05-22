// HoverWindowController.swift
//
// NSPanel anchored to the top-right of the active screen, always above
// other windows, click-through when there are no active flags (so it
// doesn't interfere with the user's actual work).
//
// 240x40 sized exactly, with a 12pt offset from the menu bar / right edge.

import AppKit
import SwiftUI
import SupervisorCore

@MainActor
public final class HoverWindowController {

    private let vm: HoverViewModel
    private let panel: NSPanel

    public init(vm: HoverViewModel) {
        self.vm = vm

        let panel = HoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: HoverView(vm: vm))
        self.panel = panel
    }

    public func present() {
        positionTopRight()
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        panel.orderOut(nil)
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: frame.maxX - panelSize.width - 12,
            y: frame.maxY - panelSize.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}

/// `canBecomeKey` override on a borderless NSPanel. Default borderless
/// panels can't become key, which would block the v0.1.7+ expanded-panel
/// interactions. For v0.1.0 the hover is read-only — we override anyway so
/// the foundation is in place.
private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
