// RemoteNotifier.swift. The second conformer to `Notifying`.
//
// Posts an escalation to an owner-supplied webhook so a pause that nobody is
// looking at stops being a silent stall. It ADDS to the banner;
// `FanoutNotifier` owns the composition and the banner always fires first.
//
// Five gates, in order, every one of them traced:
//
//   1. enabled       : off unless config.yaml says on.
//   2. endpoint      : a URL must be stored. The notifier can exist WITHOUT
//                      one (so a URL stored while the app runs is applied
//                      live via `apply(endpoint:)`), but nothing posts
//                      until it holds a validated endpoint.
//   3. policy        : `RemoteNotifyPolicy`, so only owner-blocking events
//                      and high-severity flags leave the machine.
//   4. dedupe        : one message per session/outcome/category per window,
//                      so a stuck loop pages once and not forty times. An
//                      in-flight reservation covers the gap the delivered
//                      stamp cannot: two concurrent identical escalations
//                      would both pass the stamp check before either POST
//                      returns.
//   5. https + redact: `RemoteWebhookURL` refuses anything but https, and
//                      `RemoteNotifyPayload` redacts before encoding.
//
// A remote failure never changes what happened locally. The banner has
// already posted, the intervention has already landed, and this returns
// `.failed` for the trace log and nothing else. Nothing here throws into
// the router or retries forever — but the attempt DOES run on the router's
// dispatch task, and with the default two attempts, ten-second timeout and
// two-second retry pause a dead endpoint can hold that task for ~22s.
// Bounded, and strictly after the intervention and the banner, never
// before either.
//
// Dedupe is stamped on SUCCESS only. Stamping on attempt would mean one
// dropped packet costs the owner the whole window, and the entire point of
// the channel is that the pause notification arrives.

import Foundation

/// Transport seam. Exists so tests can assert on bytes and status handling
/// without a network, and so a future transport (a local relay, a different
/// auth shape) drops in without touching the policy.
public protocol RemoteNotifyTransport: Sendable {
    /// POST `body.data` to `url` with `body.contentType` and the format's
    /// extra headers (C13: ntfy carries the message title as a `Title`
    /// header, so content-type and headers are the payload's business, not
    /// the transport's). Returns the HTTP status code. Throws only on
    /// transport failure, never on a non-2xx status.
    func post(_ body: RemoteNotifyPayload.WireBody, to url: URL) async throws -> Int
}

/// Production transport. Short timeout because a notification that arrives
/// two minutes late has already been overtaken by the owner walking to the
/// Mac, and a long timeout keeps a task alive for no benefit.
///
/// The session is a dedicated ephemeral one, not `.shared`: no cookies, no
/// cache, nothing persisted between posts, and BOTH timeout knobs pinned
/// (`timeoutIntervalForRequest` covers the idle wait; without
/// `timeoutIntervalForResource` the system default of seven days still
/// bounds the transfer as a whole). Redirects are refused outright: a
/// webhook answering 3xx is either misconfigured or moving the
/// credential-bearing POST somewhere else, and either way the caller should
/// see the 3xx as a rejected status, never a silent second request.
public struct URLSessionRemoteNotifyTransport: RemoteNotifyTransport {

    private let session: URLSession
    private let timeout: TimeInterval

    /// Completes every redirect decision with nil, so URLSession stops at
    /// the 3xx response itself and `post` reports its status code.
    private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    public init(timeout: TimeInterval = 10) {
        self.init(timeout: timeout, configuration: .ephemeral)
    }

