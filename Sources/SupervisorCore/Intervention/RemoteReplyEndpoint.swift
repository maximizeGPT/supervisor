// RemoteReplyEndpoint.swift. Where an owner's reply comes back from, and
// why the address is the credential.
//
// v0.4.0 shipped the outbound page: RemoteNotifier POSTs to a webhook the
// owner stored in the Keychain. For an ntfy webhook that URL is
// `https://ntfy.sh/<topic>`, and ntfy's topics are bidirectional: the same
// path that accepts a POST also serves a long-lived GET stream of everything
// posted to it. So the return path needs no new secret, no new account and
// no inbound port. It needs the URL the owner already stored.
//
// THAT SHARING IS THE WHOLE THREAT MODEL. The topic is a bearer credential
// with no second factor: anyone who learns it can READ every escalation
// Supervisor sends AND POST a string that Supervisor will read back. It was
// already true for the outbound half (a leaked topic leaks the pages); the
// inbound half is what makes it a write primitive against a live coding
// session. Everything downstream of this file exists because of that one
// sentence:
//
//   - a posted string is not a reply unless it carries a correlation code
//     Supervisor minted itself (ReplyCorrelationTable),
//   - the code is single-use, session-bound and short-lived,
//   - wrong codes are budgeted, and blowing the budget switches the inbound
//     half off and pages the owner (RemoteReplyGate),
//   - whatever survives all of that is still screened by
//     InjectionSafetyScreen before a single keystroke is synthesized.
//
// The topic is never logged. `RemoteWebhookURL` already treats the whole URL
// as secret-class and exposes only `loggableHost`; this type keeps that
// convention exactly, and deliberately has no `description` and no
// `CustomStringConvertible`, so there is no way to turn one of these into a
// string by accident inside a trace line.
//
// There is exactly ONE accessor that hands the topic back,
// `ownerSubscribeURL()`, added in v0.4.2 so the panel can show the owner
// where their replies come from. An owner cannot subscribe a phone to an
// address they are never shown, so the path has to exist; what the rule
// above rules out is a CONVENIENT one. That function has to be called by
// name, its name says who the result is for, and the panel masks what it
// returns until the owner clicks Reveal.

import Foundation

/// The ntfy topic the inbound half subscribes to, derived from the outbound
/// webhook rather than minted separately.
///
/// Derivation rather than generation is a deliberate choice. A second,
/// app-minted topic would be a stronger secret (more entropy, never typed by
/// a human), but it would also be a second thing to store, a second thing to
/// revoke, and a second subscription the owner has to add on their phone
/// before a reply can be typed at all. The channel they already have open is
/// the channel the page arrived on, and replying to a notification in place
/// is the only interaction that survives being done one-handed at a bus
/// stop. The security this gives up is bought back downstream, where a
/// stranger holding the topic still cannot inject without a live code.
public struct RemoteReplyEndpoint: Sendable, Equatable {

    /// Shortest topic the inbound half will arm on.
    ///
    /// A guessable topic does not let a stranger inject (they still need a
    /// live correlation code), but it does let them burn the failure budget
    /// and switch the reply channel off, which is a denial of service
    /// against the feature. Sixteen characters is ntfy's own generated-topic
    /// length, so an owner who used ntfy's "generate" button passes and an
    /// owner who typed `supervisor-alerts` is refused with a reason rather
    /// than armed with a topic three guesses wide.
    public static let minimumTopicLength = 16

    /// Scheme and host of the ntfy server, with no path. Not a secret.
    public let base: URL

    /// The topic. Internal, not public: the only ways out of this type are a
    /// stream URL and a poll URL, both of which are handed straight to a
    /// transport, so there is no convenient accessor to log by accident.
    let topic: String

    /// Host only, and only ever the host. Same rule as
    /// `RemoteWebhookURL.loggableHost`: the path carries the credential.
    public var loggableHost: String { base.host ?? "?" }

    init(base: URL, topic: String) {
        self.base = base
        self.topic = topic
    }

