// HoverWindowController.swift
//
// NSPanel anchored to the top-right of the active screen, always above
// other windows, click-through when there are no active flags (so it
// doesn't interfere with the user's actual work).
//
// 240x40 sized exactly, with a 12pt offset from the menu bar / right edge.
//
// v0.1.4 Gap 8: the panel is only visible when a known terminal is
// frontmost AND Supervisor is actively tailing at least one session.
// The check runs on NSWorkspace.didActivateApplicationNotification
// (immediate response to alt-tab) plus a 3s poll (catches the
// session-becoming-active-without-app-switch case). The
// `.nonactivatingPanel` styleMask + `orderFrontRegardless` keeps focus
// with the user's frontmost app; `[.canJoinAllSpaces, .stationary,
// .ignoresCycle]` collection behavior survives hide/show cycles
// without losing the top-right anchor.

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
    /// when I reported "some bubble top right but not sure".
    public static let panelSize = NSSize(width: 240, height: 40)

    /// Pixel inset from the right edge and top edge of visibleFrame.
    private static let edgeInset: CGFloat = 12

    /// Apps that host a tailable Claude Code session — terminal emulators
    /// where the `claude` CLI runs, plus the Claude desktop app which
    /// spawns `claude` internally. Frontmost bundle IDs not in this set
    /// are treated as non-hosting and trigger hover hide.
    ///
    /// Long-term path: see Issue #3 (user-configurable host-app list)
    /// for users on emulators not in the default set — Electron-based
    /// VS Code / Cursor integrated terminals, mosh, tmux-over-ssh on a
    /// remote, etc. Until that ships, additions land here.
    public static let claudeCodeHostApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "com.anthropic.claudefordesktop",
    ]

    private let vm: HoverViewModel
    private let panel: NSPanel
    private let isAnySessionActive: () -> Bool

    private var workspaceObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var currentlyVisible: Bool = false

    public init(
        vm: HoverViewModel,
        isAnySessionActive: @escaping () -> Bool = { true }
    ) {
        self.vm = vm
        self.isAnySessionActive = isAnySessionActive

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
        // `.canJoinAllSpaces` keeps the panel pinned to the active
        // Space so alt-tab → different Space + alt-tab back doesn't
        // strand the panel on the old Space. `.stationary` prevents
        // Mission Control / Expose from grouping the panel with app
        // windows. `.ignoresCycle` keeps the panel out of Cmd-` /
        // Cmd-Tab cycles.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: HoverView(vm: vm))
        self.panel = panel
    }

    public func present() {
        // v0.1.4 Gap 8: don't unconditionally show. Hook up the
        // visibility-deciding observer + poller, then apply once.
        registerWorkspaceObserver()
        startPollTimer()
        applyVisibility()
    }

    public func dismiss() {
        unregisterWorkspaceObserver()
        stopPollTimer()
        if currentlyVisible {
            panel.orderOut(nil)
            currentlyVisible = false
        }
    }

    // MARK: - Visibility logic (Gap 8)

    /// Compound visibility rule: show iff a Claude-Code-hosting app is
    /// frontmost AND Supervisor is tailing at least one session.
    /// Re-applied on every workspace activation event + on a 3s poll.
    private func applyVisibility() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmostHostsClaudeCode = frontmostBundleID.map(Self.claudeCodeHostApps.contains) ?? false
        let sessionActive = isAnySessionActive()
        let shouldShow = frontmostHostsClaudeCode && sessionActive

        if shouldShow && !currentlyVisible {
            positionTopRight()
            // `.nonactivatingPanel` + `orderFrontRegardless()` shows
            // the panel without activating Supervisor — focus stays
            // with the user's frontmost terminal.
            panel.orderFrontRegardless()
            currentlyVisible = true
        } else if !shouldShow && currentlyVisible {
            panel.orderOut(nil)
            currentlyVisible = false
        }
    }

    private func registerWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        let ws = NSWorkspace.shared
        workspaceObserver = ws.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer queue is `.main`, so this fires on the main
            // thread; we hop to the @MainActor context explicitly to
            // satisfy Swift concurrency without doubling up the dispatch.
            // Local-bind self before Task so Swift 5.10 (CI) accepts the
            // capture pattern — see HoverViewModel.swift for the long
            // form of this comment.
            guard let self else { return }
            Task { @MainActor in self.applyVisibility() }
        }
    }

    private func unregisterWorkspaceObserver() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
    }

    /// 3s poll catches the "session became active while my terminal was
    /// already frontmost" case (the NSWorkspace event only fires on app
    /// switches). Cheap — one closure tick + a string lookup.
    private func startPollTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.applyVisibility() }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
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