    /// Internal seam so tests can slot a mock `URLProtocol` into the SAME
    /// session construction the production path uses — delegate, cookie and
    /// cache posture included — rather than a lookalike.
    init(timeout: TimeInterval, configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(
            configuration: configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
        self.timeout = timeout
    }

    public func post(_ body: RemoteNotifyPayload.WireBody, to url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Supervisor", forHTTPHeaderField: "User-Agent")
        // Format-carried headers (ntfy's Title). Sorted so the request is
        // deterministic for byte-level assertions.
        for (field, value) in body.headers.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = timeout
        request.httpBody = body.data
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteNotifyError.transport(underlying: "non-HTTP response")
            }
            return http.statusCode
        } catch let e as RemoteNotifyError {
            throw e
        } catch {
            // Never interpolate the raw error: URLSession's NSErrors carry
            // the full failing URL (NSErrorFailingURLKey and friends), and
            // the webhook URL is a bearer credential. The sanitizer keeps
            // the code and the human-readable failure, drops the rest.
            throw RemoteNotifyError.transport(
                underlying: RemoteNotifier.traceSafeMessage(for: error)
            )
        }
    }
}

/// Typed failures for the remote channel. Callers branch on these, never on
/// message text.
///
/// None of these cases carries the webhook URL. A Discord or Slack webhook
/// URL is a bearer credential: anyone holding it can post as the owner. It is
/// never written to the trace log, never put in an error, and never rendered
/// in the UI. Only the host is ever logged.
public enum RemoteNotifyError: Error, Sendable, Equatable {

    /// The stored string did not parse into something postable. `hint`
    /// describes the shape problem and never quotes the input.
    case malformedURL(hint: String)

    /// Scheme was not https. Plain http would put the message, and the
    /// credential in the URL path, on the wire in the clear.
    case insecureURL(scheme: String)

    /// URLSession-level failure: no network, DNS, TLS, timeout.
    case transport(underlying: String)

    /// The endpoint answered with a non-2xx status.
    case rejected(status: Int)

    /// JSONEncoder refused the payload. Should not happen (every field is a
    /// String) but a silent empty POST would be worse than a trace line.
    case encodingFailed(reason: String)
}

extension RemoteNotifyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedURL(let h):   return "Remote notify URL is not usable: \(h)"
        case .insecureURL(let s):    return "Remote notify URL must be https, got \(s)"
        case .transport(let u):      return "Remote notify transport failed: \(u)"
        case .rejected(let s):       return "Remote notify endpoint rejected the post: HTTP \(s)"
        case .encodingFailed(let r): return "Remote notify payload encode failed: \(r)"
        }
    }
}

/// A validated webhook destination. The https check lives in the initializer,
/// so there is no way to construct a `RemoteNotifier` around a plaintext
/// endpoint. Safety gates that can be skipped by a convenient call site are
/// not gates.
public struct RemoteWebhookURL: Sendable, Equatable {

    public let url: URL
    /// Wire shape, detected once at construction from the host.
    public let format: RemoteNotifyFormat

    /// Host only, safe to log. The path carries the credential.
    public var loggableHost: String { url.host ?? "?" }

    public init(validating raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteNotifyError.malformedURL(hint: "empty")
        }
        guard let parsed = URL(string: trimmed) else {
            throw RemoteNotifyError.malformedURL(hint: "not a URL")
        }
        guard let scheme = parsed.scheme?.lowercased(), !scheme.isEmpty else {
            throw RemoteNotifyError.malformedURL(hint: "no scheme")
        }
        guard scheme == "https" else {
            throw RemoteNotifyError.insecureURL(scheme: scheme)
        }
        guard let host = parsed.host, !host.isEmpty else {
            throw RemoteNotifyError.malformedURL(hint: "no host")
        }
        self.url = parsed
        self.format = RemoteNotifyFormat.detect(from: parsed)
    }
}

public final class RemoteNotifier: Notifying, @unchecked Sendable {

    /// Live-reloadable knobs. Everything here can change while the app runs,
    /// because `config.yaml` is watched and the owner flipping the toggle
    /// should not require a relaunch.
    public struct Configuration: Sendable, Equatable {

        /// Master switch. False means the notifier is constructed but inert.
        public var enabled: Bool

        /// How much of the session may cross the network.
        public var detail: RemoteNotifyDetail

        /// Collapse identical escalations inside this many seconds. Zero
        /// disables collapsing.
        public var dedupeWindow: TimeInterval

        /// Total POST attempts per message, including the first. Two means
        /// one retry. Bounded on purpose: an unreachable endpoint must not
        /// turn into a background task that outlives the intervention.
        public var maxAttempts: Int

