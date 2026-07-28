// OnboardingScene.swift
//
// v0.1.6.3 layout: a 480x420 window split into three explicit bands.
//
//   Header (80pt, Paper-warm bg):   wordmark centered at 24pt
//   Content (fill = 284pt, default): step indicator + title + step body
//   Footer (56pt, Paper bg):        primary button right-aligned;
//                                    Skip left-aligned on the AX step
//
// Window grew from 360→420pt in v0.1.6.3: at 360pt the AX step body
// and the Notif-denied state body both overflowed the 224pt content
// band and clipped the footer buttons. See OnboardingWindowController
// for the longer note.
//
// Step views (KeyEntryStep, AXCheckStep, NotifCheckStep) shed their
// primary buttons, those moved into the footer here. KeyEntryStep's
// `key` state lifts up via a Binding<String> so the footer's primary
// button can gate its disabled state on emptiness. AXCheckStep's
// "Re-check now" is gone entirely (vm.tick() polls every 1.5s);
// NotifCheckStep's "Skip" is removed per the spec ("Skip only on AX").
// In `.denied` the secondary "Open System Settings" still lives
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
                .frame(height: BrandMetrics.iconLarge)
                .accessibilityLabel("Supervisor")
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
        // The header band closes on a hairline rule, the same quiet 1px
        // separator the Plan card uses between surfaces, so the wizard
        // reads as the same instrument, not a stack of differently-edged
        // panes.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.mute.color.opacity(0.15))
                .frame(height: BrandMetrics.hairline)
        }
    }

    /// SVG resource → NSImage → SwiftUI Image, with a text fallback. The
    /// fallback prevents an empty header band if the resource bundle misses
    /// the asset (resource-stripped build, name typo, etc.), same defensive
    /// shape as the menu-bar status item's branded glyph.
    ///
    /// Deliberately NOT `Bundle.module`: the synthesized accessor fatalErrors
    /// when `Supervisor_SupervisorUI.bundle` itself is absent — exactly the
    /// packaged-app case if the build script ever fails to copy it into
    /// Contents/Resources — which would crash the app on the FIRST onboarding
    /// render. `Self.resourceBundle` probes the same locations and returns nil
    /// instead, so a missing bundle degrades to the text fallback below.
    @ViewBuilder
    private var wordmark: some View {
        if let ns = Self.resourceBundle?.image(forResource: "OnboardingWordmark") {
            Image(nsImage: ns)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("Supervisor")
                .font(BrandFont.title)
                .foregroundStyle(BrandColor.ink.color)
        }
    }

    /// Non-trapping stand-in for `Bundle.module`. Probes the candidate
    /// directories the synthesized accessor searches — the main bundle's
    /// Resources dir and bundle root, the class-context bundle (dev / xctest
    /// layouts, where SwiftPM drops the resource bundle next to the binary),
    /// and the executable's own directory — and returns nil when the bundle
    /// is genuinely absent rather than crashing.
    /// Class token for `Bundle(for:)` — resolves to the binary this library is
    /// statically linked into (the app in production, the xctest bundle in tests).
    private final class SupervisorUIBundleToken {}

    private static let resourceBundle: Bundle? = {
        let name = "Supervisor_SupervisorUI.bundle"
        var candidates: [URL] = []
        if let u = Bundle.main.resourceURL { candidates.append(u) }
        candidates.append(Bundle.main.bundleURL)
        let classBundle = Bundle(for: SupervisorUIBundleToken.self)
        if let u = classBundle.resourceURL { candidates.append(u) }
        candidates.append(classBundle.bundleURL.deletingLastPathComponent())
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe)
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for dir in candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let b = Bundle(url: url) {
                return b
            }
        }
        return nil
    }()

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Wrap in a ZStack with an explicit Paper background so the
        // content band doesn't fall through to the window's default
        // background (belt + suspenders with .preferredColorScheme(.light)
        // on the parent, works even if a future SwiftUI build ignores
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
                // ScrollView, not a bare VStack: the window is a fixed
                // 480x420 (header 80 + content ~284 + footer 56), and a
                // step whose body outgrows the band — step 5's two cards
                // did, all its texts being fixedSize — otherwise overflows
                // PAST the footer, pushing the primary Done button below
                // the window edge. A user then sees "no button to move
                // forward" (real field report, v0.3.1 onboarding). Tall
                // content now scrolls inside the band; the footer, and
                // with it the primary button, is always on screen.
                ScrollView {
                    VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                        Text(stepIndicatorText)
                            .font(BrandFont.indicator)
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(BrandColor.mute.color)
                        Text(stepTitle)
                            .font(BrandFont.title)
                            .foregroundStyle(BrandColor.ink.color)
                        stepBody
                            .padding(.top, BrandSpacing.xs)
                    }
                    .padding(.horizontal, BrandSpacing.xl)
                    .padding(.top, BrandSpacing.lg)
                    .padding(.bottom, BrandSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The one calm beat as a step lands: content crossfades on the
        // standard motion (the same curve the panel uses when its contents
        // reflow), so advancing a step reads as a deliberate transition,
        // never a jump. Keyed on the step identity so substate changes
        // within a step (an inline error appearing) don't re-trigger it.
        .animation(BrandMotion.standard, value: stepIndicatorText)
    }

    private var stepIndicatorText: String {
        switch vm.state {
        case .keyEntry, .keyValidating: return "Step 1 of 5"
        case .axCheck:                  return "Step 2 of 5"
        case .screenRecordingCheck:     return "Step 3 of 5"
        case .notifCheck:               return "Step 4 of 5"
        case .customization:            return "Step 5 of 5"
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
        case .screenRecordingCheck:     return "Screen Recording access"
        case .notifCheck:               return "Notifications"
        case .customization:            return "Make it yours"
        case .complete:                 return "All set"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch vm.state {
        case .keyEntry(let err):
            KeyEntryStep(vm: vm, error: err, key: $keyDraft)
        case .keyValidating:
            KeyValidatingStep(providerName: vm.selectedProvider.displayName)
        case .axCheck(let prompted):
            AXCheckStep(vm: vm, prompted: prompted)
        case .screenRecordingCheck(let prompted):
            ScreenRecordingCheckStep(vm: vm, prompted: prompted)
        case .notifCheck(let status):
            NotifCheckStep(vm: vm, status: status)
        case .customization:
            CustomizationStep()
        case .complete:
            EmptyView()   // handled by the `.complete` branch in `content`
        }
    }

    // MARK: - Footer (56pt, Paper, 1pt top border in Paper-warm)

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(BrandColor.mute.color.opacity(0.15))
                .frame(height: BrandMetrics.hairline)
            HStack(spacing: BrandSpacing.sm) {
                skipButton
                Spacer()
                primaryButton
            }
            .padding(.horizontal, BrandSpacing.xl)
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
        } else if case .screenRecordingCheck = vm.state {
            Button("Skip for now") {
                Task { await vm.skipScreenRecording() }
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
            ProgressView()
                .controlSize(.small)
                .tint(BrandColor.signal.color)

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

        case .screenRecordingCheck(let prompted):
            // Mirrors the AX step: before the user has been sent to Settings,
            // the primary action opens System Settings (and fires the macOS
            // request once). After that it becomes "Continue" so a user who
            // enabled the grant is never stuck on "Skip" when macOS fails to
            // report the grant back. The 1.5s poll still auto-advances when
            // macOS does report it.
            if prompted {
                BrandPrimaryButton("Continue") {
                    Task { await vm.confirmScreenRecording() }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                BrandPrimaryButton("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.screenRecording)
                    vm.promptForScreenRecording()
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

        case .customization:
            BrandPrimaryButton("Done") {
                vm.finishCustomizationStep()
            }
            .keyboardShortcut(.defaultAction)

        case .complete:
            EmptyView()
        }
    }
}
