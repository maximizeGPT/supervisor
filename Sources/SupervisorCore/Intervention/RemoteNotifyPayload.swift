// RemoteNotifyPayload.swift. Composes the message that crosses the
// network, and nothing else.
//
// Pure functions, so the privacy contract is testable without a socket.
//
// The privacy contract, stated once and enforced here:
//
//   1. Two detail levels. `.minimal` (the default) sends Supervisor's own
//      verdict and nothing from the session: category, severity, what
//      Supervisor did, the project directory's BASENAME, and an 8-char
//      session prefix. No command text, no assistant prose, no paths.
//      `.full` adds the triggering command and the plain reasoning, both
//      redacted, both capped.
//   2. Every free-text field goes through the same `Redactor` the API path
//      uses, including in `.minimal`. There is no second redaction layer to
//      keep in sync, and a project directory can itself be a secret-shaped
//      string.
//   3. The composed text is capped at `maxTextLength`. Discord rejects
//      bodies over 2000 characters outright, and a five-page reasoning
//      paragraph is not a notification.
//
// The banner title is reused verbatim from `Notifier.plainTitle(for:)`, so
// the phone and the Mac say the same sentence about the same event. One copy
// surface, one place to change it.

import Foundation

/// How much of the session may cross the network. Default is `.minimal`.
/// Named in `config.yaml` as `remote_notify.detail`.
public enum RemoteNotifyDetail: String, Sendable, Equatable, CaseIterable {
    /// Supervisor's verdict only. Nothing quoted from the session.
    case minimal
    /// Adds the redacted triggering command and the redacted plain
    /// reasoning. Opt in when the notification needs to be actionable
    /// without walking to the Mac.
    case full
}

/// Wire shape of the receiving endpoint. Detected from the URL host so a
/// Discord, Slack, or ntfy.sh webhook works with no configuration beyond
/// the URL; anything else gets the structured envelope. Raw values are the
/// `remote_notify.format` vocabulary in config.yaml (a SELF-HOSTED ntfy
/// server's host cannot be detected, so the format is selectable there and
/// in the panel).
public enum RemoteNotifyFormat: String, Sendable, Equatable, CaseIterable {
    /// Discord incoming webhook: `{"content": "..."}`.
    case discord
    /// Slack incoming webhook: `{"text": "..."}`.
    case slack
    /// Everything else: a flat JSON envelope with the fields broken out,
    /// plus `text` so a dumb receiver can still render one string.
    case generic
    /// ntfy publish API (C13): the URL is the topic, the body is the
    /// plain-text message, and the title travels as the `Title` header.
    /// https://docs.ntfy.sh/publish/
    case ntfy

    public static func detect(from url: URL) -> RemoteNotifyFormat {
        let host = (url.host ?? "").lowercased()
        if host == "discord.com" || host.hasSuffix(".discord.com")
            || host == "discordapp.com" || host.hasSuffix(".discordapp.com") {
            return .discord
        }
        if host == "hooks.slack.com" || host.hasSuffix(".slack.com") {
            return .slack
        }
        if host == "ntfy.sh" || host.hasSuffix(".ntfy.sh") {
            return .ntfy
        }
        return .generic
    }
}

/// The composed, already-redacted message. Constructing one of these is the
/// only supported way to produce bytes for the wire.
public struct RemoteNotifyPayload: Sendable, Equatable {

    /// Same sentence the local banner uses.
    public let title: String
    /// Rendered multi-line body, redacted and capped.
    public let text: String
    /// Rubric category that fired.
    public let category: String
    /// low / medium / high.
    public let severity: String
    /// What Supervisor did, in `RemoteNotifyPolicy.outcomeKind` vocabulary.
    public let outcomeKind: String
    /// Stable policy reason (why this one was worth sending).
    public let reason: String
    /// First 8 characters of the session id. Enough to match a session in
    /// the hover panel, not enough to be the session id.
    public let sessionShort: String
    /// Basename of the session's working directory, never the full path.
    /// Nil when the decision carried no cwd.
    public let project: String?
    /// Which detail level produced this payload. Echoed on the wire so a
    /// receiver can tell "quiet by policy" from "nothing happened".
    public let detail: RemoteNotifyDetail

    /// Hard cap on `text`. Discord's own limit is 2000; staying well under
    /// leaves room for a receiver that decorates the message.
    public static let maxTextLength = 1500

    /// Cap on each quoted session field in `.full`. A triggering command is
    /// usually one line; a reasoning paragraph is three sentences. Both get
    /// truncated rather than dropped, so the notification degrades
    /// gracefully instead of going silent.
    public static let maxQuotedLength = 400

    /// Categories allowed on the wire, i.e. the rubric's own vocabulary.
    /// The category on a `TriageCandidate` is model output: the tool schema
    /// enumerates the legal values, but a model can and occasionally does
    /// invent one, and an invented category is session-derived free text on
    /// a path that promises to quote nothing from the session at `.minimal`.
    static let knownCategories: Set<String> = Set(HardcodedRubric.allNames)

    /// What an out-of-vocabulary category becomes on the wire.
    public static let unrecognizedCategory = "unrecognized_category"

    /// The wire-safe form of a category string: the rubric's own names pass
    /// through, anything else is replaced wholesale (not redacted — there is
    /// no safe half of an invented string to keep). Also used by
    /// `RemoteNotifyPolicy.dedupeKey`, so two escalations differing only in
    /// an invented category still collapse inside the window.
    public static func normalizedCategory(_ raw: String) -> String {
        knownCategories.contains(raw) ? raw : unrecognizedCategory
    }

