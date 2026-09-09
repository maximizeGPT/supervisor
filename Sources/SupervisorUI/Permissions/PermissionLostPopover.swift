// PermissionLostPopover.swift
//
// 320x180 NSPanel that appears when AX permission is revoked after
// onboarding. Two CTAs: open System Settings → AX, or dismiss.
//
// The panel is floating (`.floating` level), released on close, and
// re-creatable — the PermissionMonitor in the main app owns the lifecycle
// and instantiates a fresh popover on each revocation transition.

import AppKit
import SwiftUI
import SupervisorCore

@MainActor
public final class PermissionLostPopover {

    /// Internal, not private: the screen gate below is proven by asserting no
    /// panel was ever built, and a private field cannot be asserted on.
    private(set) var window: NSWindow?

    /// Whether this instance may put the panel on the user's screen. False for
    /// any instance resolving a non-default `SUPERVISOR_HOME` (an E2E
    /// scenario), which runs alongside the owner's real app by design and must
    /// not paint on his screen or take his focus — this panel calls
    /// `NSApp.activate(ignoringOtherApps:)`, so an isolated instance whose AX
    /// grant flickered would steal the keyboard mid-sentence.
    ///
    /// The gate is here rather than on `PermissionMonitor.start()`, and the
    /// monitor keeps running in an isolated instance, for two reasons. The
    /// monitor is the app's only account of what happened to its permissions,
    /// and a harness run that loses those trace lines loses the one signal that
    /// explains an AX-driven scenario suddenly unable to press anything. And
    /// this class is the only part of that path that reaches the screen, so it
    /// is the one place a future caller cannot route around — the same
    /// reasoning that put the hover gate inside `forceShowForFlash` rather than
    /// at its call sites.
    public let presentsOnScreen: Bool

    public enum Reason: Sendable, Equatable {
        case accessibilityRevoked
        case notificationsRevoked

        var title: String {
            switch self {
            case .accessibilityRevoked: return "Accessibility access was revoked."
            case .notificationsRevoked: return "Notification permission was revoked."
            }
        }

        var body: String {
            switch self {
            case .accessibilityRevoked:
                return "macOS sometimes does this after updates, especially for unsigned apps. Re-grant in System Settings → Privacy & Security → Accessibility.\n\nInject is disabled until then. Triage, escalation, notify, pause, and kill still work."
            case .notificationsRevoked:
                return "Banner notifications are suppressed; flags will still appear in Notification Center. Re-grant in System Settings → Notifications → Supervisor."
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibilityRevoked: return PermissionSettingsURL.accessibility
            case .notificationsRevoked: return PermissionSettingsURL.notifications
            }
        }
    }

    public init(presentsOnScreen: Bool = ConfigPaths.isRealUserHome) {
        self.presentsOnScreen = presentsOnScreen
    }

    public func present(reason: Reason) {
        // A suppressed instance never even builds the panel: an NSPanel that
        // exists is one `makeKeyAndOrderFront` away from the owner's screen.
        guard presentsOnScreen else { return }
        // Reuse a single window so rapid repeat presents don't pile up.
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.title = "Supervisor"
            panel.isReleasedWhenClosed = false
            window = panel
        }
        let content = PermissionLostView(
            reason: reason,
            openSettings: { [weak self] in
                NSWorkspace.shared.open(reason.settingsURL)
                self?.dismiss()
            },
            dismiss: { [weak self] in self?.dismiss() }
        )
        window?.contentViewController = NSHostingController(rootView: content)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        window?.orderOut(nil)
    }
}

// MARK: - SwiftUI body

private struct PermissionLostView: View {
    let reason: PermissionLostPopover.Reason
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(reason.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(reason.body)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Dismiss", action: dismiss)
                Spacer()
                Button("Open System Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320, height: 180, alignment: .topLeading)
    }
}