        /// Pause between attempts.
        public var retryDelay: TimeInterval

        /// C13: wire-shape override, for endpoints whose host cannot be
        /// detected (a self-hosted ntfy server on the owner's own domain).
        /// nil (the default) means detect from the URL host, which keeps
        /// Discord / Slack / ntfy.sh working with zero configuration.
        public var formatOverride: RemoteNotifyFormat?

        public init(
            enabled: Bool = false,
            detail: RemoteNotifyDetail = .minimal,
            dedupeWindow: TimeInterval = 60,
            maxAttempts: Int = 2,
            retryDelay: TimeInterval = 2,
            formatOverride: RemoteNotifyFormat? = nil
        ) {
            self.enabled = enabled
            self.detail = detail
            self.dedupeWindow = dedupeWindow
            self.maxAttempts = maxAttempts
            self.retryDelay = retryDelay
            self.formatOverride = formatOverride
        }
    }

    /// Delivery destination. Optional and lock-guarded on purpose: the
    /// notifier is constructable BEFORE a webhook URL exists, so the config
    /// watcher can complete it live (`apply(endpoint:)`) the moment the
    /// owner stores one — the documented setup order stores the URL first
    /// and flips the switch second, and requiring a relaunch between those
    /// two steps is the papercut this optionality removes. With no endpoint,
    /// delivery skips with its own trace reason and nothing else changes.
    private var endpoint: RemoteWebhookURL?
    private let transport: any RemoteNotifyTransport
    private let redactor: any Redactor
    private let trace: TraceLog
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var configuration: Configuration
    /// dedupe key to the time it was last DELIVERED.
    private var lastDelivered: [String: Date] = [:]
    /// System-channel dedupe: key to (delivered stamp, the window it was
    /// stamped under). A SEPARATE map from `lastDelivered` on purpose — the
    /// intervention map is pruned against the one configured window, and
    /// system messages carry per-call windows (a health page dedupes
    /// differently from an hourly cost-cap page), so each entry must be
    /// pruned against its own window or a short-window prune would evict a
    /// long-window stamp early.
    private var lastSystemDelivered: [String: (stamp: Date, window: TimeInterval)] = [:]
    /// C7: rolling record of how delivery itself is doing, updated by every
    /// attempt loop under the same lock. The panel's Remote escalation row
    /// renders it, because a channel that has been failing for an hour and a
    /// channel that delivered three minutes ago look identical from the
    /// enabled toggle alone — and the owner planning to step away needs to
    /// know which one they have.
    private var health = DeliveryHealth()

    /// Snapshot of the channel's delivery health. Value type out, so the
    /// caller can render it without holding anything.
    public struct DeliveryHealth: Sendable, Equatable {
        /// When the last successful delivery (any lane: intervention,
        /// system, test) completed. nil = never delivered this run.
        public var lastSuccessAt: Date?
        /// Length of the CURRENT unbroken failure run. 0 while healthy.
        public var consecutiveFailures: Int
        /// When the current failure run began. nil while healthy.
        public var firstFailureAt: Date?
        /// The last failure's short tag (http_404, transport, encode).
        /// Never a URL: tags come from failureTag, which carries none.
        public var lastFailureReason: String?

        public init(
            lastSuccessAt: Date? = nil,
            consecutiveFailures: Int = 0,
            firstFailureAt: Date? = nil,
            lastFailureReason: String? = nil
        ) {
            self.lastSuccessAt = lastSuccessAt
            self.consecutiveFailures = consecutiveFailures
            self.firstFailureAt = firstFailureAt
            self.lastFailureReason = lastFailureReason
        }
    }

    public var deliveryHealth: DeliveryHealth {
        lock.lock(); defer { lock.unlock() }
        return health
    }
    /// Keys currently being POSTed. Covers the check-then-send window the
    /// delivered stamp cannot: the stamp lands only after the transport
    /// returns, so two concurrent escalations for the same key would both
    /// pass the dedupe gate and both page the owner. Reserved before the
    /// POST, released when the attempt (success or failure) is over.
    private var inFlight: Set<String> = []