    public init(
        title: String,
        text: String,
        category: String,
        severity: String,
        outcomeKind: String,
        reason: String,
        sessionShort: String,
        project: String?,
        detail: RemoteNotifyDetail
    ) {
        self.title = title
        self.text = text
        self.category = category
        self.severity = severity
        self.outcomeKind = outcomeKind
        self.reason = reason
        self.sessionShort = sessionShort
        self.project = project
        self.detail = detail
    }

    /// Build the payload for one intervention. `reason` comes from
    /// `RemoteNotifyPolicy.verdict`; the caller has already decided this
    /// event is worth sending.
    public static func compose(
        decision: TriageDecision,
        outcome: InterventionOutcome,
        reason: String,
        detail: RemoteNotifyDetail,
        redactor: any Redactor
    ) -> RemoteNotifyPayload {
        let kind = RemoteNotifyPolicy.outcomeKind(outcome)
        let title = Notifier.plainTitle(for: outcome)
        let sessionShort = String(decision.sessionId.prefix(8))
        let project = decision.cwd.map { redactor.redact(basename(of: $0)) }
        let category = normalizedCategory(decision.candidate.category)

        var lines: [String] = [title]
        if let project, !project.isEmpty {
            lines.append("Project: \(project)")
        }
        if !sessionShort.isEmpty {
            lines.append("Session: \(sessionShort)")
        }
        lines.append("Flag: \(category) (\(decision.candidate.severity.rawValue))")
        lines.append("Supervisor: \(kind)")

        switch detail {
        case .minimal:
            // The honest line. Without it the owner assumes the message is
            // everything Supervisor knows, and walks to the Mac for nothing
            // or fails to walk when they should have.
            lines.append("Command and reasoning stayed on your Mac. Open Supervisor for the detail.")
        case .full:
            let command = clip(redactor.redact(decision.candidate.matchedCommand), to: maxQuotedLength)
            if !command.isEmpty {
                lines.append("Command: \(command)")
            }
            let plain = clip(redactor.redact(decision.candidate.reasoningPlain), to: maxQuotedLength)
            if !plain.isEmpty {
                lines.append("Why: \(plain)")
            }
        }

        return RemoteNotifyPayload(
            title: title,
            text: clip(lines.joined(separator: "\n"), to: maxTextLength),
            category: category,
            severity: decision.candidate.severity.rawValue,
            outcomeKind: kind,
            reason: reason,
            sessionShort: sessionShort,
            project: project,
            detail: detail
        )
    }

    /// Everything one POST needs beyond the URL: the bytes, their content
    /// type, and any extra headers the format's protocol carries out of
    /// band. Exists because ntfy is not JSON-in-a-body — its title is a
    /// header — and the transport should not know format rules.
    public struct WireBody: Sendable, Equatable {
        public let data: Data
        public let contentType: String
        public let headers: [String: String]

        public init(data: Data, contentType: String, headers: [String: String] = [:]) {
            self.data = data
            self.contentType = contentType
            self.headers = headers
        }
    }

    /// Encode for the wire in the endpoint's shape. Never throws in practice
    /// (every field is a String), but the encoder can, and a silent empty
    /// body would be worse than a traced failure.
    public func wireBody(format: RemoteNotifyFormat) throws -> WireBody {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = "application/json"
        switch format {
        case .discord:
            return WireBody(data: try encoder.encode(DiscordBody(content: text)), contentType: json)
        case .slack:
            return WireBody(data: try encoder.encode(SlackBody(text: text)), contentType: json)
        case .generic:
            return WireBody(
                data: try encoder.encode(GenericBody(
                    source: "supervisor",
                    title: title,
                    text: text,
                    category: category,
                    severity: severity,
                    outcome: outcomeKind,
                    reason: reason,
                    session: sessionShort,
                    project: project,
                    detail: detail.rawValue
                )),
                contentType: json
            )
        case .ntfy:
            // ntfy's publish API: plain-text POST to the topic URL, title in
            // the `Title` header. The body drops the leading title line the
            // JSON formats fold into `text`, because ntfy renders the header
            // title above the body and repeating it reads twice.
            return WireBody(
                data: Data(ntfyBodyText.utf8),
                contentType: "text/plain; charset=utf-8",
                headers: ["Title": Self.headerSafe(title)]
            )
        }
    }

    /// Compatibility shim for the JSON formats (the existing shape tests
    /// and any caller that only wants bytes).
    public func body(format: RemoteNotifyFormat) throws -> Data {
        try wireBody(format: format).data
    }

    /// The ntfy message body: `text` without its first line when that line
    /// is the title (the composed text always leads with it).
    private var ntfyBodyText: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, String(first) == title else { return text }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTTP-header-safe rendering of a string: header values cannot carry
    /// newlines (response splitting), and ntfy documents non-ASCII header
    /// titles as needing RFC 2047 encoding — our titles are ASCII by
    /// construction, so anything outside printable ASCII is dropped rather
    /// than encoded.
    static func headerSafe(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F })
    }

    // MARK: - Wire structs

    private struct DiscordBody: Encodable {
        let content: String
    }

    private struct SlackBody: Encodable {
        let text: String
    }

    private struct GenericBody: Encodable {
        let source: String
        let title: String
        let text: String
        let category: String
        let severity: String
        let outcome: String
        let reason: String
        let session: String
        let project: String?
        let detail: String
    }

    // MARK: - Helpers

    /// Last path component of a directory string, with any trailing slash
    /// ignored. Deliberately string-only (no URL round trip) so a cwd that
    /// is not a valid file URL still yields something rather than nil.
    static func basename(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last else { return trimmed }
        return String(last)
    }

    /// Truncate to `limit` characters, appending a marker so the reader can
    /// tell a short message from a cut one.
    static func clip(_ input: String, to limit: Int) -> String {
        guard input.count > limit else { return input }
        return String(input.prefix(limit)) + "..."
    }
}
