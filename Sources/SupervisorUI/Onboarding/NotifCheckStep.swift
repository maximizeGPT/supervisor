// NotifCheckStep.swift
//
// Step 3 content body — notification permission. Three substates branch
// off NotificationAuthStatus:
//   - notDetermined → primary "Request permission" (in footer) → triggers
//     the macOS prompt; user can deny in that dialog and the flow continues
//     via the `.denied` substate's "Continue anyway" footer button.
//   - authorized / provisional / ephemeral → primary "Continue" in footer.
//   - denied → primary "Continue anyway" in footer; secondary "Open System
//     Settings" stays inside the content area as a non-footer action.
//
// The v0.1.2 "Skip" button is removed per the spec ("Skip only on AX").
// Users in notDetermined must click "Request permission" before they can
// advance — they can still deny in the macOS prompt and proceed from there.

import AppKit
import SwiftUI
import SupervisorCore

struct NotifCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let status: NotificationAuthStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Supervisor surfaces flags. Banners are the primary path; the macOS Notification Center keeps a record either way.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .notDetermined:
            Label("Permission not yet requested.", systemImage: "questionmark.circle")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
        case .authorized, .provisional, .ephemeral:
            // Spec calls Signal-green on the checkmark only — "No green
            // text, no green icons" applies to the rest. SwiftUI's Label
            // inherits one foregroundStyle for icon + text, so we split
            // into an HStack: Signal icon, Mute text (matching the
            // .notDetermined treatment for the status text style).
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColor.signal.color)
                Text("Notifications enabled.")
                    .foregroundStyle(BrandColor.mute.color)
            }
            .font(BrandFont.note)
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications denied by macOS.", systemImage: "exclamationmark.triangle.fill")
                    .font(BrandFont.note)
                    .foregroundStyle(.orange)
                Text("Flags will still appear in Notification Center; banner pop-ups are suppressed. You can re-enable in System Settings → Notifications → Supervisor.")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.notifications)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }
}

struct CompleteStep: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColor.signal.color)
            Text("Supervisor is now watching your Claude Code sessions.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
