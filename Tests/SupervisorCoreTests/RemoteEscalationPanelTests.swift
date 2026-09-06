// RemoteEscalationPanelTests.swift
//
// The hover panel's Remote escalation row, at the view-model layer: seeding,
// the honest save flow (state follows the Keychain write, never precedes
// it), the config toggle's write-then-reflect rule, and the "Send test"
// lifecycle. Follows the HoverLabelTests construction pattern (a VM over a
// throwaway bus + trace); the handlers are closures, so no Keychain, no
// config file, and no network appear anywhere in this file.
//
// The RemoteNotifier.sendTest half — the method the app wires the button to
// — is exercised at the bottom against the stub transport, because a green
// panel result must mean bytes actually reached the endpoint.

import XCTest
@testable import SupervisorCore

@MainActor
final class RemoteEscalationPanelTests: XCTestCase {

    private func makeVM() -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-escalation-panel-\(UUID()).log"))
        return HoverViewModel(bus: EventBus(trace: trace), trace: trace)
    }

    /// Spin the main actor until `condition` holds (the handlers hop through
    /// a Task, so the published state lands one turn later).
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeoutSeconds: TimeInterval = 2,
        _ message: String = ""
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - Seeding

    func testSeedReflectsCurrentStateOnFirstOpen() {
        let vm = makeVM()
        XCTAssertFalse(vm.remoteWebhookConfigured)
        XCTAssertFalse(vm.remoteNotifyEnabled)

        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .full)
        XCTAssertTrue(vm.remoteWebhookConfigured)
        XCTAssertTrue(vm.remoteNotifyEnabled)
        XCTAssertEqual(vm.remoteNotifyDetail, .full)
        XCTAssertEqual(vm.remoteEscalationStatusLine, "Webhook stored. Delivery is on (full).")
    }

    func testStatusLineForEachState() {
        let vm = makeVM()
        XCTAssertTrue(vm.remoteEscalationStatusLine.contains("No webhook URL stored"))
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal)
        XCTAssertEqual(vm.remoteEscalationStatusLine, "Webhook stored. Delivery is off.")
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        XCTAssertEqual(vm.remoteEscalationStatusLine, "Webhook stored. Delivery is on (minimal).")
    }

    // MARK: - Webhook save

    func testInvalidURLIsRejectedBeforeTheHandlerRuns() async {
        let vm = makeVM()
        let called = Counter()
        vm.saveRemoteWebhookHandler = { _ in called.bump() }

        vm.saveRemoteWebhook("http://discord.com/api/webhooks/1/t")
        XCTAssertNotNil(vm.remoteWebhookSaveError, "a plaintext URL must be refused in the panel")
        XCTAssertTrue(vm.remoteWebhookSaveError?.contains("https") == true)
        XCTAssertFalse(vm.remoteWebhookConfigured)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(called.value, 0, "nothing may reach the Keychain path on a shape failure")
    }

    func testSaveErrorNeverContainsTheURL() {
        let vm = makeVM()
        vm.saveRemoteWebhookHandler = { _ in }
        vm.saveRemoteWebhook("ftp://hooks.example.com/SECRET-TOKEN-XYZ")
        XCTAssertNotNil(vm.remoteWebhookSaveError)
        XCTAssertFalse(vm.remoteWebhookSaveError?.contains("SECRET-TOKEN-XYZ") == true,
                       "the error renders on screen; the URL is a bearer credential")
    }

    func testSuccessfulSaveFlipsConfigured() async {
        let vm = makeVM()
        let saved = Box<String>()
        vm.saveRemoteWebhookHandler = { url in saved.value = url }

        vm.saveRemoteWebhook("  https://discord.com/api/webhooks/1/token  ")
        await waitUntil(vm.remoteWebhookConfigured, "save must complete and flip configured")
        XCTAssertNil(vm.remoteWebhookSaveError)
        XCTAssertFalse(vm.isSavingRemoteWebhook)
        XCTAssertEqual(saved.value, "https://discord.com/api/webhooks/1/token",
                       "the handler receives the trimmed URL")
    }

    func testFailedKeychainWriteSurfacesAndDoesNotClaimConfigured() async {
        struct KeychainDown: Error {}
        let vm = makeVM()
        vm.saveRemoteWebhookHandler = { _ in throw KeychainDown() }

        vm.saveRemoteWebhook("https://discord.com/api/webhooks/1/token")
        await waitUntil(vm.remoteWebhookSaveError != nil, "the failure must surface")
        XCTAssertFalse(vm.remoteWebhookConfigured,
                       "a failed write must never show as a stored webhook")
        XCTAssertTrue(vm.remoteWebhookSaveError?.contains("NOT stored") == true)
    }

    func testMissingHandlerIsAnHonestFailureNotASilentDrop() {
        let vm = makeVM()
        vm.saveRemoteWebhook("https://discord.com/api/webhooks/1/token")
        XCTAssertEqual(vm.remoteWebhookSaveError, "Saving is unavailable.")
        XCTAssertFalse(vm.remoteWebhookConfigured)
    }

    // MARK: - Enabled / detail toggle

    func testToggleReflectsOnlyAfterTheWriteSucceeds() async {
        let vm = makeVM()
        let written = Box<(Bool, RemoteNotifyDetail)>()
        vm.setRemoteNotifyHandler = { enabled, detail, _ in
            written.value = (enabled, detail)
            return true
        }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal)

        vm.setRemoteNotifyEnabled(true)
        await waitUntil(vm.remoteNotifyEnabled, "state follows the successful write")
        XCTAssertEqual(written.value?.0, true)

        vm.setRemoteNotifyDetail(.full)
        await waitUntil(vm.remoteNotifyDetail == .full)
        XCTAssertEqual(written.value?.1, .full)
        XCTAssertTrue(vm.remoteNotifyEnabled, "detail change must not disturb the switch")
    }

    func testFailedConfigWriteLeavesThePanelStateUntouched() async {
        let vm = makeVM()
        vm.setRemoteNotifyHandler = { _, _, _ in false }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal)

        vm.setRemoteNotifyEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(vm.remoteNotifyEnabled,
                       "the pill must never show a position config.yaml does not hold")
    }

    func testRapidClicksSerializeAndCompoundInsteadOfInterleaving() async {
        // The stale-triple interleave: enable, then immediately pick a
        // detail while the first write is still in flight. The detail
        // write used to be computed from the still-old published state, so
        // it silently wrote enabled=false back. Serialized writes compute
        // each triple from the last ENQUEUED target and run in order.
        let vm = makeVM()
        final class Writes: @unchecked Sendable {
            var triples: [(Bool, RemoteNotifyDetail)] = []
        }
        let writes = Writes()
        vm.setRemoteNotifyHandler = { enabled, detail, _ in
            // A slow write, so the second click lands while this one is
            // still in flight.
            try? await Task.sleep(nanoseconds: 100_000_000)
            writes.triples.append((enabled, detail))
            return true
        }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal)

        vm.setRemoteNotifyEnabled(true)
        vm.setRemoteNotifyDetail(.full)

        await waitUntil(vm.remoteNotifyEnabled && vm.remoteNotifyDetail == .full,
                        timeoutSeconds: 3, "both clicks must land")
        XCTAssertEqual(writes.triples.map(\.0), [true, true],
                       "the detail click must not carry a stale enabled=false back into config")
        XCTAssertEqual(writes.triples.map(\.1), [.minimal, .full])
    }

    func testNoOpToggleDoesNotCallTheHandler() async {
        let vm = makeVM()
        let called = Counter()
        vm.setRemoteNotifyHandler = { _, _, _ in called.bump(); return true }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        vm.setRemoteNotifyEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(called.value, 0)
    }

    // MARK: - Send test

    func testSendTestReportsDelivery() async {
        let vm = makeVM()
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal)
        vm.sendRemoteTestHandler = { .posted }

        vm.sendRemoteTest()
        await waitUntil({ if case .delivered = vm.remoteTestState { return true }; return false }())
    }

    func testSendTestReportsFailureWithReason() async {
        let vm = makeVM()
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        vm.sendRemoteTestHandler = { .failed(reason: "http_404") }

        vm.sendRemoteTest()
        await waitUntil({
            if case .failed(let reason) = vm.remoteTestState { return reason.contains("http_404") }
            return false
        }())
    }

    func testSendTestWithoutAStoredURLFailsFast() {
        let vm = makeVM()
        vm.sendRemoteTestHandler = { .posted }
        vm.sendRemoteTest()
        guard case .failed(let reason) = vm.remoteTestState else {
            return XCTFail("expected an immediate failure, got \(vm.remoteTestState)")
        }
        XCTAssertTrue(reason.contains("webhook URL"), reason)
    }

    // MARK: - A new endpoint has no history

    /// The row showed "Delivered 12m ago" about the PREVIOUS webhook after a
    /// swap, at exactly the moment the owner is checking whether the NEW one
    /// works. A test result belongs to the endpoint that was tested.
    func testSavingANewWebhookClearsThePreviousTestResult() async {
        let vm = makeVM()
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        vm.sendRemoteTestHandler = { .posted }
        vm.sendRemoteTest()
        await waitUntil({ if case .delivered = vm.remoteTestState { return true }; return false }())

        vm.saveRemoteWebhookHandler = { _ in }
        vm.saveRemoteWebhook("https://discord.com/api/webhooks/2/other-token")

        XCTAssertEqual(vm.remoteTestState, .idle,
                       "a verdict about the old endpoint must not stand as a verdict about the new one")
    }

    /// Cleared BEFORE the write, so a save that then fails does not leave a
    /// green result standing for an endpoint that was never stored.
    func testAFailedSaveStillClearsThePreviousTestResult() async {
        struct Boom: Error {}
        let vm = makeVM()
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        vm.sendRemoteTestHandler = { .posted }
        vm.sendRemoteTest()
        await waitUntil({ if case .delivered = vm.remoteTestState { return true }; return false }())

        vm.saveRemoteWebhookHandler = { _ in throw Boom() }
        vm.saveRemoteWebhook("https://discord.com/api/webhooks/3/token")
        await waitUntil(vm.remoteWebhookSaveError != nil)

        XCTAssertEqual(vm.remoteTestState, .idle)
    }

    /// A URL rejected on SHAPE never reaches the handler and never changes the
    /// stored endpoint, so the standing result is still about the live one.
    func testAShapeRejectionLeavesTheTestResultAlone() async {
        let vm = makeVM()
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal)
        vm.sendRemoteTestHandler = { .posted }
        vm.sendRemoteTest()
        await waitUntil({ if case .delivered = vm.remoteTestState { return true }; return false }())

        vm.saveRemoteWebhookHandler = { _ in }
        vm.saveRemoteWebhook("http://discord.com/api/webhooks/4/token")  // not https

        XCTAssertNotNil(vm.remoteWebhookSaveError)
        if case .delivered = vm.remoteTestState {} else {
            XCTFail("nothing was swapped, so the live endpoint's result still stands")
        }
    }

    // MARK: - RemoteNotifier.sendTest (the real channel behind the button)

    private func scratchTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-test-send-\(UUID()).log"))
    }

    func testSendTestPostsThroughTheRealTransportEvenWhileDisabled() async throws {
        // The documented setup order proves delivery BEFORE flipping the
        // switch on, so the test send must bypass the enabled gate.
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: false),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        let outcome = await notifier.sendTest()
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(transport.callCount, 1)
        let body = String(decoding: try XCTUnwrap(transport.sent.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("Supervisor test message"), body)
        XCTAssertTrue(body.hasPrefix("{\"content\":"),
                      "the test must use the endpoint's real wire shape: \(body)")
    }

    func testSendTestTwiceInARowSendsTwice() async throws {
        // The owner clicking twice is confirmation, not spam; the dedupe
        // window must not swallow the second click.
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: true),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        _ = await notifier.sendTest()
        _ = await notifier.sendTest()
        XCTAssertEqual(transport.callCount, 2)
    }

    func testSendTestWithoutAnEndpointSkips() async {
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: nil,
            configuration: .init(enabled: true),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        let outcome = await notifier.sendTest()
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testSendTestReportsARealDeliveryFailure() async throws {
        let transport = RemoteNotifierTests.StubTransport(results: [.success(404)])
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: true),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: scratchTrace()
        )
        let outcome = await notifier.sendTest()
        XCTAssertEqual(outcome, .failed(reason: "http_404"),
                       "a green panel result must never come from a failed POST")
    }

    // MARK: - Tiny reference boxes (the handlers are @Sendable-ish closures)

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
