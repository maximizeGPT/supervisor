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
            Text("Required so Supervisor can send text into your terminal when an intervention fires. macOS will route you to System Settings → Privacy & Security → Accessibility — enable “Supervisor” in the list, then this step advances on its own.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            if prompted {
                Label("Waiting for grant…", systemImage: "hourglass")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
            }

            Text("Skip is fine — v0.1.0's intervention surface is notify-only and doesn't use Accessibility. Inject (v0.1.1+) will prompt you again when it's needed. If macOS isn't accepting your grant (a known unsigned-app pattern), use Skip and continue.")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
