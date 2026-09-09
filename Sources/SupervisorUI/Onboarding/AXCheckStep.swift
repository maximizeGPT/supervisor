// AXCheckStep.swift
//
// Step 2 content body, Accessibility permission. The step indicator and
// title now live on OnboardingScene. The "Open System Settings" primary
// and the "Skip" secondary both moved to the footer (Skip is left,
// primary right). "Re-check now" is gone entirely, vm.tick() polls
// every 1.5s and advances the moment AX is granted.

import AppKit
import SwiftUI
import SupervisorCore

struct AXCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let prompted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.md) {
            Text(bodyText)
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

    /// Upgrading is the common way to land back on this screen, and it is not
    /// the user's doing. macOS ties an Accessibility grant to the certificate
    /// that signed the app, so replacing Supervisor with a build signed
    /// differently reads as a different program and the grant is dropped. The
    /// old entry is usually still sitting in the list, switched off. Saying so
    /// turns a confusing repeat of setup into one switch. See
    /// docs/upgrading.md.
    private var bodyText: String {
        if vm.flow.isRegrant {
            return "Supervisor was replaced by a newer build, and macOS drops Accessibility when an app is replaced. Open System Settings, go to Privacy and Security, then Accessibility, and switch Supervisor back on. Your API key and settings are still there, though the same change of signing identity can make macOS ask once for permission to use your Keychain."
        }
        return "Supervisor needs Accessibility access to type into your terminal when it acts for you. Open System Settings, then turn Supervisor on under Privacy and Security, then Accessibility."
    }
}