    public init(
        endpoint: RemoteWebhookURL?,
        configuration: Configuration = Configuration(),
        transport: any RemoteNotifyTransport = URLSessionRemoteNotifyTransport(),
        redactor: any Redactor = DefaultRedactor(),
        trace: TraceLog = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.transport = transport
        self.redactor = redactor
        self.trace = trace
        self.now = now
        trace.emit(
            "remote",
            "remote.configured host=\(endpoint?.loggableHost ?? "none") format=\(endpoint.map { "\($0.format)" } ?? "none") enabled=\(configuration.enabled) detail=\(configuration.detail.rawValue)"
        )
    }

    /// Apply a new configuration, e.g. after `config.yaml` changed. Traces
    /// the transition only when something actually moved, so a watcher that
    /// fires on every editor save does not flood the log.
    public func apply(_ new: Configuration) {
        lock.lock()
        let old = configuration
        configuration = new
        lock.unlock()
        guard old != new else { return }
        trace.emit(
            "remote",
            "remote.config_changed enabled=\(old.enabled)->\(new.enabled) detail=\(old.detail.rawValue)->\(new.detail.rawValue) dedupe=\(Int(old.dedupeWindow))s->\(Int(new.dedupeWindow))s"
        )
    }

    /// Current configuration snapshot. Public for the wiring layer and tests;
    /// the notifier itself always reads under the lock.
    public var currentConfiguration: Configuration {
        lock.lock(); defer { lock.unlock() }
        return configuration
    }

    /// Late endpoint arrival: the owner stored a webhook URL while the app
    /// was already running, and the config watcher re-read the Keychain.
    /// Validation is not repeated here because it cannot be skipped —
    /// `RemoteWebhookURL` is the only way to construct the parameter, and
    /// its initializer is where the https check lives.
    public func apply(endpoint new: RemoteWebhookURL) {
        lock.lock()
        let old = endpoint
        endpoint = new
        let changed = old != new
        // Delivery health describes ONE endpoint. Carrying it across a swap
        // made the panel say "Delivered 12m ago" about the webhook the owner
        // had just replaced, which reads as "the new one works" at exactly the
        // moment the owner is checking whether it does. A fresh endpoint has
        // no delivery history until it delivers something.
        if changed { health = DeliveryHealth() }
        lock.unlock()
        guard changed else { return }
        trace.emit("remote", "remote.endpoint_applied host=\(new.loggableHost) format=\(new.format) delivery_health=reset")
    }

    /// Whether a delivery destination is currently held. The wiring layer
    /// reads this to decide when a Keychain re-read is worth doing; the
    /// notifier itself always reads `endpoint` under the lock.
    public var hasEndpoint: Bool {
        lock.lock(); defer { lock.unlock() }
        return endpoint != nil
    }

    private var currentEndpoint: RemoteWebhookURL? {
        lock.lock(); defer { lock.unlock() }
        return endpoint
    }

    // MARK: - Notifying

    /// Legacy single-argument path. Treated as a plain notify outcome so the
    /// policy still gets to decide (a low-severity flag posted through this
    /// entry point must not bypass the volume gate).
    @discardableResult
    public func post(decision: TriageDecision) async -> Notifier.Outcome {
        await postInterventionResult(decision: decision, outcome: .notifyOnly)
    }

