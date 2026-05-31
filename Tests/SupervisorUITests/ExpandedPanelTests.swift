// ExpandedPanelTests.swift — v0.1.7.
//
// Coverage for the expanded panel feature: session metrics tracking
// (turn count, tool call count), toggle state, cost formatting,
// relative time display, and flag list population.

import XCTest
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class ExpandedPanelTests: XCTestCase {

    private func makeVM(
        initialFlagCount: Int = 0,
        modelName: String = "claude-haiku-4-5-20251001"
    ) -> (HoverViewModel, EventBus) {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        let vm = HoverViewModel(
            bus: bus,
            trace: trace,
            initialFlagCount: initialFlagCount,
            modelName: modelName
        )
        return (vm, bus)
    }

    // MARK: - Session metrics

    func testTurnCountIncreasesOnUserPrompt() {
        let (vm, bus) = makeVM()
        XCTAssertEqual(vm.turnCount, 0)

        bus.publish(.userPrompt(UserPromptInfo(
            sessionId: "s1", text: "fix the bug", ts: Date()
        )))
        // EventBus dispatches via Task; give it a tick.
        let exp = expectation(description: "turn count updated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 1)
    }

    func testToolCallCountIncreasesOnBashToolCall() {
        let (vm, bus) = makeVM()
        XCTAssertEqual(vm.toolCallCount, 0)

        bus.publish(.bashToolCall(BashToolCallInfo(
            sessionId: "s1", command: "git status", description: nil,
            toolUseId: "t1", turnUUID: "u1", ts: Date()
        )))
        let exp = expectation(description: "tool count updated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(vm.toolCallCount, 1)
    }

    func testSessionStartResetsMetrics() {
        let (vm, bus) = makeVM()

        // Accumulate some counts.
        bus.publish(.userPrompt(UserPromptInfo(
            sessionId: "s1", text: "hello", ts: Date()
        )))
        bus.publish(.bashToolCall(BashToolCallInfo(
            sessionId: "s1", command: "ls", description: nil,
            toolUseId: "t1", turnUUID: "u1", ts: Date()
        )))
        let exp1 = expectation(description: "counts accumulated")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 1)
        XCTAssertEqual(vm.toolCallCount, 1)

        // New session resets.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "s2", cwd: "/Users/main/new-project",
            gitBranch: "main", projectHash: "hash",
            jsonlPath: "/tmp/test.jsonl", ts: Date()
        )))
        let exp2 = expectation(description: "metrics reset")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
        XCTAssertEqual(vm.turnCount, 0)
        XCTAssertEqual(vm.toolCallCount, 0)
        XCTAssertEqual(vm.sessionCwd, "/Users/main/new-project")
    }

    // MARK: - Toggle

    func testToggleExpandedFlipsState() {
        let (vm, _) = makeVM()
        XCTAssertFalse(vm.isExpanded)
        vm.toggleExpanded()
        XCTAssertTrue(vm.isExpanded)
        vm.toggleExpanded()
        XCTAssertFalse(vm.isExpanded)
    }

    // MARK: - Model name

    func testModelNameSetAtInit() {
        let (vm, _) = makeVM(modelName: "deepseek-chat")
        XCTAssertEqual(vm.modelName, "deepseek-chat")
    }

    // MARK: - Cost formatting

    func testFormatCostZero() {
        XCTAssertEqual(ExpandedPanelView.formatCost(0), "$0.00")
    }

    func testFormatCostSubPenny() {
        XCTAssertEqual(ExpandedPanelView.formatCost(0.005), "$0.00")
    }

    func testFormatCostNormal() {
        XCTAssertEqual(ExpandedPanelView.formatCost(1.234), "$1.23")
    }

    func testFormatCostLarge() {
        XCTAssertEqual(ExpandedPanelView.formatCost(42.50), "$42.50")
    }

    // MARK: - Relative time

    func testRelativeTimeJustNow() {
        let recent = Date().addingTimeInterval(-30)
        XCTAssertEqual(ExpandedPanelView.relativeTime(recent), "just now")
    }

    func testRelativeTimeMinutes() {
        let fiveMinAgo = Date().addingTimeInterval(-300)
        XCTAssertEqual(ExpandedPanelView.relativeTime(fiveMinAgo), "5m")
    }

    func testRelativeTimeHours() {
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        XCTAssertEqual(ExpandedPanelView.relativeTime(twoHoursAgo), "2h")
    }

    func testRelativeTimeDays() {
        let twoDaysAgo = Date().addingTimeInterval(-172800)
        XCTAssertEqual(ExpandedPanelView.relativeTime(twoDaysAgo), "2d")
    }

    // MARK: - No stores returns sensible defaults

    func testTodayCostWithoutStoreReturnsZero() {
        let (vm, _) = makeVM()
        XCTAssertEqual(vm.todayCostUSD(), 0)
    }

    func testRecentFlagsWithoutStoreReturnsEmpty() {
        let (vm, _) = makeVM()
        XCTAssertTrue(vm.recentFlags().isEmpty)
    }
}
