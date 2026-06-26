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

    private var window: NSWindow?

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

    public init() {}

    public func present(reason: Reason) {
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