    /// Derive the inbound endpoint from the configured outbound webhook, or
    /// nil when this webhook cannot carry replies.
    ///
    /// `format` is the format the notifier RESOLVED for this endpoint (the
    /// owner's `formatOverride` when set, host detection otherwise), so a
    /// self-hosted ntfy that only detects as `.generic` still works when the
    /// owner has told the app what it is. Discord and Slack webhooks are
    /// write-only by design and return nil, which is how the feature stays
    /// silently inert for the majority of installs.
    public static func derive(
        from endpoint: RemoteWebhookURL,
        format: RemoteNotifyFormat
    ) -> RemoteReplyEndpoint? {
        guard format == .ntfy else { return nil }
        guard let components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Exactly one path segment. An ntfy publish URL is
        // `https://host/<topic>`; anything deeper is a publish endpoint we do
        // not understand (ntfy's own `/<topic>/publish` and `/<topic>/json`
        // among them), and guessing which segment is the topic is precisely
        // the kind of inference a credential-handling path should refuse.
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count == 1 else { return nil }
        let topic = segments[0]
        guard topic.count >= minimumTopicLength else { return nil }
        // ntfy topic names are `[-_A-Za-z0-9]{1,64}`. Refusing anything else
        // means the value we append to a URL path can never carry a `..`, a
        // query, or a percent-escape that re-points the request.
        guard topic.count <= 64, topic.allSatisfy(isTopicCharacter) else { return nil }

        var baseComponents = URLComponents()
        baseComponents.scheme = components.scheme
        baseComponents.host = components.host
        baseComponents.port = components.port
        guard let base = baseComponents.url else { return nil }
        return RemoteReplyEndpoint(base: base, topic: topic)
    }

    /// Why a derivation failed, in the vocabulary the trace and the panel
    /// share. Separate from `derive` so the caller can explain an inert
    /// channel without this function having to return a two-case result on
    /// the happy path.
    public static func unavailableReason(
        from endpoint: RemoteWebhookURL,
        format: RemoteNotifyFormat
    ) -> String? {
        if derive(from: endpoint, format: format) != nil { return nil }
        guard format == .ntfy else { return "webhook_is_not_ntfy" }
        let segments = (URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
        if segments.count != 1 { return "webhook_path_is_not_a_topic" }
        if segments[0].count < minimumTopicLength { return "topic_too_short" }
        return "topic_malformed"
    }

    private static func isTopicCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// The plain topic URL, for showing the OWNER where their replies come
    /// from so they can subscribe a phone to it.
    ///
    /// This is the one accessor in the file that hands the topic back, and
    /// it is named for the single thing it is for. The owner cannot
    /// subscribe a phone to an address they are never shown, so some path
    /// has to exist; what the file header rules out is a CONVENIENT one, a
    /// `description` or a `CustomStringConvertible` that turns the topic
    /// into a string by accident inside a trace line. This has to be
    /// called, and its name says out loud that what comes back belongs on
    /// the owner's screen and nowhere else.
    ///
    /// The panel masks the result by default and reveals it only on an
    /// explicit click (`HoverViewModel.remoteReplyTopicRevealed`), because
    /// a topic glimpsed over a shoulder or caught in a screenshot is the
    /// whole credential in both directions.
    public func ownerSubscribeURL() -> URL {
        base.appendingPathComponent(topic)
    }

    /// The same address with the topic blanked out, which is what the panel
    /// renders until the owner asks to see it.
    ///
    /// The mask is a FIXED width and never a prefix of the real topic. A
    /// few leading characters would be a friendly touch and a real gift: a
    /// topic is `[-_A-Za-z0-9]` and every character shown divides the work
    /// of guessing the rest by 64. The length is hidden for the same
    /// reason, cheaply.
    public func maskedSubscribeURL() -> String {
        "\(base.absoluteString)/\(String(repeating: "\u{2022}", count: 12))"
    }

    /// ntfy's JSON stream endpoint: a response that stays open and emits one
    /// JSON object per line.
    public func streamURL() -> URL {
        base.appendingPathComponent(topic).appendingPathComponent("json")
    }

    /// The degraded read: everything since `since`, then the connection
    /// closes. `since` is an ntfy duration (`10m`) or a message id.
    public func pollURL(since: String) -> URL {
        var components = URLComponents(url: streamURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since),
        ]
        return components?.url ?? streamURL()
    }
}
