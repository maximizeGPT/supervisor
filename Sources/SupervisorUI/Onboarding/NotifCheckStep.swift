// NotifCheckStep.swift
//
// Step 3 content body, notification permission. Three substates branch
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
// advance, they can still deny in the macOS prompt and proceed from there.

import AppKit
import SwiftUI
import SupervisorCore

struct NotifCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let status: NotificationAuthStatus

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.md) {
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
            // Spec calls Signal-green on the checkmark only, "No green
            // text, no green icons" applies to the rest. SwiftUI's Label
            // inherits one foregroundStyle for icon + text, so we split
            // into an HStack: Signal icon, Mute text (matching the
            // .notDetermined treatment for the status text style).
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColor.signal.color)
                Text("Notifications enabled.")
                    .foregroundStyle(BrandColor.mute.color)
            }
            .font(BrandFont.note)
        case .denied:
            VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                // Denied is an attention state, not an alarm: the one calm
                // amber tone the rest of the app reserves for "needs a look"
                // (SeverityBadge, a failed plan step), never a raw system
                // orange.
                Label("Notifications denied by macOS.", systemImage: "exclamationmark.triangle.fill")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.attention.color)
                Text("Flags will still appear in Notification Center; banner pop-ups are suppressed. You can re-enable in System Settings → Notifications → Supervisor.")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                // The quiet secondary action, on the brand secondary button
                // (neutral, hairline-bordered) so it matches the footer pair
                // instead of dropping in default macOS bordered chrome next
                // to the brand surfaces.
                BrandSecondaryButton("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.notifications)
                }
                .padding(.top, BrandSpacing.xs)
            }
        }
    }
}

struct CompleteStep: View {
    var body: some View {
        VStack(spacing: BrandSpacing.lg) {
            Spacer()
            // The one place green carries a celebration: the "all set"
            // success mark. A hero size (2x iconLarge) for the single
            // confirming beat of the wizard; the green is the same accent
            // the live panel reserves for success.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: BrandMetrics.iconLarge * 2))
                .foregroundStyle(BrandColor.signal.color)
            Text("Supervisor is now watching your Claude Code sessions.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BrandSpacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