    /// Deliver, or explain in the trace why not.
    ///
    /// Outcome mapping, kept narrow so the router's existing logging reads
    /// the same for both channels:
    ///   `.posted`                 the endpoint accepted it (2xx).
    ///   `.skippedDeniedSilently`  a gate said no. Nothing was sent and
    ///                             nothing is wrong.
    ///   `.failed(reason:)`        we tried and could not deliver.
    @discardableResult
    public func postInterventionResult(
        decision: TriageDecision,
        outcome: InterventionOutcome
    ) async -> Notifier.Outcome {
        let config = currentConfiguration
        let kind = RemoteNotifyPolicy.outcomeKind(outcome)

        guard config.enabled else {
            trace.emit("remote", "remote.skipped reason=disabled kind=\(kind)")
            return .skippedDeniedSilently
        }

        // Endpoint gate right after the switch: "on but no URL yet" is the
        // one state the owner can fix from here (store the URL; the config
        // watcher applies it live), so it gets its own reason rather than
        // hiding behind a policy skip.
        guard let endpoint = currentEndpoint else {
            trace.emit("remote", "remote.skipped reason=no_endpoint kind=\(kind) session=\(decision.sessionId)")
            return .skippedDeniedSilently
        }

        let verdict = RemoteNotifyPolicy.verdict(decision: decision, outcome: outcome)
        guard case .deliver(let reason) = verdict else {
            trace.emit("remote", "remote.skipped reason=\(verdict.reason) kind=\(kind) session=\(decision.sessionId)")
            return .skippedDeniedSilently
        }

        let key = RemoteNotifyPolicy.dedupeKey(decision: decision, outcome: outcome)
        if let age = suppressedAge(for: key, window: config.dedupeWindow) {
            trace.emit(
                "remote",
                "remote.suppressed reason=dedupe_window kind=\(kind) session=\(decision.sessionId) age=\(Int(age))s window=\(Int(config.dedupeWindow))s"
            )
            return .skippedDeniedSilently
        }

        // Reserve the key BEFORE the POST. The delivered stamp lands only on
        // success, after the transport returns; without the reservation two
        // concurrent identical escalations both pass the stamp check and the
        // owner is paged twice for one event.
        guard reserveInFlight(key) else {
            trace.emit("remote", "remote.skipped reason=in_flight kind=\(kind) session=\(decision.sessionId)")
            return .skippedDeniedSilently
        }
        defer { releaseInFlight(key) }

        let payload = RemoteNotifyPayload.compose(
            decision: decision,
            outcome: outcome,
            reason: reason,
            detail: config.detail,
            redactor: redactor
        )
        let wire: RemoteNotifyPayload.WireBody
        do {
            wire = try payload.wireBody(format: resolvedFormat(for: endpoint, config: config))
        } catch {
            // Type name only: an encoding error’s description can quote the
            // payload it choked on, and this line crosses into the trace log.
            trace.emit("remote", "remote.failed reason=encode kind=\(kind) error=\(String(describing: type(of: error)))")
            return .failed(reason: "encode")
        }

        return await deliver(
            wire: wire, to: endpoint, kind: kind, reason: reason, config: config,
            stampDelivered: { [weak self] in self?.stampDelivered(key, window: config.dedupeWindow) }
        )
    }

    /// C13: the wire shape one message actually uses — the owner's explicit
    /// override when set (self-hosted ntfy), host detection otherwise.
    private func resolvedFormat(for endpoint: RemoteWebhookURL, config: Configuration) -> RemoteNotifyFormat {
        config.formatOverride ?? endpoint.format
    }

    // MARK: - System messages (Supervisor's own health, not an intervention)

