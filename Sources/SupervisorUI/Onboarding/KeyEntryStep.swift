// KeyEntryStep.swift
//
// Step 1 content body — Anthropic API key entry. The step indicator and
// title now live on OnboardingScene; the primary "Validate & Save" button
// moved to the footer. KeyEntryStep keeps the description copy, the
// SecureField, and the inline error display.
//
// The `key` State lifts up to OnboardingScene as a `Binding<String>` so
// the footer's primary button can gate its disabled state on emptiness
// without coupling draft state into the view model.

import SwiftUI
import SupervisorCore

struct KeyEntryStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let error: KeyEntryError?
    @Binding var key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. At heavy use, expect ~$80/month on your Anthropic bill (one continuous Claude Code session, all interventions enabled).")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-...", text: $key, onCommit: submit)
                .textFieldStyle(.roundedBorder)
                .font(BrandFont.body)
                .onChange(of: key) { _ in vm.clearKeyError() }

            if let error {
                Text(errorMessage(error))
                    .font(BrandFont.note)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        let toSubmit = key
        Task { await vm.submitKey(toSubmit) }
    }

    private func errorMessage(_ err: KeyEntryError) -> String {
        switch err {
        case .invalidKey(let m):       return "Key invalid: \(m)"
        case .rateLimit(let r?):       return "Anthropic is rate-limiting validation. Try again in ~\(Int(r))s."
        case .rateLimit(nil):          return "Anthropic is rate-limiting validation. Try again in a moment."
        case .network(let m):          return "Couldn't reach Anthropic: \(m)"
        case .server(let s, let m):    return "Anthropic returned \(s): \(m)"
        case .unexpected(let m):       return "Unexpected error: \(m)"
        }
    }
}

struct KeyValidatingStep: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Validating with Anthropic…")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.mute.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
