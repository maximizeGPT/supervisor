// AXCheckStep.swift
//
// Step 2 content body — Accessibility permission. The step indicator and
// title now live on OnboardingScene. The "Open System Settings" primary
// and the "Skip" secondary both moved to the footer (Skip is left,
// primary right). "Re-check now" is gone entirely — vm.tick() polls
// every 1.5s and advances the moment AX is granted.

import AppKit
import SwiftUI
import SupervisorCore

struct AXCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let prompted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supervisor needs Accessibility access to type into your terminal when it acts for you. Open System Settings, then turn Supervisor on under Privacy and Security, then Accessibility.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            if prompted {
                Text("This step continues by itself once macOS reports the grant. If it does not continue within a few seconds, click Continue. macOS sometimes fails to report the grant for self built apps, so Continue moves you forward either way.")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("You can skip this. Supervisor still watches and notifies without it. It asks again when it needs to type.")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
