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
//
// v0.1.7: expanded panel. Click on hover toggles a 480x360 panel
// below the hover with recent flags, session metrics, and cost.
//
// v0.8.1: draggable hover. The user can grab and drag the hover window
// anywhere on screen. A click (< 3pt movement) toggles the expanded
// panel; a drag (>= 3pt) moves the window. Once dragged, the hover
// remembers its user-set position and doesn't snap back to top-right.

import AppKit
import Combine
import SwiftUI
import SupervisorCore

@MainActor
public final class HoverWindowController {

    /// Single source of truth for the hover panel's dimensions.
    public static let panelSize = NSSize(width: 240, height: 40)

    /// Expanded panel dimensions per DESIGN.md section 6.2.
    public static let expandedSize = NSSize(width: 480, height: 360)

    /// Gap between hover and expanded panel.
    private static let expandedGap: CGFloat = 4

    /// Pixel inset from the right edge and top edge of visibleFrame.
    private static let edgeInset: CGFloat = 12

    /// Default apps that host a tailable Claude Code session.
    public static let defaultHostApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "com.anthropic.claudefordesktop",
    ]

    /// Live set: defaults + user config. Updated by `mergeUserConfig`.
    public private(set) var claudeCodeHostApps: Set<String>

    private let vm: HoverViewModel
    private let panel: HoverPanel
    private let expandedPanel: HoverPanel
    private let isAnySessionActive: () -> Bool

    private var workspaceObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var currentlyVisible: Bool = false
    private var expandedCancellable: AnyCancellable?
    private var frameObserver: NSObjectProtocol?

    /// Once the user drags the hover, don't auto-position it anymore.
    private var userHasRepositioned: Bool = false

    public init(
        vm: HoverViewModel,
        isAnySessionActive: @escaping () -> Bool = { true },
        additionalHostApps: [String] = []
    ) {
        self.vm = vm
        self.isAnySessionActive = isAnySessionActive
        self.claudeCodeHostApps = Self.defaultHostApps.union(additionalHostApps)

        // -- Hover panel (240x40) --
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
        // v0.8.1: enable native drag via isMovableByWindowBackground.
        // Click vs drag is distinguished in HoverPanel's mouse handling.
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // The HoverView no longer has onTapGesture — click detection is
        // handled at the NSPanel level to properly distinguish from drag.
        panel.contentViewController = NSHostingController(rootView: HoverView(vm: vm))
        self.panel = panel

        // -- Expanded panel (480x360) --
        let expanded = HoverPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        expanded.isFloatingPanel = true
        expanded.level = .statusBar
        expanded.isOpaque = false
        expanded.backgroundColor = .clear
        expanded.hasShadow = true
        expanded.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        expanded.isMovableByWindowBackground = false
        expanded.isReleasedWhenClosed = false
        expanded.hidesOnDeactivate = false
        expanded.contentViewController = NSHostingController(
            rootView: ExpandedPanelView(vm: vm)
        )
        self.expandedPanel = expanded

        // Wire callbacks now that all stored properties are initialized.
        panel.onClick = { [weak vm] in
            vm?.toggleExpanded()
        }
        panel.onDragStarted = { [weak self] in
            self?.userHasRepositioned = true
        }

        // Observe vm.isExpanded to show/hide the expanded panel.
        self.expandedCancellable = vm.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                guard let self else { return }
                if isExpanded {
                    self.showExpanded()
                } else {
                    self.hideExpanded()
                }
            }

        // Observe hover panel frame changes — re-anchor expanded panel
        // when the hover is dragged to a new position.
        self.frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.expandedPanel.isVisible else { return }
            Task { @MainActor in self.positionExpanded() }
        }
    }

    /// Merge user config into the live host-apps set.
    public func mergeUserConfig(additionalHostApps: [String]) {
        claudeCodeHostApps = Self.defaultHostApps.union(additionalHostApps)
        applyVisibility()
    }

    public func present() {
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
        hideExpanded()
    }

    // MARK: - Expanded panel show/hide

    private func showExpanded() {
        guard panel.isVisible else { return }
        positionExpanded()
        expandedPanel.alphaValue = 1.0
        expandedPanel.orderFrontRegardless()
    }

    private func hideExpanded() {
        expandedPanel.orderOut(nil)
        expandedPanel.alphaValue = 0.0
    }

    /// Position expanded panel directly below the hover, right-aligned.
    private func positionExpanded() {
        let hoverFrame = panel.frame
        expandedPanel.setContentSize(Self.expandedSize)
        let origin = NSPoint(
            x: hoverFrame.maxX - Self.expandedSize.width,
            y: hoverFrame.minY - Self.expandedGap - Self.expandedSize.height
        )
        expandedPanel.setFrameOrigin(origin)
    }

    // MARK: - Visibility logic (Gap 8)

    private func applyVisibility() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmostHostsClaudeCode = frontmostBundleID.map(claudeCodeHostApps.contains) ?? false
        let sessionActive = isAnySessionActive()
        let shouldShow = frontmostHostsClaudeCode && sessionActive

        if shouldShow && !currentlyVisible {
            // Only auto-position if the user hasn't manually dragged.
            if !userHasRepositioned {
                positionTopRight()
            }
            panel.orderFrontRegardless()
            currentlyVisible = true
        } else if !shouldShow && currentlyVisible {
            panel.orderOut(nil)
            currentlyVisible = false
            vm.isExpanded = false
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
        panel.setContentSize(Self.panelSize)
        let origin = NSPoint(
            x: frame.maxX - Self.panelSize.width - Self.edgeInset,
            y: frame.maxY - Self.panelSize.height - Self.edgeInset
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - HoverPanel (click vs drag distinction)

/// Custom NSPanel that distinguishes a click (< 3pt movement) from a drag.
/// `canBecomeKey` is overridden so the expanded panel can receive input.
/// `isMovableByWindowBackground` is true so macOS handles the native drag;
/// this class tracks mouse-down/up to detect whether it was a click.
final class HoverPanel: NSPanel {

    /// Movement threshold: if the mouse moves less than this many points
    /// between mouseDown and mouseUp, it's a click, not a drag.
    private static let clickThreshold: CGFloat = 3.0

    /// Called when the user clicks (not drags) the panel.
    var onClick: (() -> Void)?

    /// Called when the user starts dragging (movement exceeds threshold).
    var onDragStarted: (() -> Void)?

    private var mouseDownLocation: NSPoint?
    private var didNotifyDrag = false

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        didNotifyDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        // Check if we've exceeded the drag threshold.
        if !didNotifyDrag, let start = mouseDownLocation {
            let current = NSEvent.mouseLocation
            let dx = current.x - start.x
            let dy = current.y - start.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance >= Self.clickThreshold {
                didNotifyDrag = true
                onDragStarted?()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let start = mouseDownLocation else { return }
        let end = NSEvent.mouseLocation
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        if distance < Self.clickThreshold {
            // Click — not a drag.
            onClick?()
        }
        mouseDownLocation = nil
    }
}