    /// Deliver a message ABOUT Supervisor itself: an engine-health page from
    /// the status-bar companion, a cost-cap or provider-failure alert. No
    /// `TriageDecision` exists for these, so they bypass `RemoteNotifyPolicy`
    /// (their callers ARE the policy: transition edges, hourly throttles) but
    /// keep every other gate — the enabled switch, the https-validated
    /// endpoint, and a dedupe window of their own passed per call, because
    /// one size does not fit both a health transition (self-limiting, small
    /// window) and a failing-provider storm (hourly).
    ///
    /// `title` and `body` must contain nothing session-derived; they are
    /// still run through the redactor as defense in depth.
    @discardableResult
    public func postSystemMessage(
        title: String,
        body bodyText: String,
        kind: String,
        dedupeWindow: TimeInterval = 0
    ) async -> Notifier.Outcome {
        let config = currentConfiguration
        guard config.enabled else {
            trace.emit("remote", "remote.skipped reason=disabled kind=\(kind)")
            return .skippedDeniedSilently
        }
        // No endpoint is a FAILURE here, not a silent skip. `enabled=false`
        // means the owner said no — retrying changes nothing, so it stamps
        // complete upstream. An empty endpoint slot means the URL has not
        // REACHED this notifier yet (the owner may well have one stored;
        // the companion's boot warm can time out and its 5-minute refresh
        // fills the slot later), so the caller's retry ladder must keep the
        // page alive instead of marking it delivered. Delivery health is
        // untouched: nothing was attempted, so this says nothing about
        // whether sending works.
        guard let endpoint = currentEndpoint else {
            trace.emit("remote", "remote.failed reason=no_endpoint kind=\(kind)")
            return .failed(reason: "no_endpoint")
        }
        let key = "system|\(kind)"
        if let age = systemSuppressedAge(for: key, window: dedupeWindow) {
            trace.emit(
                "remote",
                "remote.suppressed reason=system_dedupe kind=\(kind) age=\(Int(age))s window=\(Int(dedupeWindow))s"
            )
            return .skippedDeniedSilently
        }
        guard reserveInFlight(key) else {
            trace.emit("remote", "remote.skipped reason=in_flight kind=\(kind)")
            return .skippedDeniedSilently
        }
        defer { releaseInFlight(key) }

        let payload = RemoteNotifyPayload(
            title: redactor.redact(title),
            text: RemoteNotifyPayload.clip(
                redactor.redact("\(title)\n\(bodyText)"),
                to: RemoteNotifyPayload.maxTextLength
            ),
            category: "supervisor_system",
            severity: "high",
            outcomeKind: kind,
            reason: "system_health",
            sessionShort: "",
            project: nil,
            detail: config.detail
        )
        let wire: RemoteNotifyPayload.WireBody
        do {
            wire = try payload.wireBody(format: resolvedFormat(for: endpoint, config: config))
        } catch {
            // Type name only: an encoding error’s description can quote the
            // payload it choked on, and this line crosses into the trace log.
            trace.emit("remote", "remote.failed reason=encode kind=\(kind) error=\(String(describing: type(of: error)))")
            return .failed(reason: "encode")
        }
        return await deliver(
            wire: wire, to: endpoint, kind: kind, reason: "system_health", config: config,
            stampDelivered: { [weak self] in self?.stampSystemDelivered(key, window: dedupeWindow) }
        )
    }

    /// C2/D1 convenience: a Supervisor-is-down escalation. The PAGING
    /// policy lives in the engine's incident ledger (one page when the
    /// incident opens, one repeat after 6 hours, cleared on the first
    /// successful call); this window is only the storm guard behind it,
    /// short enough that a new incident the ledger re-opens still pages.
    @discardableResult
    public func postSystemEvent(_ event: SystemEscalationEvent) async -> Notifier.Outcome {
        await postSystemMessage(
            title: event.title,
            body: event.body,
            kind: event.kind,
            dedupeWindow: SystemEscalationEvent.remoteStormGuardSeconds
        )
    }

    // MARK: - Test send (panel "Send test" button)

    /// One synthetic message through THIS notifier's endpoint and transport,
    /// so a green result in the panel proves the exact channel a real
    /// escalation would use — not a lookalike built fresh for the test.
    ///
    /// Two gates deliberately do NOT apply here: the `enabled` switch (the
    /// owner explicitly clicked Send test, and proving delivery BEFORE
    /// flipping the switch on is the documented setup order) and the policy
    /// plus dedupe (a test is not an escalation, and the owner may well
    /// click twice in a row). The endpoint gate and the https validation
    /// behind it still hold — there is nothing to test without a URL.
    @discardableResult
    public func sendTest() async -> Notifier.Outcome {
        let config = currentConfiguration
        guard let endpoint = currentEndpoint else {
            trace.emit("remote", "remote.test_skipped reason=no_endpoint")
            return .skippedDeniedSilently
        }
        let payload = RemoteNotifyPayload(
            title: "Supervisor test message",
            text: "Supervisor test message. Remote escalation delivery is reaching this endpoint.",
            category: "remote_notify_test",
            severity: "low",
            outcomeKind: "test",
            reason: "owner_test",
            sessionShort: "",
            project: nil,
            detail: config.detail
        )
        let wire: RemoteNotifyPayload.WireBody
        do {
            wire = try payload.wireBody(format: resolvedFormat(for: endpoint, config: config))
        } catch {
            // Same rule as the delivery paths: type name only, never the
            // error's own text.
            trace.emit("remote", "remote.test_failed reason=encode error=\(String(describing: type(of: error)))")
            return .failed(reason: "encode")
        }
        trace.emit("remote", "remote.test_send host=\(endpoint.loggableHost) enabled=\(config.enabled)")
        // No dedupe stamp: the test must never collapse into (or stamp over)
        // a real escalation's window, and two clicks mean two sends.
        return await deliver(
            wire: wire,
            to: endpoint,
            kind: "test",
            reason: "owner_test",
            config: config,
            stampDelivered: {}
        )
    }

