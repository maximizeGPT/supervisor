// PanelInvocationTests.swift — the app-facing panel layer (setting, available
// providers, default config, coordinator dispatch). No network; injected seams.

import XCTest
@testable import SupervisorCore

final class PanelInvocationTests: XCTestCase {

    private struct FakeKeyStore: ProviderKeyStore {
        var keys: [LLMProvider: String]
        func read(_ p: LLMProvider) throws -> String? { keys[p] }
        func write(_ key: String, for p: LLMProvider) throws {}
        func delete(_ p: LLMProvider) throws {}
    }

    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mmp-test-\(UUID().uuidString)")!
    }

    private func textResponse(model: String, text: String, i: Int = 1, o: Int = 1) -> AnthropicMessageResponse {
        AnthropicMessageResponse(
            id: "m", type: "message", role: "assistant", model: model,
            content: [AnthropicContentBlock(type: "text", text: text)],
            stop_reason: "end_turn", stop_sequence: nil,
            usage: AnthropicUsage(input_tokens: i, output_tokens: o,
                                  cache_creation_input_tokens: nil, cache_read_input_tokens: nil))
    }

    private func verdictResponse(_ consensus: String) -> AnthropicMessageResponse {
        AnthropicMessageResponse(
            id: "m", type: "message", role: "assistant", model: "judge",
            content: [AnthropicContentBlock(type: "tool_use", id: "t",
                name: DeliberationPanel.judgeToolName,
                input: .object([
                    "consensus": .string(consensus),
                    "contradictions": .array([]), "blind_spots": .array([]),
                    "unique_insights": .array([]),
                ]))],
            stop_reason: "tool_use", stop_sequence: nil,
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1,
                                  cache_creation_input_tokens: nil, cache_read_input_tokens: nil))
    }

    // MARK: - availableProviders

    func testAvailableProvidersReturnsOnlyKeyed() {
        let store = FakeKeyStore(keys: [.anthropic: "sk-ant", .deepseek: "", .openrouter: "sk-or"])
        let available = store.availableProviders()
        XCTAssertEqual(available, [.anthropic, .openrouter], "empty-string key is not available; order follows allCases")
    }

    func testAvailableProvidersEmptyWhenNoKeys() {
        XCTAssertTrue(FakeKeyStore(keys: [:]).availableProviders().isEmpty)
    }

    // MARK: - MultiModelPanelStore

    func testPanelSettingDefaultsToDisabledDIY() {
        let d = ephemeralDefaults()
        XCTAssertFalse(MultiModelPanelStore.isEnabled(defaults: d), "off by default — no surprise 4-5x cost")
        XCTAssertEqual(MultiModelPanelStore.mode(defaults: d), .diy)
    }

    func testPanelSettingRoundTrips() {
        let d = ephemeralDefaults()
        MultiModelPanelStore.setEnabled(true, defaults: d)
        MultiModelPanelStore.setMode(.fusion, defaults: d)
        XCTAssertTrue(MultiModelPanelStore.isEnabled(defaults: d))
        XCTAssertEqual(MultiModelPanelStore.mode(defaults: d), .fusion)
    }

    // MARK: - defaultConfig

    func testDefaultConfigNilWithFewerThanTwoEligible() {
        XCTAssertNil(DeliberationPanel.defaultConfig(available: []))
        XCTAssertNil(DeliberationPanel.defaultConfig(available: [.anthropic]))
        // OpenRouter alone is not DIY-eligible (it aggregates, not a distinct seat).
        XCTAssertNil(DeliberationPanel.defaultConfig(available: [.openrouter]))
    }

    func testDefaultConfigExcludesOpenRouterFromMembersAndPrefersAnthropicJudge() throws {
        let cfg = try XCTUnwrap(DeliberationPanel.defaultConfig(
            available: [.deepseek, .anthropic, .openrouter, .moonshot], maxMembers: 3))
        XCTAssertFalse(cfg.members.contains { $0.provider == .openrouter }, "OpenRouter is not a DIY member")
        XCTAssertEqual(cfg.members.count, 3)
        XCTAssertEqual(cfg.judge.provider, .anthropic, "judge prefers Anthropic when present")
    }

    func testDefaultConfigJudgeFallsBackToFirstMemberWhenNoAnthropic() throws {
        let cfg = try XCTUnwrap(DeliberationPanel.defaultConfig(available: [.deepseek, .moonshot]))
        XCTAssertEqual(cfg.judge.provider, .deepseek)
        XCTAssertEqual(cfg.members.count, 2)
    }

    // MARK: - Coordinator dispatch

    func testCoordinatorDIYRunsFanOutAndJudge() async throws {
        let cfg = PanelConfig(members: [PanelMember(provider: .anthropic, model: "a"),
                                        PanelMember(provider: .deepseek, model: "b")],
                              judge: PanelMember(provider: .anthropic, model: "judge"))
        let panel = DeliberationPanel(config: cfg) { _, req in
            req.tools != nil ? self.verdictResponse("DIY consensus")
                             : self.textResponse(model: req.model, text: "m")
        }
        let result = try await PanelCoordinator(panel: panel, mode: .diy)
            .secondOpinion(on: "decision")
        XCTAssertEqual(result.consensus, "DIY consensus")
        XCTAssertEqual(result.usage.memberCalls, 2)
        XCTAssertEqual(result.usage.judgeCalls, 1)
    }

    func testCoordinatorFusionRunsSingleCall() async throws {
        let cfg = PanelConfig(members: [], judge: PanelMember(provider: .openrouter, model: "openrouter/fusion"))
        var calls = 0
        let panel = DeliberationPanel(config: cfg) { provider, _ in
            calls += 1
            XCTAssertEqual(provider, .openrouter)
            return self.textResponse(model: "openrouter/fusion", text: "fusion consensus")
        }
        let result = try await PanelCoordinator(panel: panel, mode: .fusion)
            .secondOpinion(on: "decision")
        XCTAssertEqual(result.consensus, "fusion consensus")
        XCTAssertEqual(calls, 1, "Fusion is one call, not a fan-out")
    }

    // MARK: - Provider-key management (panel settings "Add a provider")

    func testComputePanelReady() {
        XCTAssertFalse(HoverViewModel.computePanelReady(from: []))
        XCTAssertFalse(HoverViewModel.computePanelReady(from: [.deepseek]), "one provider is not a panel")
        XCTAssertTrue(HoverViewModel.computePanelReady(from: [.deepseek, .qwenHF]), "two providers -> DIY")
        XCTAssertTrue(HoverViewModel.computePanelReady(from: [.openrouter]), "OpenRouter alone -> Fusion")
        XCTAssertFalse(HoverViewModel.computePanelReady(from: [.openrouter, .deepseek].filter { $0 == .deepseek }),
                       "one non-OpenRouter provider is not enough for DIY")
    }

    private final class KeyWriteBox: @unchecked Sendable { var calls: [(LLMProvider, String)] = [] }

    @MainActor
    func testAddProviderKeyFlipsPanelReadyOn() async {
        let vm = HoverViewModel(bus: EventBus(trace: .shared))
        vm.setConfiguredProviders([.deepseek])
        XCTAssertFalse(vm.panelReady, "one provider -> panel not ready")

        let box = KeyWriteBox()
        vm.addProviderKeyHandler = { provider, key in
            box.calls.append((provider, key))
            return [.deepseek, .qwenHF]   // the store now has two
        }
        vm.addProviderKey(.qwenHF, key: "  hf_test_key  ")
        for _ in 0..<200 { if !vm.isSavingProviderKey { break }; try? await Task.sleep(nanoseconds: 2_000_000) }

        XCTAssertEqual(box.calls.first?.0, .qwenHF)
        XCTAssertEqual(box.calls.first?.1, "hf_test_key", "the key is trimmed before storing")
        XCTAssertEqual(vm.configuredProviders, [.deepseek, .qwenHF])
        XCTAssertTrue(vm.panelReady, "adding a second provider flips panelReady on without a relaunch")
    }

    @MainActor
    func testAddProviderKeySurfacesKeychainWriteFailure() async {
        struct KeychainWriteError: Error {}
        let vm = HoverViewModel(bus: EventBus(trace: .shared))
        vm.setConfiguredProviders([.deepseek])

        // The Keychain write throws: the VM must surface the failure, keep the
        // configured set unchanged, and never claim the key was saved.
        vm.addProviderKeyHandler = { _, _ in throw KeychainWriteError() }
        vm.addProviderKey(.qwenHF, key: "hf_x")
        for _ in 0..<200 { if !vm.isSavingProviderKey { break }; try? await Task.sleep(nanoseconds: 2_000_000) }

        XCTAssertNotNil(vm.providerKeySaveError,
                        "a thrown Keychain write must surface an error, not claim saved")
        XCTAssertTrue(vm.providerKeySaveError?.contains("NOT stored") == true,
                      "the error must say the key was not stored: \(vm.providerKeySaveError ?? "nil")")
        XCTAssertEqual(vm.configuredProviders, [.deepseek],
                       "a failed write must not change the configured providers")
        XCTAssertFalse(vm.panelReady, "panelReady must not flip on a failed save")

        // A subsequent successful save clears the error and applies normally.
        vm.addProviderKeyHandler = { _, _ in [.deepseek, .qwenHF] }
        vm.addProviderKey(.qwenHF, key: "hf_x")
        for _ in 0..<200 { if !vm.isSavingProviderKey { break }; try? await Task.sleep(nanoseconds: 2_000_000) }

        XCTAssertNil(vm.providerKeySaveError, "a successful retry clears the surfaced failure")
        XCTAssertEqual(vm.configuredProviders, [.deepseek, .qwenHF])
        XCTAssertTrue(vm.panelReady)
    }

    @MainActor
    func testAddProviderKeyIgnoresEmptyOrNoHandler() async {
        let vm = HoverViewModel(bus: EventBus(trace: .shared))
        vm.setConfiguredProviders([.deepseek])
        // No handler wired.
        vm.addProviderKey(.qwenHF, key: "hf_x")
        XCTAssertFalse(vm.isSavingProviderKey)
        XCTAssertEqual(vm.configuredProviders, [.deepseek], "no handler -> no change")
        // Empty key.
        vm.addProviderKeyHandler = { _, _ in [.deepseek, .qwenHF] }
        vm.addProviderKey(.qwenHF, key: "   ")
        XCTAssertFalse(vm.isSavingProviderKey, "empty key is a no-op")
        XCTAssertEqual(vm.configuredProviders, [.deepseek])
    }
}
