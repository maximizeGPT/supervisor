// OnboardingScene.swift
//
// The SwiftUI root for the onboarding window. Picks which step view to
// render based on the view model's current state. No logic here — every
// branch dispatches to a child view that's a pure projection of state.

import SwiftUI
import SupervisorCore

public struct OnboardingScene: View {

    @ObservedObject var vm: OnboardingViewModel

    public init(vm: OnboardingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            Divider()
            footer
        }
        .frame(width: 480, height: 360)
        .task {
            // Periodic refresh while the window is up: catches out-of-band
            // AX grants in System Settings and notification status changes.
            while !Task.isCancelled {
                await vm.tick()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Supervisor")
                .font(.system(size: 18, weight: .semibold))
            Text("A native macOS app that watches Claude Code sessions and intervenes when you'd want it to.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StepIndicator(current: vm.state.step)
                .padding(.top, 4)
        }
        .padding(20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .keyEntry(let err):
            KeyEntryStep(vm: vm, error: err)
        case .keyValidating:
            KeyValidatingStep()
        case .axCheck(let prompted):
            AXCheckStep(vm: vm, prompted: prompted)
        case .notifCheck(let status):
            NotifCheckStep(vm: vm, status: status)
        case .complete:
            CompleteStep()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Your Anthropic key is stored in macOS Keychain. Triage and escalation calls go directly from this Mac to api.anthropic.com.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { step in
                let isActive = step <= current && current < 4
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            Text(stepLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
    private var stepLabel: String {
        switch current {
        case 1: return "Step 1 of 3: API key"
        case 2: return "Step 2 of 3: Accessibility"
        case 3: return "Step 3 of 3: Notifications"
        default: return "Setup complete"
        }
    }
}