    // MARK: - Delivery

    /// `stampDelivered` runs exactly once, on the 2xx that ends the attempt
    /// loop — the caller decides WHICH dedupe ledger (intervention, system,
    /// or none for a test send) the success is recorded in, so this function
    /// stays a pure delivery loop.
    private func deliver(
        wire: RemoteNotifyPayload.WireBody,
        to endpoint: RemoteWebhookURL,
        kind: String,
        reason: String,
        config: Configuration,
        stampDelivered: () -> Void
    ) async -> Notifier.Outcome {
        let attempts = max(1, config.maxAttempts)
        var lastError: RemoteNotifyError = .transport(underlying: "no attempt made")

        for attempt in 1...attempts {
            do {
                let status = try await transport.post(wire, to: endpoint.url)
                if (200..<300).contains(status) {
                    stampDelivered()
                    recordDeliverySuccess()
                    trace.emit(
                        "remote",
                        "remote.delivered host=\(endpoint.loggableHost) kind=\(kind) reason=\(reason) status=\(status) bytes=\(wire.data.count) attempt=\(attempt)"
                    )
                    return .posted
                }
                lastError = .rejected(status: status)
                trace.emit(
                    "remote",
                    "remote.rejected host=\(endpoint.loggableHost) kind=\(kind) status=\(status) attempt=\(attempt)/\(attempts)"
                )
                guard Self.isRetryable(lastError), attempt < attempts else {
                    recordDeliveryFailure(tag: "http_\(status)")
                    return .failed(reason: "http_\(status)")
                }
            } catch let e as RemoteNotifyError {
                lastError = e
                trace.emit(
                    "remote",
                    "remote.transport_error host=\(endpoint.loggableHost) kind=\(kind) attempt=\(attempt)/\(attempts) error=\(Self.traceSafeMessage(for: e))"
                )
                guard Self.isRetryable(e), attempt < attempts else {
                    recordDeliveryFailure(tag: "transport")
                    return .failed(reason: "transport")
                }
            } catch {
                lastError = .transport(underlying: Self.traceSafeMessage(for: error))
                trace.emit(
                    "remote",
                    "remote.transport_error host=\(endpoint.loggableHost) kind=\(kind) attempt=\(attempt)/\(attempts) error=\(Self.traceSafeMessage(for: error))"
                )
                guard attempt < attempts else {
                    recordDeliveryFailure(tag: "transport")
                    return .failed(reason: "transport")
                }
            }
            await sleepBeforeRetry(config.retryDelay)
        }

        recordDeliveryFailure(tag: Self.failureTag(lastError))
        return .failed(reason: Self.failureTag(lastError))
    }

    // MARK: - Delivery-health bookkeeping (C7)

    /// One ATTEMPT LOOP is one health data point (retries inside it are the
    /// loop's own business): a 2xx anywhere resets the failure run, a loop
    /// that ends failed extends it. Gate-skips never touch health — a
    /// message that was not supposed to send says nothing about whether
    /// sending works.
    private func recordDeliverySuccess() {
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        health.lastSuccessAt = stamp
        health.consecutiveFailures = 0
        health.firstFailureAt = nil
        health.lastFailureReason = nil
    }

