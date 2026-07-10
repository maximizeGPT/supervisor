// CodexAgentIdentityTests.swift
//
// The UX data-flow: AgentKind derives from a session's projectHash (no event
// or DB schema change), and HoverViewModel exposes currentAgent + isMultiAgent
// so the agent chip shows only when Supervisor is watching more than one agent.

import XCTest
@testable import SupervisorCore

@MainActor
final class CodexAgentIdentityTests: XCTestCase {

    func testAgentKindDerivesFromProjectNamespace() {
        XCTAssertEqual(AgentKind(projectNamespace: "codex"), .codex)
        XCTAssertEqual(AgentKind(projectNamespace: "-Users-main"), .claudeCode)
        XCTAssertEqual(AgentKind(projectNamespace: ""), .claudeCode)
        XCTAssertEqual(AgentKind.codex.projectNamespace, "codex")
        XCTAssertNil(AgentKind.claudeCode.projectNamespace)
        XCTAssertEqual(AgentKind.codex.shortName, "Codex")
        XCTAssertEqual(AgentKind.claudeCode.displayName, "Claude Code")
    }

    private func makeVM() -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-id-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        return (HoverViewModel(bus: bus, trace: trace), bus)
    }

    private func start(_ bus: EventBus, sessionId: String, projectHash: String) {
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: sessionId, cwd: "/x/\(sessionId)", gitBranch: "main",
            projectHash: projectHash, jsonlPath: "/tmp/\(sessionId).jsonl", ts: Date())))
    }

    // A Claude-Code-only user sees no agent chip; once a Codex session appears,
    // the chip is enabled and stays enabled (so any session stays legible).
    func testMultiAgentGating() async {
        let (vm, bus) = makeVM()

        start(bus, sessionId: "cc1", projectHash: "-Users-main")
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(vm.currentAgent, .claudeCode)
        XCTAssertFalse(vm.isMultiAgent, "single agent kind: no chip")

        start(bus, sessionId: "cx1", projectHash: "codex")
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(vm.currentAgent, .codex)
        XCTAssertTrue(vm.isMultiAgent, "second agent kind: chip enabled")

        start(bus, sessionId: "cc2", projectHash: "-Users-main")
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(vm.currentAgent, .claudeCode)
        XCTAssertTrue(vm.isMultiAgent, "chip stays enabled once both are seen")
    }
}
