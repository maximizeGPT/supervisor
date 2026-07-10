// ScreenRecordingCheckStep.swift
//
// Step 3 content body, Screen Recording permission. Modeled exactly on
// AXCheckStep: the step indicator and title live on OnboardingScene, the
// "Open System Settings" primary and the "Skip" secondary live in the
// footer (Skip left, primary right). vm.tick() polls every 1.5s and
// advances the moment Screen Recording is granted.
//
// Why Supervisor needs it: when it drives a plan or answers a question in
// the Claude desktop app, it screenshots and reads the conversation
// sidebar on-device to pick the right conversation before it acts. Without
// Screen Recording it cannot tell which conversation to target, so desktop
// driving and answering degrade to a notify and the work never lands.
//
// RC fix #6: macOS does not apply a freshly-granted Screen Recording
// permission to an already-running process — capture keeps failing until the
// app is quit and relaunched, even though System Settings shows the grant on.
// The step now says so up front, and once the grant is observed it surfaces a
// "Quit & relaunch Supervisor" affordance (driven by
// vm.screenRecordingNeedsRelaunch) so the user is not left with a
// granted-but-not-effective permission.

import AppKit
import SwiftUI
import SupervisorCore

struct ScreenRecordingCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let prompted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.md) {
            Text("Supervisor needs Screen Recording to see which Claude conversation to drive or answer. It screenshots the Claude desktop window and reads the sidebar on your Mac. Open System Settings, then turn Supervisor on under Privacy and Security, then Screen Recording. macOS only applies the grant after Supervisor is quit and relaunched, so plan on relaunching once you have turned it on.")
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
                Text("You can skip this. Supervisor still watches and notifies without it. Without Screen Recording it cannot drive or answer inside the Claude desktop app, so it falls back to a notification you act on yourself.")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Granted-but-not-effective: macOS reported the grant, but capture
            // stays broken until relaunch. Surface the relaunch affordance so
            // the permission actually takes effect (RC fix #6).
            if vm.screenRecordingNeedsRelaunch {
                relaunchNotice
            }
        }
    }

    private var relaunchNotice: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            Text("Screen Recording is granted, but macOS needs Supervisor to relaunch before it can capture. Quit and relaunch to finish.")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.attention.color)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit & relaunch Supervisor", action: quitAndRelaunch)
                .buttonStyle(.borderedProminent)
        }
        .padding(BrandSpacing.sm)
        .background(
            BrandColor.attention.color.opacity(0.10),
            in: RoundedRectangle(cornerRadius: BrandRadius.control)
        )
    }

    /// Best-effort quit & relaunch: schedule a detached `open` of this app
    /// bundle a moment after the current process exits, then terminate. Uses a
    /// plain `open` (not `-n`) so the single-instance guard accepts the fresh
    /// launch once this process is gone.
    private func quitAndRelaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
