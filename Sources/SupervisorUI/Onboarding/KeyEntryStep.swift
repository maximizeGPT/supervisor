// KeyEntryStep.swift
//
// Step 1 content body — API key entry. The step indicator and title now
// live on OnboardingScene; the primary "Validate & Save" button is in
// the footer. KeyEntryStep owns the provider picker (v0.2.0+), the
// description copy, the SecureField, and the inline error display.
//
// The `key` State lifts up to OnboardingScene as a `Binding<String>` so
// the footer's primary button can gate its disabled state on emptiness
// without coupling draft state into the view model.
//
// v0.2.0: a Picker bound to `vm.selectedProvider` sits above the field.
// Changing providers updates the field's placeholder text and the cost
// hint immediately. The actual `submitKey` call uses whatever provider
// is selected at the moment the user hits Validate.

import SwiftUI
import SupervisorCore

struct KeyEntryStep: View {

    @ObservedObject var vm: OnboardingViewModel
    let error: KeyEntryError?
    @Binding var key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Cost / provenance copy. Cost line is provider-specific so
            // the user understands what they're committing to before
            // pasting a key.
            Text(introCopy(for: vm.selectedProvider))
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.inkDeep.color)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            // Provider picker. .menu style keeps the row compact so the
            // SecureField sits at roughly the same vertical position as
            // before, and we don't push the footer out.
            HStack(spacing: 8) {
                Text("Provider:")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                Picker("", selection: $vm.selectedProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
                Spacer()
            }
            // Re-rendering on provider change is automatic because vm is
            // @ObservedObject and selectedProvider is @Published.
            .onChange(of: vm.selectedProvider) { _ in
                // Clear any previous error so a stale "key invalid for
                // Anthropic" message doesn't linger after switching to
                // a different provider.
                vm.clearKeyError()
            }

            SecureField(vm.selectedProvider.keyPlaceholder, text: $key, onCommit: submit)
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

    /// Per-provider intro copy. Anthropic keeps the v0.1.x cost line;
    /// other providers get a shorter, generic message because their
    /// pricing varies more wildly and we don't want to put a stale
    /// number in front of the user.
    private func introCopy(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. At heavy use, expect ~$80/month on your Anthropic bill (one continuous Claude Code session, all interventions enabled)."
        case .deepseek:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. DeepSeek's per-token pricing is roughly 1/30th of Anthropic's, so triage cost stays under $5/month at heavy use."
        case .moonshot:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. Kimi K2 has strong tool-calling and is competitively priced — expect single-digit dollars per month at heavy use."
        case .minimax:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. MiniMax's pricing varies by model — review their dashboard for current rates."
        case .qwenHF:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. Routed through the Hugging Face Inference router; pricing depends on the upstream provider selected. Expect higher latency than direct providers."
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
