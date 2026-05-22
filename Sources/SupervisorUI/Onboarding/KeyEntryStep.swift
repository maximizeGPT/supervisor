// KeyEntryStep.swift
//
// Step 1: Anthropic API key entry. Live validation; inline error surfaces
// next to the field on bad input without restarting onboarding.

import SwiftUI
import SupervisorCore

struct KeyEntryStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let error: KeyEntryError?

    @State private var key: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Anthropic API key")
                .font(.system(size: 14, weight: .semibold))

            Text("Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. At heavy use, expect ~$80/month on your Anthropic bill (one continuous Claude Code session, all interventions enabled).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-...", text: $key, onCommit: submit)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { _ in vm.clearKeyError() }

            if let error {
                Text(errorMessage(error))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Validate & Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
