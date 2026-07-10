// PanelLiveIntegrationTests.swift — LIVE, real-API proof that the multi-model
// panel works end-to-end across real providers. Gated by SUPERVISOR_LIVE_API=1
// AND provider key env vars, so it never runs (or costs) in a normal test pass.
//
// Run: export the configured keys into the environment and
//   SUPERVISOR_LIVE_API=1 swift test --filter PanelLiveIntegrationTests
//
// It exercises the EXACT path the hover "Second opinion" uses: PanelCoordinator
// built from a key store, then a real deliberation. Member fault-tolerance is
// part of what's proven — a provider that fails its call is captured, and the
// panel still fuses the rest.

import XCTest
@testable import SupervisorCore

final class PanelLiveIntegrationTests: XCTestCase {

    /// An env-backed key store so the live test uses the real PanelCoordinator
    /// path without touching Keychain (mirrors the calibration harness reading
    /// keys from the environment).
    private struct EnvKeyStore: ProviderKeyStore {
        let keys: [LLMProvider: String]
        func read(_ p: LLMProvider) throws -> String? { keys[p] }
        func write(_ key: String, for p: LLMProvider) throws {}
        func delete(_ p: LLMProvider) throws {}
    }

    private func envKeys() -> [LLMProvider: String] {
        let map: [(String, LLMProvider)] = [
            ("DEEPSEEK_API_KEY", .deepseek),
            ("MOONSHOT_API_KEY", .moonshot),
            ("MINIMAX_API_KEY", .minimax),
            ("QWEN_HF_API_KEY", .qwenHF),
            ("OPENROUTER_API_KEY", .openrouter),
        ]
        var out: [LLMProvider: String] = [:]
        for (env, p) in map {
            if let k = ProcessInfo.processInfo.environment[env], !k.isEmpty { out[p] = k }
        }
        return out
    }

    private func requireLive() throws -> [LLMProvider: String] {
        guard ProcessInfo.processInfo.environment["SUPERVISOR_LIVE_API"] != nil else {
            throw XCTSkip("set SUPERVISOR_LIVE_API=1 + provider key env vars to run the live panel test")
        }
        return envKeys()
    }

    private func trace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-live-\(UUID().uuidString).log"))
    }

    private let decision = """
    A coding agent is about to run `git reset --hard` after the user only said \
    "clean things up." Give your own independent assessment: is this genuinely \
    risky, is it warranted, and what should the user watch for?
    """

    /// The exact composition-root path: PanelCoordinator.live(keyStore:mode:.diy)
    /// then secondOpinion. Proves a real cross-provider panel fuses a verdict.
    func testLiveDIYPanelViaCoordinator() async throws {
        let keys = try requireLive()
        let diyKeys = keys.filter { $0.key != .openrouter }
        try XCTSkipIf(diyKeys.count < 2, "need >= 2 non-OpenRouter provider keys for a DIY panel; have \(diyKeys.count)")

        guard let coordinator = PanelCoordinator.live(
            keyStore: EnvKeyStore(keys: keys),
            mode: .diy,
            redactor: DefaultRedactor(),
            traceLog: trace()
        ) else {
            return XCTFail("PanelCoordinator.live returned nil despite \(diyKeys.count) providers")
        }

        let result = try await coordinator.secondOpinion(on: decision)

        print("=== LIVE DIY PANEL (coordinator path) ===")
        printResult(result)

        XCTAssertFalse(result.consensus.isEmpty, "the panel must produce a non-empty consensus")
        XCTAssertGreaterThan(result.perMember.filter { $0.succeeded }.count, 0,
                             "at least one panel member must answer for real")
        XCTAssertGreaterThan(result.usage.inputTokens + result.usage.outputTokens, 0,
                             "real token usage must be recorded")
    }

    /// The DeliberationPanel directly, so the report enumerates EVERY configured
    /// provider's success/failure — the live health check of each OpenAI-compat
    /// integration (DeepSeek / Moonshot / MiniMax / Qwen-HF).
    func testLiveEveryProviderAnswers() async throws {
        let keys = try requireLive()
        let diyKeys = keys.filter { $0.key != .openrouter }
        try XCTSkipIf(diyKeys.isEmpty, "no provider keys in env")

        var clients: [LLMProvider: LLMClient] = [:]
        var members: [PanelMember] = []
        for (p, key) in diyKeys.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            clients[p] = LLMClient(provider: p, apiKey: key, redactor: DefaultRedactor(), traceLog: trace())
            members.append(PanelMember(provider: p, model: p.defaultTriageModel, label: p.displayName))
        }
        let judge = members.first { $0.provider == .deepseek } ?? members[0]
        let panel = DeliberationPanel.live(
            config: PanelConfig(members: members, judge: judge),
            clients: clients
        )

        // Use the panel's own deliberate so member failures are captured, not fatal.
        let result = try await panel.deliberate(decision: decision)

        print("=== LIVE PANEL — per-provider health ===")
        printResult(result)
        for m in result.perMember {
            print("  \(m.member.label): \(m.succeeded ? "OK (\(m.text.prefix(60))...)" : "FAILED — \(m.error ?? "?")")")
        }

        // Non-gating visibility: at least one provider must work for the panel to
        // be usable, but we do not fail the whole run because e.g. the HF router
        // is flaky — the fault-tolerance is the point. We DO assert the panel
        // surfaced every configured provider so a silent drop is caught.
        XCTAssertEqual(result.perMember.count, members.count,
                       "every configured member must be reported (success or captured failure)")
        XCTAssertGreaterThan(result.perMember.filter { $0.succeeded }.count, 0,
                             "at least one provider must answer for the panel to be usable")
    }

    private func printResult(_ r: PanelResult) {
        print("degraded: \(r.degraded)")
        print("consensus: \(r.consensus)")
        if !r.contradictions.isEmpty { print("contradictions: \(r.contradictions)") }
        if !r.blindSpots.isEmpty { print("blindSpots: \(r.blindSpots)") }
        if !r.uniqueInsights.isEmpty { print("uniqueInsights: \(r.uniqueInsights)") }
        print("members answered: \(r.perMember.filter { $0.succeeded }.count)/\(r.perMember.count)")
        print("usage: in=\(r.usage.inputTokens) out=\(r.usage.outputTokens) memberCalls=\(r.usage.memberCalls) judgeCalls=\(r.usage.judgeCalls)")
    }
}
