// AXCheckStep.swift
//
// Step 2: Accessibility permission. macOS doesn't have an in-app grant
// flow for AX — the user has to flip a switch in System Settings, after
// which Supervisor polls and advances. We prompt once (which opens the
// settings sheet) and then wait.

import AppKit
import SwiftUI
import SupervisorCore

struct AXCheckStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let prompted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. Accessibility access")
                .font(.system(size: 14, weight: .semibold))

            Text("Required so Supervisor can send text into your terminal when an intervention fires. macOS will route you to System Settings → Privacy & Security → Accessibility — enable “Supervisor” in the list, then this step advances on its own.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(PermissionSettingsURL.accessibility)
                    vm.promptForAX()
                }
                .keyboardShortcut(.defaultAction)

                Button("Re-check now") {
                    Task { await vm.recheckAX() }
                }

                Spacer()

                if prompted {
                    Label("Waiting for grant…", systemImage: "hourglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Tip: if Supervisor doesn't appear in the list after you click the toggle, drag Supervisor.app from Finder into the list.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
