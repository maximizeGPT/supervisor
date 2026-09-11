// RemoteReplyEndpointTests.swift
//
// Which webhooks can carry a reply, and which are refused. This is the
// first gate in the feature: everything downstream is unreachable when
// derivation returns nil, so "a Discord webhook silently arms an inbound
// channel" has to be impossible here rather than caught later.

import XCTest
@testable import SupervisorCore

final class RemoteReplyEndpointTests: XCTestCase {

    private func webhook(_ raw: String) throws -> RemoteWebhookURL {
        try RemoteWebhookURL(validating: raw)
    }

    private let goodTopic = "hDs8dpM3zLpTGGQEabcd"

    // MARK: - What derives

    func testAnNtfyWebhookDerivesAStreamAndPollURL() throws {
        let endpoint = try XCTUnwrap(
            RemoteReplyEndpoint.derive(from: webhook("https://ntfy.sh/\(goodTopic)"), format: .ntfy)
        )
        XCTAssertEqual(endpoint.streamURL().absoluteString,
                       "https://ntfy.sh/\(goodTopic)/json")
        XCTAssertEqual(endpoint.pollURL(since: "10m").absoluteString,
                       "https://ntfy.sh/\(goodTopic)/json?poll=1&since=10m")
        XCTAssertEqual(endpoint.loggableHost, "ntfy.sh")
    }

    func testASelfHostedServerDerivesWhenTheOwnerNamedTheFormat() throws {
        // A self-hosted ntfy host detects as `.generic`, so without the
        // owner's explicit `format: ntfy` there is nothing to go on. With
        // it, the reply channel works the same way.
        let raw = "https://push.example.com/\(goodTopic)"
        XCTAssertNil(RemoteReplyEndpoint.derive(from: try webhook(raw), format: .generic),
                     "a host we cannot recognize must not be assumed to be ntfy")
        let endpoint = try XCTUnwrap(RemoteReplyEndpoint.derive(from: try webhook(raw), format: .ntfy))
        XCTAssertEqual(endpoint.loggableHost, "push.example.com")
        XCTAssertEqual(endpoint.streamURL().absoluteString,
                       "https://push.example.com/\(goodTopic)/json")
    }

    // MARK: - What is refused

    func testWriteOnlyWebhooksCannotCarryReplies() throws {
        let discord = try webhook("https://discord.com/api/webhooks/123456789/aVeryLongTokenValue")
        XCTAssertEqual(discord.format, .discord)
        XCTAssertNil(RemoteReplyEndpoint.derive(from: discord, format: discord.format))
        XCTAssertEqual(RemoteReplyEndpoint.unavailableReason(from: discord, format: discord.format),
                       "webhook_is_not_ntfy")

        let slack = try webhook("https://hooks.slack.com/services/T000/B000/XXXXXXXXXXXX")
        XCTAssertNil(RemoteReplyEndpoint.derive(from: slack, format: slack.format))
    }

    func testAShortTopicIsRefused() throws {
        // A guessable topic cannot inject (that still needs a live code) but
        // it CAN be used to burn the failure budget and switch the owner's
        // reply channel off, so it is refused at arming time with a reason.
        let short = try webhook("https://ntfy.sh/supervisor")
        XCTAssertNil(RemoteReplyEndpoint.derive(from: short, format: .ntfy))
        XCTAssertEqual(RemoteReplyEndpoint.unavailableReason(from: short, format: .ntfy),
                       "topic_too_short")
        XCTAssertEqual(RemoteReplyEndpoint.minimumTopicLength, 16,
                       "the floor tracks ntfy's own generated-topic length")
    }

    func testADeepPathIsRefusedRatherThanGuessedAt() throws {
        for raw in [
            "https://ntfy.sh/\(goodTopic)/publish",
            "https://ntfy.sh/\(goodTopic)/json",
            "https://ntfy.sh/",
            "https://ntfy.sh",
        ] {
            XCTAssertNil(RemoteReplyEndpoint.derive(from: try webhook(raw), format: .ntfy),
                         "guessing which path segment is the topic is not something a credential path may do: \(raw)")
        }
    }

    func testATopicWithPathTricksIsRefused() throws {
        // `RemoteWebhookURL` already normalizes a lot of this, so the real
        // job here is that whatever survives is still checked against the
        // ntfy topic alphabet before it is appended to a URL path.
        for raw in [
            "https://ntfy.sh/topic.with.dots.aaaaaaaa",
            "https://ntfy.sh/topic%2Fwith%2Fescapes12345",
        ] {
            XCTAssertNil(RemoteReplyEndpoint.derive(from: try webhook(raw), format: .ntfy),
                         "must refuse: \(raw)")
        }
    }

    // MARK: - Nothing leaks

    func testTheEndpointNeverPrintsItsTopic() throws {
        let endpoint = try XCTUnwrap(
            RemoteReplyEndpoint.derive(from: webhook("https://ntfy.sh/\(goodTopic)"), format: .ntfy)
        )
        // The topic is a bearer credential shared with the outbound page.
        // `loggableHost` is the one thing a trace line may carry, and the
        // interpolated description must not become a back door to the rest.
        XCTAssertFalse("\(endpoint.loggableHost)".contains(goodTopic))
        XCTAssertFalse("\(endpoint.base)".contains(goodTopic),
                       "the base URL carries no path, so it carries no topic")
    }
}
