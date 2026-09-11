// RemoteReplyPanelTests.swift
//
// The "Allow replies from your phone" controls in the hover panel's Remote
// escalation row, at the view-model layer. Same construction pattern as
// RemoteEscalationPanelTests (a VM over a throwaway bus + trace, handlers as
// closures), so no Keychain, no config file and no network appear here.
//
// The centre of gravity is the MASKING rule, and it is worth saying why a
// panel test file leans that hard on one string. The ntfy topic is the whole
// credential in both directions: whoever learns it reads every escalation
// Supervisor sends and can post a reply Supervisor will read back. This
// feature's threat model names a topic caught on a screenshot as an
// adversary by name. So "the address is bulleted out until the owner asks"
// is a security property, and the assertions below treat it as one: the
// masked line must not contain the topic, must not contain a PREFIX of the
// topic, and the QR target (the same secret in a form a camera reads across
// a room) must be nil while the text is masked.

import XCTest
@testable import SupervisorCore

@MainActor
final class RemoteReplyPanelTests: XCTestCase {

    /// A topic long enough to arm on, and distinctive enough that a
    /// substring check is meaningful.
    private static let topic = "hDs8dpM3zLpTGGQEabcd"

    private func makeVM() -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-reply-panel-\(UUID()).log"))
        return HoverViewModel(bus: EventBus(trace: trace), trace: trace)
    }

    private func endpoint(topic: String = RemoteReplyPanelTests.topic) throws -> RemoteReplyEndpoint {
        try XCTUnwrap(RemoteReplyEndpoint.derive(
            from: RemoteWebhookURL(validating: "https://ntfy.sh/\(topic)"),
            format: .ntfy
        ))
    }

    /// Spin the main actor until `condition` holds. The setters hop through
    /// a Task, so published state lands a turn later.
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

    func testReplySwitchSeedsFromConfig() {
        let vm = makeVM()
        XCTAssertFalse(vm.remoteReplyEnabled, "the inbound half is off unless the file says otherwise")

        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        XCTAssertTrue(vm.remoteReplyEnabled)
    }

    func testASeedRehidesARevealedTopic() throws {
        let vm = makeVM()
        let live = try endpoint()
        vm.remoteReplyInboxEndpointProvider = { live }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        vm.revealRemoteReplyTopic()
        XCTAssertTrue(vm.remoteReplyTopicRevealed)

        // A re-seed is config.yaml speaking, and it can be speaking because
        // somebody rotated the webhook. What is on screen may no longer be
        // the address that was revealed, so it goes back behind the mask.
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        XCTAssertFalse(vm.remoteReplyTopicRevealed)
    }

    // MARK: - The masking rule

    func testAddressIsMaskedUntilRevealed() throws {
        let vm = makeVM()
        let live = try endpoint()
        vm.remoteReplyInboxEndpointProvider = { live }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)

        let masked = try XCTUnwrap(vm.remoteReplyInboxAddressLine())
        XCTAssertFalse(masked.contains(Self.topic), "the masked line must not carry the topic")
        XCTAssertTrue(masked.hasPrefix("https://ntfy.sh/"),
                      "the host is not a secret and the owner needs to recognize their server")
        XCTAssertTrue(masked.contains("\u{2022}"), "the topic is replaced by a mask, not omitted")

        vm.revealRemoteReplyTopic()
        let revealed = try XCTUnwrap(vm.remoteReplyInboxAddressLine())
        XCTAssertEqual(revealed, "https://ntfy.sh/\(Self.topic)")
    }

    func testTheMaskLeaksNeitherAPrefixNorTheLength() throws {
        let vm = makeVM()
        // Two topics of DIFFERENT lengths sharing a long common prefix. A
        // mask that showed the first few characters, or that sized itself
        // to the real topic, would render these two differently. Every
        // character shown divides the work of guessing the rest by 64, and
        // the length narrows the search on its own.
        let short = try endpoint(topic: "commonPrefixAAAA")
        let long = try endpoint(topic: "commonPrefixAAAABBBBCCCCDDDD")

        vm.remoteReplyInboxEndpointProvider = { short }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        let maskedShort = try XCTUnwrap(vm.remoteReplyInboxAddressLine())

        vm.remoteReplyInboxEndpointProvider = { long }
        let maskedLong = try XCTUnwrap(vm.remoteReplyInboxAddressLine())

        XCTAssertEqual(maskedShort, maskedLong,
                       "two different topics on one host must mask identically")
        XCTAssertFalse(maskedShort.contains("common"),
                       "not one character of the topic may survive the mask")
    }

    func testQRTargetIsNilUntilTheTopicIsRevealed() throws {
        let vm = makeVM()
        let live = try endpoint()
        vm.remoteReplyInboxEndpointProvider = { live }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)

        XCTAssertNil(vm.remoteReplyInboxQRTarget(),
                     "a QR is the topic in a form a camera reads across a room")

        vm.revealRemoteReplyTopic()
        XCTAssertEqual(vm.remoteReplyInboxQRTarget()?.absoluteString, "https://ntfy.sh/\(Self.topic)")

        vm.hideRemoteReplyTopic()
        XCTAssertNil(vm.remoteReplyInboxQRTarget(), "Hide puts the image away too, not only the text")
    }

    func testTurningRepliesOffRehidesTheTopic() async throws {
        let vm = makeVM()
        let live = try endpoint()
        vm.remoteReplyInboxEndpointProvider = { live }
        vm.setRemoteNotifyHandler = { _ in true }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        vm.revealRemoteReplyTopic()

        vm.setRemoteReplyEnabled(false)
        await waitUntil(!vm.remoteReplyEnabled)
        XCTAssertFalse(vm.remoteReplyTopicRevealed,
                       "an owner who just switched the inbound half off is not left staring at its credential")
    }

    func testNoAddressAtAllWhenTheWebhookCannotCarryReplies() {
        let vm = makeVM()
        // A Discord webhook derives no endpoint, so the provider is nil and
        // the row has nothing to show. The row must not invent an address.
        vm.remoteReplyInboxEndpointProvider = { nil }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)

        XCTAssertNil(vm.remoteReplyInboxAddressLine())
        vm.revealRemoteReplyTopic()
        XCTAssertNil(vm.remoteReplyInboxQRTarget(), "a reveal with nothing to reveal stays empty")
    }

    // MARK: - The switch

    func testReplyToggleReflectsOnlyAfterTheWriteSucceeds() async {
        let vm = makeVM()
        let written = ValueBox<RemoteNotifyConfigWriter.Values>()
        vm.setRemoteNotifyHandler = { values in
            written.value = values
            return true
        }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .full, replyEnabled: false)

        vm.setRemoteReplyEnabled(true)
        await waitUntil(vm.remoteReplyEnabled, "state follows the successful write")
        XCTAssertEqual(written.value?.replyEnabled, true)
        XCTAssertEqual(written.value?.enabled, true, "the other three scalars ride along unchanged")
        XCTAssertEqual(written.value?.detail, .full)
    }

    func testFailedWriteLeavesTheReplySwitchAlone() async {
        let vm = makeVM()
        vm.setRemoteNotifyHandler = { _ in false }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: false)

        vm.setRemoteReplyEnabled(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(vm.remoteReplyEnabled,
                       "the pill must never show a position config.yaml does not hold")
    }

    func testTheOtherToggleCarriesTheReplySwitchInsteadOfClobberingIt() async {
        // The whole reason the writer takes one Values: every save writes
        // every scalar, so a detail change that computed its own reply
        // value would silently switch the owner's reply channel off.
        let vm = makeVM()
        let written = ValueBox<RemoteNotifyConfigWriter.Values>()
        vm.setRemoteNotifyHandler = { values in
            written.value = values
            return true
        }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)

        vm.setRemoteNotifyDetail(.full)
        await waitUntil(vm.remoteNotifyDetail == .full)
        XCTAssertEqual(written.value?.replyEnabled, true,
                       "changing the detail level must not turn replies off")
        XCTAssertTrue(vm.remoteReplyEnabled)
    }

    func testRapidClicksAcrossBothSwitchesCompound() async {
        // The stale-value interleave, now across the outbound and inbound
        // switches: flip replies on, then immediately pick a detail while
        // the first write is still in flight.
        let vm = makeVM()
        final class Writes: @unchecked Sendable {
            var values: [RemoteNotifyConfigWriter.Values] = []
        }
        let writes = Writes()
        vm.setRemoteNotifyHandler = { values in
            try? await Task.sleep(nanoseconds: 100_000_000)
            writes.values.append(values)
            return true
        }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: false)

        vm.setRemoteReplyEnabled(true)
        vm.setRemoteNotifyDetail(.full)

        await waitUntil(vm.remoteReplyEnabled && vm.remoteNotifyDetail == .full,
                        timeoutSeconds: 3, "both clicks must land")
        XCTAssertEqual(writes.values.map(\.replyEnabled), [true, true],
                       "the detail click must not carry a stale reply_enabled=false back into config")
        XCTAssertEqual(writes.values.map(\.detail), [.minimal, .full])
    }

    func testNoOpReplyToggleDoesNotCallTheHandler() async {
        let vm = makeVM()
        let calls = CallCounter()
        vm.setRemoteNotifyHandler = { _ in calls.bump(); return true }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)

        vm.setRemoteReplyEnabled(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: - Status line

    func testStatusLineForEachState() throws {
        let vm = makeVM()
        let live = try endpoint()

        vm.seedRemoteEscalation(webhookConfigured: true, enabled: false, detail: .minimal, replyEnabled: false)
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("Turn delivery on first"))

        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: false)
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("Off."))
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("treat it like a password"))

        vm.remoteReplyInboxEndpointProvider = { nil }
        vm.seedRemoteEscalation(webhookConfigured: true, enabled: true, detail: .minimal, replyEnabled: true)
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("cannot carry replies"))

        vm.remoteReplyInboxEndpointProvider = { live }
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("Subscribe your phone"))
        XCTAssertTrue(vm.remoteReplyStatusLine.contains("guard it like a password"))
    }

    func testNoStatusLineEverQuotesTheTopic() throws {
        let vm = makeVM()
        let live = try endpoint()
        vm.remoteReplyInboxEndpointProvider = { live }
        for (enabled, reply) in [(false, false), (true, false), (true, true)] {
            vm.seedRemoteEscalation(
                webhookConfigured: true, enabled: enabled, detail: .minimal, replyEnabled: reply
            )
            XCTAssertFalse(vm.remoteReplyStatusLine.contains(Self.topic),
                           "prose about the channel never carries the credential")
        }
    }

    // MARK: - Helpers

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func bump() { lock.lock(); _value += 1; lock.unlock() }
    }

    private final class ValueBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
}
