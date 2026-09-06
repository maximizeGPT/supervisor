// KeyEntryStep.swift
//
// Step 1 content body, API key entry. The step indicator and title now
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
        VStack(alignment: .leading, spacing: BrandSpacing.md) {
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
            // before, and we don't push the footer out. The "Provider"
            // label uses the same caps/tracked overline treatment as the
            // panel's section headers, so the field reads as a labeled
            // control on the instrument panel rather than an ad-hoc row.
            VStack(alignment: .leading, spacing: BrandSpacing.xs) {
                BrandSectionHeader("Provider")
                Picker("", selection: $vm.selectedProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(BrandFont.body)
                .tint(BrandColor.signal.color)
                .frame(maxWidth: 200, alignment: .leading)
            }
            // Re-rendering on provider change is automatic because vm is
            // @ObservedObject and selectedProvider is @Published.
            .onChange(of: vm.selectedProvider) { _ in
                // Clear any previous error so a stale "key invalid for
                // Anthropic" message doesn't linger after switching to
                // a different provider.
                vm.clearKeyError()
            }

            VStack(alignment: .leading, spacing: BrandSpacing.xs) {
                BrandSectionHeader("API key")
                SecureField(vm.selectedProvider.keyPlaceholder, text: $key, onCommit: submit)
                    .textFieldStyle(.roundedBorder)
                    .font(BrandFont.body)
                    .onChange(of: key) { _ in vm.clearKeyError() }

                if let error {
                    // A failed validation is an attention state, not an alarm:
                    // the one calm amber tone the rest of the app uses for
                    // "needs a look" (SeverityBadge, a failed plan step), never
                    // a raw system red. A leading warning glyph matches the
                    // severity-badge vocabulary.
                    HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9, weight: .semibold))
                        Text(errorMessage(error))
                            .font(BrandFont.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(BrandColor.attention.color)
                    .transition(.opacity)
                }
            }
        }
        // The inline error appears on the calm "content reflow" curve.
        .animation(BrandMotion.standard, value: error != nil)
    }

    /// Per-provider intro copy. Anthropic keeps the v0.1.x cost line;
    /// other providers get a shorter, generic message because their
    /// pricing varies more wildly and we don't want to put a stale
    /// number in front of the user.
    private func introCopy(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. At heavy use, expect ~$80/month on your Anthropic bill (one continuous Claude Code session, all interventions enabled). A $5/day cap stops a runaway; heavy use is about $2.67/day, so it should never fire."
        case .deepseek:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. DeepSeek's per-token pricing is roughly 1/30th of Anthropic's, so triage cost stays under $5/month at heavy use."
        case .moonshot:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. Kimi K2 has strong tool-calling and is competitively priced. Expect single-digit dollars per month at heavy use."
        case .minimax:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. MiniMax pricing varies by model. Review their dashboard for current rates."
        case .qwenHF:
            return "Stored in macOS Keychain. Used only for Supervisor's triage and escalation calls. Routed through the Hugging Face Inference router; pricing depends on the upstream provider selected. Expect higher latency than direct providers."
        case .openrouter:
            return "Stored in macOS Keychain. OpenRouter routes to many models under one key and powers the multi-model deliberation panel. Cost depends on the models you pick; a panel bills every member plus the judge, so use it deliberately."
        }
    }

    private func submit() {
        let toSubmit = key
        Task { await vm.submitKey(toSubmit) }
    }

    private func errorMessage(_ err: KeyEntryError) -> String {
        let provider = vm.selectedProvider.displayName
        switch err {
        case .invalidKey(let m):       return "Key invalid: \(m)"
        case .rateLimit(let r?):       return "\(provider) is rate-limiting validation. Try again in ~\(Int(r))s."
        case .rateLimit(nil):          return "\(provider) is rate-limiting validation. Try again in a moment."
        case .network(let m):          return "Couldn't reach \(provider): \(m)"
        case .server(let s, let m):    return "\(provider) returned \(s): \(m)"
        case .unexpected(let m):       return "Unexpected error: \(m)"
        }
    }
}

struct KeyValidatingStep: View {
    /// The provider whose key is being validated, so the spinner copy
    /// names the provider the user actually picked (DeepSeek by default)
    /// rather than always saying "Anthropic".
    var providerName: String = "your provider"

    var body: some View {
        VStack(spacing: BrandSpacing.md) {
            ProgressView()
                .controlSize(.small)
                .tint(BrandColor.signal.color)
            Text("Validating your API key with \(providerName)…")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.mute.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
