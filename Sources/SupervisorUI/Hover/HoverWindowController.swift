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

    /// Single source of truth for the hover panel's dimensions. Used at
    /// init (contentRect), at position-time (origin math), and at every
    /// re-anchor. Don't compute the size from `panel.frame.size` —
    /// during early init the panel reports (0, 0) until the SwiftUI
    /// hosting controller realizes its content. We hit that exact bug
    /// during the Checkpoint C visual smoke: the hover ended up at
    /// (1908, 2)–(2148, 42), only the leftmost 12 px on-screen. Caught
    /// by Mohammed reporting "some bubble top right but not sure".
    public static let panelSize = NSSize(width: 240, height: 40)

    /// Pixel inset from the right edge and top edge of visibleFrame.
    private static let edgeInset: CGFloat = 12

    private let vm: HoverViewModel
    private let panel: NSPanel

    public init(vm: HoverViewModel) {
        self.vm = vm

        let panel = HoverPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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

        // Belt: pin the content size now so layout has the right rect.
        panel.setContentSize(Self.panelSize)

        // Suspenders: compute origin from the known constant, not from
        // `panel.frame.size`. If the SwiftUI hosting controller hasn't
        // realized layout yet (Checkpoint-C-visual-smoke bug), frame.size
        // can be (0, 0) — using the constant makes the position correct
        // regardless of init timing.
        let origin = NSPoint(
            x: frame.maxX - Self.panelSize.width - Self.edgeInset,
            y: frame.maxY - Self.panelSize.height - Self.edgeInset
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
