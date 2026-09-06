// RemoteDeliveryHealthTests.swift
//
// C7: the delivery-health record the panel's Remote escalation row renders.
// Two layers: RemoteNotifier's bookkeeping (one attempt loop = one data
// point, failure runs accumulate, any success resets, gate-skips say
// nothing) and the pure line formatter (healthy / failing / silent-before-
// any-attempt wording).

import XCTest
@testable import SupervisorCore

final class RemoteDeliveryHealthTests: XCTestCase {

    private func makeNotifier(
        transport: RemoteNotifierTests.StubTransport,
        clock: RemoteNotifierTests.TestClock = RemoteNotifierTests.TestClock(),
        enabled: Bool = true
    ) throws -> RemoteNotifier {
        RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: enabled, dedupeWindow: 0, maxAttempts: 1, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("delivery-health-\(UUID()).log")),
            now: { [clock] in clock.now }
        )
    }

    private let pause = InterventionOutcome.pauseSucceeded(pid: 1, recoveryDocPath: nil)

    private func decision() -> TriageDecision {
        TriageDecision(
            sessionId: "sess-h",
            cwd: "/Users/test/proj",
            candidate: TriageCandidate(
                category: "destructive_action_pending", severity: .high,
                matchedCommand: "rm -rf x", action: .pause,
                reasoningPlain: "plain", reasoningTechnical: "technical"
            ),
            triggeringEvent: BashToolCallInfo(
                sessionId: "sess-h", command: "rm -rf x", description: nil,
                toolUseId: "t1", turnUUID: "u1", ts: Date()
            ),
            usage: AnthropicUsage(input_tokens: 1, output_tokens: 1),
            model: "haiku", prePost: .preExecution
        )
    }

    // MARK: - Bookkeeping

    func testFreshNotifierHasNoHealthToReport() throws {
        let notifier = try makeNotifier(transport: RemoteNotifierTests.StubTransport())
        XCTAssertEqual(notifier.deliveryHealth, RemoteNotifier.DeliveryHealth())
    }

    func testSuccessStampsLastSuccess() async throws {
        let clock = RemoteNotifierTests.TestClock()
        let notifier = try makeNotifier(transport: RemoteNotifierTests.StubTransport(), clock: clock)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        let health = notifier.deliveryHealth
        XCTAssertEqual(health.lastSuccessAt, clock.now)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertNil(health.firstFailureAt)
    }

    func testFailureRunAccumulatesAndKeepsItsFirstStamp() async throws {
        let transport = RemoteNotifierTests.StubTransport(results: [
            .success(404), .success(500), .success(204),
        ])
        let clock = RemoteNotifierTests.TestClock()
        let notifier = try makeNotifier(transport: transport, clock: clock)
        let firstFailureTime = clock.now

        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        clock.advance(120)
        _ = await notifier.sendTest()   // the test send is a delivery too
        var health = notifier.deliveryHealth
        XCTAssertEqual(health.consecutiveFailures, 2)
        XCTAssertEqual(health.firstFailureAt, firstFailureTime,
                       "the run keeps the FIRST failure's stamp, so the panel can say since when")
        XCTAssertEqual(health.lastFailureReason, "http_500")

        // Any success snaps the run shut.
        clock.advance(60)
        _ = await notifier.sendTest()
        health = notifier.deliveryHealth
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertNil(health.firstFailureAt)
        XCTAssertEqual(health.lastSuccessAt, clock.now)
    }

    func testGateSkipsDoNotTouchHealth() async throws {
        let notifier = try makeNotifier(transport: RemoteNotifierTests.StubTransport(), enabled: false)
        _ = await notifier.postInterventionResult(decision: decision(), outcome: pause)
        XCTAssertEqual(notifier.deliveryHealth, RemoteNotifier.DeliveryHealth(),
                       "a message that was not supposed to send says nothing about whether sending works")
    }

    // MARK: - Line formatter

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    func testLineIsSilentBeforeAnyAttempt() {
        XCTAssertNil(HoverViewModel.remoteHealthLine(nil, now: t0))
        XCTAssertNil(HoverViewModel.remoteHealthLine(RemoteNotifier.DeliveryHealth(), now: t0),
                     "an untested channel is unknown, not healthy")
    }

    @MainActor
    func testHealthyLineSaysWhenItLastDelivered() {
        let health = RemoteNotifier.DeliveryHealth(lastSuccessAt: t0.addingTimeInterval(-180))
        XCTAssertEqual(HoverViewModel.remoteHealthLine(health, now: t0), "Remote: delivered 3m ago")

        let recent = RemoteNotifier.DeliveryHealth(lastSuccessAt: t0.addingTimeInterval(-10))
        XCTAssertEqual(HoverViewModel.remoteHealthLine(recent, now: t0), "Remote: delivered just now")

        let old = RemoteNotifier.DeliveryHealth(lastSuccessAt: t0.addingTimeInterval(-7200))
        XCTAssertEqual(HoverViewModel.remoteHealthLine(old, now: t0), "Remote: delivered 2h ago")
    }

    @MainActor
    func testFailingLineCountsTheRunAndNamesItsStart() {
        let first = t0.addingTimeInterval(-600)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: first)

        let several = RemoteNotifier.DeliveryHealth(
            lastSuccessAt: t0.addingTimeInterval(-3600),
            consecutiveFailures: 3,
            firstFailureAt: first,
            lastFailureReason: "http_500"
        )
        XCTAssertEqual(HoverViewModel.remoteHealthLine(several, now: t0),
                       "Remote: last 3 attempts failed, first at \(clock)")

        let single = RemoteNotifier.DeliveryHealth(
            consecutiveFailures: 1, firstFailureAt: first, lastFailureReason: "transport"
        )
        XCTAssertEqual(HoverViewModel.remoteHealthLine(single, now: t0),
                       "Remote: last attempt failed at \(clock)")
    }

    @MainActor
    func testFailingOutranksAnOlderSuccess() {
        // Delivered an hour ago but failing since: the row must lead with
        // the failure, or the owner steps away trusting a dead channel.
        let health = RemoteNotifier.DeliveryHealth(
            lastSuccessAt: t0.addingTimeInterval(-3600),
            consecutiveFailures: 2,
            firstFailureAt: t0.addingTimeInterval(-300)
        )
        XCTAssertTrue(HoverViewModel.remoteHealthLine(health, now: t0)?.contains("failed") == true)
    }
}
