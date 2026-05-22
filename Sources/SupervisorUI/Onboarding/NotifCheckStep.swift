// NotifCheckStep.swift
//
// Step 3: Notifications. Three substates branch off the
// NotificationAuthStatus per the Spike 2 finding:
//   - notDetermined → "Request" button triggers the system prompt
//   - authorized / provisional → "Continue" advances
//   - denied → degradation banner copy + "Open System Settings" deep link
//     + "Continue anyway" (proceeds with notifDegraded=true)

import AppKit
import SwiftUI
import SupervisorCore

struct NotifCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let status: NotificationAuthStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3. Notifications")
                .font(.system(size: 14, weight: .semibold))

            Text("How Supervisor surfaces flags. Banners are the primary path; the macOS Notification Center keeps a record either way.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusView

            HStack(spacing: 10) {
                actionButton
                Button("Skip") {
                    vm.finishNotificationStep()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .notDetermined:
            Label("Permission not yet requested.", systemImage: "questionmark.circle")
                .font(.system(size: 12))
        case .authorized, .provisional, .ephemeral:
            Label("Notifications enabled.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications denied by macOS.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Flags will still appear in Notification Center; banner pop-ups are suppressed. You can re-enable in System Settings → Notifications → Supervisor.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notDetermined:
            Button("Request permission") {
                Task { await vm.requestNotifications() }
            }
            .keyboardShortcut(.defaultAction)
        case .authorized, .provisional, .ephemeral:
            Button("Continue") {
                vm.finishNotificationStep()
            }
            .keyboardShortcut(.defaultAction)
        case .denied:
            HStack(spacing: 8) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.notifications)
                }
                Button("Continue anyway") {
                    vm.finishNotificationStep()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct CompleteStep: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("All set.")
                .font(.system(size: 14, weight: .semibold))
            Text("Supervisor is now watching your Claude Code sessions.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
