// OnboardingScene.swift
//
// v0.1.6.3 layout — a 480×420 window split into three explicit bands:
//
//   Header (80pt, Paper-warm bg)     — wordmark centered at 24pt
//   Content (fill = 284pt, default)   — step indicator + title + step body
//   Footer (56pt, Paper bg)           — primary button right-aligned;
//                                       Skip left-aligned on the AX step
//
// Window grew from 360→420pt in v0.1.6.3: at 360pt the AX step body
// and the Notif-denied state body both overflowed the 224pt content
// band and clipped the footer buttons. See OnboardingWindowController
// for the longer note.
//
// Step views (KeyEntryStep, AXCheckStep, NotifCheckStep) shed their
// primary buttons — those moved into the footer here. KeyEntryStep's
// `key` state lifts up via a Binding<String> so the footer's primary
// button can gate its disabled state on emptiness. AXCheckStep's
// "Re-check now" is gone entirely (vm.tick() polls every 1.5s);
// NotifCheckStep's "Skip" is removed per the spec ("Skip only on AX")
// — in `.denied` the secondary "Open System Settings" still lives
// inside the content area as a non-primary action.

import AppKit
import SwiftUI
import SupervisorCore

public struct OnboardingScene: View {

    @ObservedObject var vm: OnboardingViewModel

    /// Lifted up from KeyEntryStep so the footer's primary button can
    /// gate its disabled state on emptiness without coupling state into
    /// the view model.
    @State private var keyDraft: String = ""

    public init(vm: OnboardingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 480, height: 420)
        // v0.1.6.4: lock the onboarding window into light mode. The brand
        // palette (inkDeep, mute, paper, paperWarm) was designed for a
        // light "paper" background; in dark mode the content band had no
        // explicit background and inherited the system dark gray, making
        // inkDeep body text and mute notes nearly invisible. Forcing
        // .light here keeps the header/content/footer visually unified
        // and makes the SecureField + buttons render against the
        // expected light surface.
        .preferredColorScheme(.light)
        .task {
            // Periodic refresh while the window is up: catches out-of-band
            // AX grants in System Settings and notification status changes.
            while !Task.isCancelled {
                await vm.tick()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - Header (80pt, Paper-warm)

    private var header: some View {
        ZStack {
            BrandColor.paperWarm.color
            wordmark
                .frame(height: 24)
                .accessibilityLabel("Supervisor")
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
    }

    /// SVG resource → NSImage → SwiftUI Image, with a text fallback. The
    /// fallback prevents an empty header band if Bundle.module misses the
    /// asset (resource-stripped build, name typo, etc.) — same defensive
    /// shape as SupervisorStatusBar's branded glyph.
    @ViewBuilder
    private var wordmark: some View {
        if let ns = Bundle.module.image(forResource: "OnboardingWordmark") {
            Image(nsImage: ns)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("Supervisor")
                .font(BrandFont.title)
                .foregroundStyle(BrandColor.ink.color)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Wrap in a ZStack with an explicit Paper background so the
        // content band doesn't fall through to the window's default
        // background (belt + suspenders with .preferredColorScheme(.light)
        // on the parent — works even if a future SwiftUI build ignores
        // the colorScheme hint on borderless-content-view windows).
        ZStack {
            BrandColor.paper.color
            switch vm.state {
            case .complete:
                // Special case: the "All set" screen is centered, not a
                // step-indicator + title + body composition. The window is
                // typically dismissed within one render cycle of this state,
                // but it should still look right if dismissal lags.
                CompleteStep()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                VStack(alignment: .leading, spacing: 10) {
                    Text(stepIndicatorText)
                        .font(BrandFont.indicator)
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(BrandColor.mute.color)
                    Text(stepTitle)
                        .font(BrandFont.title)
                        .foregroundStyle(BrandColor.ink.color)
                    stepBody
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stepIndicatorText: String {
        switch vm.state {
        case .keyEntry, .keyValidating: return "Step 1 of 3"
        case .axCheck:                  return "Step 2 of 3"
        case .notifCheck:               return "Step 3 of 3"
        case .complete:                 return ""
        }
    }

    private var stepTitle: String {
        switch vm.state {
        case .keyEntry, .keyValidating:
            // v0.2.0: title now reflects the selected provider so it
            // doesn't say "Anthropic API key" when the user has DeepSeek
            // / Moonshot / etc. picked.
            return "\(vm.selectedProvider.displayName) API key"
        case .axCheck:                  return "Accessibility access"
        case .notifCheck:               return "Notifications"
        case .complete:                 return "All set"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch vm.state {
        case .keyEntry(let err):
            KeyEntryStep(vm: vm, error: err, key: $keyDraft)
        case .keyValidating:
            KeyValidatingStep()
        case .axCheck(let prompted):
            AXCheckStep(vm: vm, prompted: prompted)
        case .notifCheck(let status):
            NotifCheckStep(vm: vm, status: status)
        case .complete:
            EmptyView()   // handled by the `.complete` branch in `content`
        }
    }

    // MARK: - Footer (56pt, Paper, 1pt top border in Paper-warm)

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(BrandColor.paperWarm.color)
                .frame(height: 1)
            HStack(spacing: 10) {
                skipButton
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.paper.color)
        }
        .frame(height: 56)
    }

    @ViewBuilder
    private var skipButton: some View {
        if case .axCheck = vm.state {
            Button("Skip for now") {
                Task { await vm.skipAX() }
            }
            .buttonStyle(.plain)
            .font(BrandFont.button)
            .foregroundStyle(BrandColor.mute.color)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch vm.state {
        case .keyEntry:
            BrandPrimaryButton("Validate & Save") {
                Task { await vm.submitKey(keyDraft) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

        case .keyValidating:
            ProgressView().controlSize(.small)

        case .axCheck(let prompted):
            // Before the user has been sent to Settings, the primary
            // action opens System Settings. After that, the primary
            // action becomes an active "Continue" so a user who enabled
            // the grant is never forced to use the muted "Skip" when
            // macOS fails to report the grant back (the stale-entry
            // ad-hoc-signing case). The 1.5s poll still auto-advances
            // when macOS does report it.
            if prompted {
                BrandPrimaryButton("Continue") {
                    Task { await vm.confirmAX() }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                BrandPrimaryButton("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.accessibility)
                    vm.promptForAX()
                }
                .keyboardShortcut(.defaultAction)
            }

        case .notifCheck(.notDetermined):
            BrandPrimaryButton("Request permission") {
                Task { await vm.requestNotifications() }
            }
            .keyboardShortcut(.defaultAction)

        case .notifCheck(.authorized), .notifCheck(.provisional), .notifCheck(.ephemeral):
            BrandPrimaryButton("Continue") {
                vm.finishNotificationStep()
            }
            .keyboardShortcut(.defaultAction)

        case .notifCheck(.denied):
            BrandPrimaryButton("Continue anyway") {
                vm.finishNotificationStep()
            }
            .keyboardShortcut(.defaultAction)

        case .complete:
            EmptyView()
        }
    }
}