    private func recordDeliveryFailure(tag: String) {
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        health.consecutiveFailures += 1
        if health.firstFailureAt == nil { health.firstFailureAt = stamp }
        health.lastFailureReason = tag
    }

    /// Trace-safe rendering of a delivery error. URLSession errors carry the
    /// full failing URL (in `userInfo` and sometimes in the description),
    /// and the webhook URL is a bearer credential, so no raw `Error` is ever
    /// interpolated into a trace line on this path. A `URLError` is reduced
    /// to its numeric code alone — not its localizedDescription, because
    /// nobody can prove every localized string for every code on every OS
    /// build is URL-free, and the code is what a debugging session needs; a
    /// typed `RemoteNotifyError` keeps its description (URL-free by that
    /// enum's contract); anything else is reduced to its type name.
    static func traceSafeMessage(for error: Error) -> String {
        switch error {
        case let e as RemoteNotifyError:
            return e.errorDescription ?? "?"
        case let e as URLError:
            return "URLError \(e.code.rawValue)"
        default:
            return String(describing: type(of: error))
        }
    }

    /// Retry only where a retry can plausibly help: transport blips, rate
    /// limits, and server-side errors. A 400 or a 404 means the URL or the
    /// payload is wrong and hammering it changes nothing.
    static func isRetryable(_ error: RemoteNotifyError) -> Bool {
        switch error {
        case .transport:
            return true
        case .rejected(let status):
            return status == 408 || status == 429 || status >= 500
        case .malformedURL, .insecureURL, .encodingFailed:
            return false
        }
    }

    /// Short stable tag for the `.failed` reason string.
    static func failureTag(_ error: RemoteNotifyError) -> String {
        switch error {
        case .transport:            return "transport"
        case .rejected(let status): return "http_\(status)"
        case .encodingFailed:       return "encode"
        case .malformedURL:         return "malformed_url"
        case .insecureURL:          return "insecure_url"
        }
    }

    private func sleepBeforeRetry(_ delay: TimeInterval) async {
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: - Dedupe bookkeeping

    /// Age of the last delivery for `key` if it is still inside `window`, nil
    /// if this message should go. Prunes expired entries while it holds the
    /// lock so the map cannot grow across a long-lived session.
    private func suppressedAge(for key: String, window: TimeInterval) -> TimeInterval? {
        guard window > 0 else { return nil }
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        lastDelivered = lastDelivered.filter { stamp.timeIntervalSince($0.value) < window }
        guard let previous = lastDelivered[key] else { return nil }
        return stamp.timeIntervalSince(previous)
    }

    /// System-channel twin of `suppressedAge`. Each entry prunes against
    /// the window it was STAMPED under, not the window of the current call,
    /// so mixed cadences coexist in one map.
    private func systemSuppressedAge(for key: String, window: TimeInterval) -> TimeInterval? {
        guard window > 0 else { return nil }
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        lastSystemDelivered = lastSystemDelivered.filter {
            stamp.timeIntervalSince($0.value.stamp) < $0.value.window
        }
        guard let previous = lastSystemDelivered[key] else { return nil }
        return stamp.timeIntervalSince(previous.stamp)
    }

    private func stampSystemDelivered(_ key: String, window: TimeInterval) {
        // Same rule as the intervention stamp: an off (non-positive) window
        // must not write, or the entry would never be pruned.
        guard window > 0 else { return }
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        lastSystemDelivered[key] = (stamp: stamp, window: window)
    }

    private func stampDelivered(_ key: String, window: TimeInterval) {
        // A non-positive window means dedupe is off, and an off dedupe must
        // not write: pruning lives only in `suppressedAge`, which
        // early-returns at window <= 0, so every stamp written here would
        // sit in the map for the life of the process.
        guard window > 0 else { return }
        let stamp = now()
        lock.lock(); defer { lock.unlock() }
        lastDelivered[key] = stamp
    }

    private func reserveInFlight(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }

    private func releaseInFlight(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(key)
    }
}
