// PanelInvocation.swift — the app-facing layer that makes the deliberation
// panel invokable: the enable/mode setting, "which providers can I panel with",
// a default panel config, and a thin coordinator that dispatches DIY vs Fusion.
//
// This is deliberately decoupled from SwiftUI so it is fully unit-testable and
// cannot break the running app. The UI (a "Second opinion" action + a settings
// toggle) calls PanelCoordinator; PanelCoordinator.live builds the real clients
// from the configured keys at the composition root.

import Foundation

// MARK: - Setting

/// How a panel is run. `.diy` fans out across the user's own configured
/// providers with our judge; `.fusion` is one call to OpenRouter's server-side
/// Fusion. Default is `.diy` (runs on keys the user already has).
public enum PanelMode: String, Sendable, Equatable, CaseIterable, Codable {
    case diy
    case fusion

    public var title: String {
        switch self {
        case .diy:    return "Cross-provider panel"
        case .fusion: return "OpenRouter Fusion"
        }
    }

    public var summary: String {
        switch self {
        case .diy:    return "Fans your decision out across the providers you've configured, then a judge fuses the answers."
        case .fusion: return "One call to OpenRouter's Fusion. Needs an OpenRouter key."
        }
    }
}

/// Persisted accessor for the multi-model panel setting. Static facade over
/// UserDefaults (mirrors `DecisionSensitivityStore`). Default (nothing stored)
/// is DISABLED, so no install gets a 4-5x-cost panel unless the owner opts in.
public enum MultiModelPanelStore {
    public static let enabledKey = "supervisor.multiModelPanel.enabled"
    public static let modeKey = "supervisor.multiModelPanel.mode"

    /// Off unless the owner turns it on. `UserDefaults.bool` returns false for
    /// an unset key, which is exactly the default we want.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    public static func mode(defaults: UserDefaults = .standard) -> PanelMode {
        guard let raw = defaults.string(forKey: modeKey), let m = PanelMode(rawValue: raw) else {
            return .diy
        }
        return m
    }

    public static func setMode(_ mode: PanelMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}

// MARK: - Which providers can we panel with

public extension ProviderKeyStore {
    /// Providers that currently have a non-empty key stored, in `allCases`
    /// order. A read error on a single provider is treated as "unavailable"
    /// rather than propagated, so enumeration never throws.
    func availableProviders() -> [LLMProvider] {
        LLMProvider.allCases.filter { p in
            if let key = try? read(p), !key.isEmpty { return true }
            return false
        }
    }
}

// MARK: - Default config

public extension DeliberationPanel {
    /// A sensible DIY panel drawn from the available providers: up to
    /// `maxMembers` distinct providers as members and a capable judge. Returns
    /// nil when fewer than two DIY-eligible providers are available (a
    /// one-model "panel" is just a normal call, not a deliberation).
    ///
    /// OpenRouter is excluded from DIY members: it aggregates other models
    /// rather than contributing one distinct view, and its natural use is the
    /// Fusion mode, not a DIY seat.
    static func defaultConfig(available: [LLMProvider], maxMembers: Int = 3,
                              maxTokens: Int = 1024) -> PanelConfig? {
        let eligible = available.filter { $0 != .openrouter }
        guard eligible.count >= 2 else { return nil }
        let picked = Array(eligible.prefix(max(2, maxMembers)))
        // Judge: prefer Anthropic when present (strongest instruction-following
        // for the fuse step), else the first picked member.
        let judgeProvider = picked.contains(.anthropic) ? .anthropic : picked[0]
        let members = picked.map {
            PanelMember(provider: $0, model: $0.defaultTriageModel, label: $0.displayName)
        }
        let judge = PanelMember(provider: judgeProvider, model: judgeProvider.defaultTriageModel,
                                label: judgeProvider.displayName + " (judge)")
        return PanelConfig(members: members, judge: judge, maxTokens: maxTokens)
    }
}

// MARK: - Coordinator

/// Thin dispatcher the UI calls. Holds a built panel and the selected mode, and
/// runs a "second opinion" on a decision. Construction of the real clients is
/// in `live(...)` so this stays trivially testable with an injected panel.
public struct PanelCoordinator: Sendable {
    public let panel: DeliberationPanel
    public let mode: PanelMode

    public init(panel: DeliberationPanel, mode: PanelMode) {
        self.panel = panel
        self.mode = mode
    }

    public func secondOpinion(on decision: String, systemPreamble: String? = nil) async throws -> PanelResult {
        switch mode {
        case .diy:    return try await panel.deliberate(decision: decision, systemPreamble: systemPreamble)
        case .fusion: return try await panel.deliberateViaFusion(decision: decision, systemPreamble: systemPreamble)
        }
    }
}

public extension PanelCoordinator {
    /// Build a coordinator from the configured provider keys, or nil when the
    /// selected mode has no viable configuration (DIY with < 2 keys, or Fusion
    /// with no OpenRouter key). Never constructs a client for a keyless
    /// provider. The cost hooks are passed straight through to every member /
    /// judge client so panel spend counts against the same daily cap as triage.
    static func live(
        keyStore: ProviderKeyStore,
        mode: PanelMode,
        redactor: any Redactor,
        traceLog: TraceLog = .shared,
        costRecorder: (@Sendable (_ model: String, _ usage: AnthropicUsage) -> Void)? = nil,
        capCheck: (@Sendable () -> (cap: Double, spent: Double)?)? = nil
    ) -> PanelCoordinator? {
        func client(for p: LLMProvider) -> LLMClient? {
            guard let key = try? keyStore.read(p), !key.isEmpty else { return nil }
            return LLMClient(provider: p, apiKey: key, redactor: redactor, traceLog: traceLog,
                             costRecorder: costRecorder, capCheck: capCheck)
        }

        switch mode {
        case .fusion:
            guard let orClient = client(for: .openrouter) else { return nil }
            let cfg = PanelConfig(members: [],
                                  judge: PanelMember(provider: .openrouter,
                                                     model: DeliberationPanel.defaultFusionModel))
            return PanelCoordinator(panel: .live(config: cfg, clients: [.openrouter: orClient]),
                                    mode: .fusion)
        case .diy:
            let available = keyStore.availableProviders()
            guard let cfg = DeliberationPanel.defaultConfig(available: available) else { return nil }
            var clients: [LLMProvider: LLMClient] = [:]
            for p in Set(cfg.members.map { $0.provider } + [cfg.judge.provider]) {
                if let c = client(for: p) { clients[p] = c }
            }
            return PanelCoordinator(panel: .live(config: cfg, clients: clients), mode: .diy)
        }
    }
}
