// CustomizationStep.swift
//
// Step 4 content body, customization explanation. Shows the user where
// Supervisor's config files live, that editing them changes behavior,
// and where session reports are exported. A "Reveal in Finder" button
// opens the config folder so the user can inspect / edit the files.
//
// No state or view model dependency: this is a pure informational step.
// The step indicator, title ("Make it yours"), and the primary "Done"
// button all live on OnboardingScene.

import AppKit
import SwiftUI
import SupervisorCore

struct CustomizationStep: View {

    /// The real Application Support path, resolved at view init so the
    /// displayed string matches what Supervisor actually reads at runtime.
    private let configDir: URL
    private let reportsDir: String

    init() {
        let paths = ConfigPaths()
        self.configDir = paths.appSupportDir
        self.reportsDir = "~/Downloads/Supervisor Reports/"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.md) {
            Text("Supervisor reads its rules from plain files. Edit them and it changes how it triages, flags, and dispatches.")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            // Config folder card
            BrandCard {
                VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                    BrandSectionHeader("Rules folder")
                    Text(configDir.path)
                        .font(BrandFont.monoSmall)
                        .foregroundStyle(BrandColor.ink.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("PRINCIPLES.md is the operating manual Supervisor reads to decide how to act. config.yaml and rubric.yaml tune the triage and dispatch. Edit any of these to change behavior. Changes are picked up live.")
                        .font(BrandFont.note)
                        .foregroundStyle(BrandColor.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                    BrandSecondaryButton("Reveal in Finder") {
                        revealConfigFolder()
                    }
                }
            }

            // Exports card
            BrandCard {
                VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                    BrandSectionHeader("Session reports")
                    Text(reportsDir)
                        .font(BrandFont.monoSmall)
                        .foregroundStyle(BrandColor.ink.color)
                    Text("Exported session reports (JSON + Markdown) land here.")
                        .font(BrandFont.note)
                        .foregroundStyle(BrandColor.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func revealConfigFolder() {
        // selectFile with nil selects the folder itself and highlights it
        // in the enclosing directory. If the folder doesn't exist yet,
        // fall back to opening it (which creates + opens it).
        let path = configDir.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(configDir)
        }
    }
}
