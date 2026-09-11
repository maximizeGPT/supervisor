// RemoteInboxSubscriber.swift. The socket an owner's reply arrives on.
//
// ntfy's JSON stream endpoint (`GET /<topic>/json`) is a long-lived HTTP
// response that never ends: one JSON object per line, a keepalive every ~45
// seconds, a `message` object whenever somebody posts. That is the whole
// transport. No account, no server, no inbound port on the owner's Mac,
// which is the point: the reply path has to cost the same zero
// infrastructure the outbound page does.
//
// Three failure shapes and what each does:
//
//   the stream drops       reconnect after a bounded backoff. A lid
//                          closing, a wifi handoff and ntfy cycling a
//                          connection all look identical here and all want
//                          the same answer.
//   the stream keeps       after `pollFallbackThreshold` consecutive
//   failing                failures, poll (`?poll=1&since=…`) on a slow
//                          timer as well. A poll is an ordinary short
//                          request, so it survives the middleboxes and
//                          captive portals that kill long responses. The
//                          loop keeps trying the stream, because polling is
//                          the degraded mode and not the destination.
//   the response is not    a failure, not an empty stream. A 404 or an HTML
//   a stream               error page must never read as "no replies",
//                          which is indistinguishable from a healthy quiet
//                          channel.
//   the endpoint refuses   a 401, 403 or 404 is not a blip and will not
//   us outright            heal on the next attempt: the topic is gone,
//                          the server wants a token, or the URL is wrong.
//                          Retrying that every thirty seconds is a loop
//                          that can only fail, so the loop drops to a
//                          minutes-scale cadence, pages the owner ONCE per
//                          episode, and says so in the panel. It keeps
//                          probing, slowly, because an endpoint that was
//                          fixed should pick up again with no relaunch.
//
// WHAT THIS TYPE DOES NOT DO. It does not decide anything. It yields
// decoded messages and nothing else; the replay check, the rate limit, the
// size cap, the code lookup and the safety screen all live in
// `RemoteReplyGate`. Keeping the socket dumb is what makes those gates
// testable without one.
//
// The topic never appears in a trace line from this file. Every log names
// the HOST and nothing else, and URLSession errors are reduced the same way
// `RemoteNotifier` reduces them, because an NSError carries the full
// failing URL and the topic is in that URL's path.

import Foundation

/// One decoded line off the stream. ntfy sends several event types down the
/// same connection; only `message` carries owner text.
public struct RemoteInboxMessage: Sendable, Equatable {
    /// ntfy's message id. Two jobs: the `since` cursor for the poll
    /// fallback, and the replay key that stops one post from being injected
    /// twice when a reconnect re-delivers it.
    public let id: String
    /// `message`, `open`, `keepalive`, `poll_request`.
    public let event: String
    /// The posted body. Empty for non-message events.
    public let message: String

    public init(id: String, event: String, message: String) {
        self.id = id
        self.event = event
        self.message = message
    }

    public var isMessage: Bool { event == "message" && !message.isEmpty }

    /// Decode one JSON line. Returns nil for anything that is not a JSON
    /// object with an id and an event: a blank keepalive line, a truncated
    /// final line, or an HTML error body being read a line at a time.
    public static func decode(line: String) -> RemoteInboxMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { return nil }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty,
            let event = object["event"] as? String
        else { return nil }
        return RemoteInboxMessage(
            id: id,
            event: event,
            message: (object["message"] as? String) ?? ""
        )
    }
}

/// Transport seam, mirroring `RemoteNotifyTransport` on the outbound side.
/// It exists so every gate downstream is tested against a scripted stub that
/// never opens a socket.
public protocol RemoteInboxTransport: Sendable {
    /// Open the long-lived stream and yield each raw line as it arrives. The
    /// stream finishes when the server closes it, and throws when the
    /// connection fails or the response is not a 2xx stream.
    func stream(url: URL) -> AsyncThrowingStream<String, Error>

    /// One poll request: every message since `since`, then done.
    func poll(url: URL) async throws -> [String]
}

/// Production transport. Same posture as `URLSessionRemoteNotifyTransport`:
/// a dedicated ephemeral session (no cookies, no cache, nothing persisted)
/// and redirects refused, because a 3xx on a credential-bearing URL is
/// either a misconfiguration or somebody moving the topic somewhere else.
///
/// The one deliberate difference from the outbound POST is the timeout. A
/// subscribe is a response that is SUPPOSED to stay open for hours, so only
/// the idle-wait knob is pinned, generously, past ntfy's 45-second keepalive
/// so a quiet channel is not mistaken for a dead one.
public struct URLSessionRemoteInboxTransport: RemoteInboxTransport {

    /// Idle-wait ceiling. Two missed keepalives is a genuinely dead
    /// connection.
    public static let defaultStreamIdleTimeout: TimeInterval = 120

    /// A poll is an ordinary short request and gets an ordinary timeout.
    public static let defaultPollTimeout: TimeInterval = 20

    /// Hard cap on one line off the stream, in bytes. ntfy's own default
    /// message limit is 4 KB and the gate refuses far smaller bodies, so
    /// this is not a functional limit: it is the bound that stops an
    /// endpoint (compromised, impersonated by DNS, or simply wrong) from
    /// making the app buffer without end while it waits for a newline.
    public static let maxLineBytes = 64 * 1024

    /// Bytes read from one poll response before it is abandoned. A poll
    /// returns a bounded backlog; this is the same anti-buffering bound in
    /// the request-shaped lane.
    public static let maxPollBytes = 512 * 1024

    private let session: URLSession
    private let pollTimeout: TimeInterval

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

    public init(
        streamIdleTimeout: TimeInterval = URLSessionRemoteInboxTransport.defaultStreamIdleTimeout,
        pollTimeout: TimeInterval = URLSessionRemoteInboxTransport.defaultPollTimeout
    ) {
        self.init(
            streamIdleTimeout: streamIdleTimeout,
            pollTimeout: pollTimeout,
            configuration: .ephemeral
        )
    }

    /// Internal seam so tests can slot a mock `URLProtocol` into the SAME
    /// session construction the production path uses.
    init(streamIdleTimeout: TimeInterval, pollTimeout: TimeInterval, configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = streamIdleTimeout
        self.session = URLSession(
            configuration: configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
        self.pollTimeout = pollTimeout
    }

    private func request(_ url: URL, timeout: TimeInterval?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Supervisor", forHTTPHeaderField: "User-Agent")
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    public func stream(url: URL) -> AsyncThrowingStream<String, Error> {
        let request = request(url, timeout: nil)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteInboxTransportError.notHTTP
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // A 404 (topic gone), a 401 (auth wrong) or a 500
                        // must surface as a FAILURE. Finishing the stream
                        // cleanly would make a broken channel look like a
                        // quiet one, which is the failure mode the whole
                        // health story exists to prevent.
                        throw RemoteInboxTransportError.rejected(status: http.statusCode)
                    }
                    // Accumulate lines by hand rather than using
                    // `bytes.lines`, purely so the length cap is
                    // enforceable: `lines` will buffer an unterminated
                    // response until the process runs out of memory, and
                    // this stream's whole job is to stay open for hours
                    // against an endpoint we do not control.
                    var buffer = [UInt8]()
                    buffer.reserveCapacity(1024)
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                            continue
                        }
                        buffer.append(byte)
                        if buffer.count > Self.maxLineBytes {
                            throw RemoteInboxTransportError.lineTooLong(cap: Self.maxLineBytes)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func poll(url: URL) async throws -> [String] {
        let (bytes, response) = try await session.bytes(for: request(url, timeout: pollTimeout))
        guard let http = response as? HTTPURLResponse else {
            throw RemoteInboxTransportError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteInboxTransportError.rejected(status: http.statusCode)
        }
        var lines: [String] = []
        var buffer = [UInt8]()
        var total = 0
        for try await byte in bytes {
            total += 1
            if total > Self.maxPollBytes {
                throw RemoteInboxTransportError.lineTooLong(cap: Self.maxPollBytes)
            }
            if byte == UInt8(ascii: "\n") {
                if !buffer.isEmpty { lines.append(String(decoding: buffer, as: UTF8.self)) }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            buffer.append(byte)
            if buffer.count > Self.maxLineBytes {
                throw RemoteInboxTransportError.lineTooLong(cap: Self.maxLineBytes)
            }
        }
        if !buffer.isEmpty { lines.append(String(decoding: buffer, as: UTF8.self)) }
        return lines
    }
}

/// Transport-level failures. Deliberately carries no URL: the topic rides in
/// the path and these values reach the trace log.
public enum RemoteInboxTransportError: Error, Sendable, Equatable {
    case notHTTP
    case rejected(status: Int)
    case lineTooLong(cap: Int)
}

/// Owns the connection lifecycle and hands decoded messages to a handler.
/// One instance per app; `start()` is idempotent and `stop()` tears the loop
/// down.
public final class RemoteInboxSubscriber: @unchecked Sendable {

    /// Backoff ladder between reconnects, in seconds. Bounded, and bounded
    /// LOW at the top: this is a channel the owner is waiting on, so a
    /// five-minute backoff after a wifi blip would mean a reply that
    /// silently does nothing for five minutes.
    static let backoffLadder: [TimeInterval] = [1, 2, 5, 10, 20, 30]

    /// Consecutive stream failures before the loop polls as well.
    static let pollFallbackThreshold = 3

    /// Poll cadence once streaming is considered unreliable.
    static let pollInterval: TimeInterval = 30

    /// Retry cadence once the endpoint has REFUSED us. Minutes, not
    /// seconds: nothing about a 403 changes between two attempts thirty
    /// seconds apart, and the owner has already been told. Low enough that
    /// a fixed endpoint recovers on its own within a few minutes.
    static let deniedPause: TimeInterval = 300

    /// The statuses that mean "this will not work until something changes",
    /// as opposed to a 500 or a dropped socket, which are worth retrying at
    /// speed. 401 and 403 are the endpoint asking for credentials the app
    /// does not have; 404 is a topic that is not there.
    static let deniedStatuses: Set<Int> = [401, 403, 404]

    /// nil for anything that is not an outright refusal.
    static func deniedStatus(for error: Error) -> Int? {
        guard
            let transportError = error as? RemoteInboxTransportError,
            case .rejected(let status) = transportError,
            deniedStatuses.contains(status)
        else { return nil }
        return status
    }

    /// How far back the first poll of a run reaches. A bounded window, not
    /// `all`: a code expires in an hour and the gate refuses replays by id,
    /// so a longer backlog can only produce work that is thrown away.
    static let initialPollWindow = "10m"

    /// What the panel renders about the INBOUND half. Separate from
    /// `RemoteNotifier.DeliveryHealth`, which is about pages going out: a
    /// channel can be delivering pages perfectly and reading no replies at
    /// all, and one line covering both would have to guess which it meant.
    public struct InboxHealth: Sendable, Equatable {
        /// Both gates passed, so the loop is genuinely running.
        public var armed: Bool
        /// Length of the current unbroken failure run.
        public var consecutiveFailures: Int
        /// The status the endpoint refused us with, when it did. Non-nil
        /// means replies are not arriving and will not start arriving until
        /// the owner changes something.
        public var deniedStatus: Int?

        public init(armed: Bool = false, consecutiveFailures: Int = 0, deniedStatus: Int? = nil) {
            self.armed = armed
            self.consecutiveFailures = consecutiveFailures
            self.deniedStatus = deniedStatus
        }
    }

    private let transport: any RemoteInboxTransport
    private let trace: TraceLog
    private let handler: @Sendable (RemoteInboxMessage) async -> Void
    private let sleeper: @Sendable (TimeInterval) async -> Void
    /// Called ONCE per denial episode, with the refusing status. The
    /// production wiring is a webhook POST on the OUTBOUND half, which still
    /// works: the two halves fail independently, which is exactly why the
    /// owner can be told at all.
    private let onDenied: @Sendable (Int) async -> Void

    private let lock = NSLock()
    private var enabled: Bool
    private var endpoint: RemoteReplyEndpoint?
    private var task: Task<Void, Never>?
    /// ntfy id of the last message seen, so a poll asks for what came after
    /// it rather than re-delivering the backlog on every reconnect.
    private var sinceCursor: String?
    /// Length of the current unbroken failure run, for the poll fallback and
    /// for an honest health line.
    private var consecutiveFailures = 0
    /// The status behind an outright refusal, while it lasts. Cleared by the
    /// first successful read, and by a config or endpoint change, because
    /// both mean the thing that was refused is not the thing being tried.
    private var deniedStatus: Int?
    /// One page per episode. Latched here rather than left to the notifier's
    /// dedupe window, for the same reason the lockout page carries a zero
    /// window: the system dedupe key is the KIND alone, so a window there
    /// would swallow the NEXT outage rather than a repeat of this one.
    private var deniedPaged = false

    public init(
        endpoint: RemoteReplyEndpoint?,
        enabled: Bool,
        transport: any RemoteInboxTransport = URLSessionRemoteInboxTransport(),
        trace: TraceLog = .shared,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        onDenied: @escaping @Sendable (Int) async -> Void = { _ in },
        handler: @escaping @Sendable (RemoteInboxMessage) async -> Void
    ) {
        self.endpoint = endpoint
        self.enabled = enabled
        self.transport = transport
        self.trace = trace
        self.sleeper = sleeper
        self.onDenied = onDenied
        self.handler = handler
    }

    /// Both gates in one place, so "why is the reply path inert" has one
    /// answer and the panel, the trace and the loop all read the same one.
    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && endpoint != nil
    }

    /// The inbound half's health, read at render time by the panel. A
    /// snapshot, so nothing holds a lock to draw a line.
    public var inboxHealth: InboxHealth {
        lock.lock(); defer { lock.unlock() }
        return InboxHealth(
            armed: enabled && endpoint != nil,
            consecutiveFailures: consecutiveFailures,
            deniedStatus: deniedStatus
        )
    }

    /// Why the loop is inert, in the vocabulary the panel and the trace
    /// share. Never names the topic.
    public var gateReason: String {
        lock.lock(); defer { lock.unlock() }
        if !enabled { return "disabled" }
        if endpoint == nil { return "no_endpoint" }
        return "armed"
    }

    /// Late arrival: the owner stored a webhook or flipped the switch while
    /// the app was already running. Restarts the loop so the change is live
    /// with no relaunch, matching `RemoteNotifier.apply(endpoint:)`.
    public func apply(endpoint new: RemoteReplyEndpoint?, enabled newEnabled: Bool) {
        lock.lock()
        let changed = endpoint != new || enabled != newEnabled
        endpoint = new
        enabled = newEnabled
        if changed {
            // A new endpoint (or a switch flip) is not the thing that was
            // refused, so it gets a clean slate: the bottom rung of the
            // backoff ladder, and one page of its own if it is also
            // refused. Carrying the latch over would silence the page for
            // the endpoint the owner just fixed it with.
            consecutiveFailures = 0
            deniedStatus = nil
            deniedPaged = false
        }
        lock.unlock()
        guard changed else { return }
        trace.emit(
            "remote",
            "remote.inbox_changed enabled=\(newEnabled) endpoint=\(new == nil ? "none" : "set") host=\(new?.loggableHost ?? "-")"
        )
        stop()
        start()
    }

    /// Start the read loop if both gates pass. Idempotent: an already
    /// running loop is left alone rather than doubled, because two
    /// subscribers on one topic would deliver every reply twice.
    public func start() {
        lock.lock()
        let armed = enabled && endpoint != nil
        let alreadyRunning = task != nil
        lock.unlock()
        guard armed else {
            trace.emit("remote", "remote.inbox_idle reason=\(gateReason)")
            return
        }
        guard !alreadyRunning else { return }
        let loop = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
        lock.lock()
        // Re-check under the lock: a concurrent start could have installed a
        // loop between the check above and here, and two loops on one topic
        // means every reply is delivered twice.
        if task == nil {
            task = loop
            lock.unlock()
        } else {
            lock.unlock()
            loop.cancel()
        }
    }

    public func stop() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    // MARK: - The loop

    /// One locked read of everything the loop needs for a pass. A struct
    /// rather than four accessors so the four values are consistent with
    /// each other, and a synchronous function so the lock is never held
    /// across a suspension point.
    private struct LoopState {
        let armed: Bool
        let endpoint: RemoteReplyEndpoint?
        let failures: Int
        let cursor: String?
    }

    private func loopState() -> LoopState {
        lock.lock(); defer { lock.unlock() }
        return LoopState(armed: enabled, endpoint: endpoint, failures: consecutiveFailures, cursor: sinceCursor)
    }

    private func resetFailures() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        // A read that worked is the only thing that clears a denial, and it
        // re-arms the page: if the endpoint is refused again later that is a
        // new episode and the owner hears about it.
        deniedStatus = nil
        deniedPaged = false
    }

    /// Charge one failure and say whether THIS one is the page. `deniedNow`
    /// is the refusing status when the endpoint turned us away outright, nil
    /// for an ordinary failure.
    ///
    /// An ordinary failure does not clear a standing denial: a 403 followed
    /// by a timeout is still a channel that will not read. Only a successful
    /// read clears it, in `resetFailures`.
    private func recordFailure(deniedNow: Int?) -> (count: Int, page: Bool) {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        guard let deniedNow else { return (consecutiveFailures, false) }
        let page = !deniedPaged
        deniedStatus = deniedNow
        deniedPaged = true
        return (consecutiveFailures, page)
    }

    /// How long to wait before the next attempt, read under the lock so the
    /// ladder index and the degraded flag agree with each other.
    private func nextPause() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        // A refusal outranks the ladder. Nothing about a 403 changes between
        // two attempts thirty seconds apart, and hammering an endpoint that
        // is telling us to go away is the wrong thing to do to somebody
        // else's server as well as a waste of this one's wakeups.
        if deniedStatus != nil { return Self.deniedPause }
        if consecutiveFailures >= Self.pollFallbackThreshold { return Self.pollInterval }
        let index = min(max(0, consecutiveFailures - 1), Self.backoffLadder.count - 1)
        return Self.backoffLadder[index]
    }

    private func advanceCursor(to id: String) {
        lock.lock(); defer { lock.unlock() }
        sinceCursor = id
    }

    private func run() async {
        trace.emit("remote", "remote.inbox_started host=\(loopState().endpoint?.loggableHost ?? "?")")

        while !Task.isCancelled {
            let state = loopState()
            let armed = state.armed
            let failures = state.failures
            let cursor = state.cursor

            guard armed, let current = state.endpoint else {
                trace.emit("remote", "remote.inbox_stopped reason=\(gateReason)")
                return
            }

            // Degraded mode: streaming has failed repeatedly, so take one
            // poll pass BEFORE trying the stream again. The poll is what
            // keeps replies flowing while the stream keeps failing; the
            // stream attempt after it is what gets us back to normal.
            if failures >= Self.pollFallbackThreshold {
                await pollOnce(endpoint: current, since: cursor ?? Self.initialPollWindow)
            }

            do {
                try await readStream(endpoint: current)
                // A clean finish is a server-side close, which ntfy does
                // routinely. Not a failure: reconnect at the bottom rung.
                resetFailures()
                trace.emit("remote", "remote.inbox_stream_closed host=\(current.loggableHost)")
            } catch is CancellationError {
                return
            } catch {
                let denied = Self.deniedStatus(for: error)
                let (count, page) = recordFailure(deniedNow: denied)
                trace.emit(
                    "remote",
                    "remote.inbox_stream_error host=\(current.loggableHost) failures=\(count) error=\(Self.traceSafeMessage(for: error))"
                )
                if page, let denied {
                    trace.emit(
                        "remote",
                        "remote.inbox_denied status=\(denied) host=\(current.loggableHost) - replies are not arriving until this endpoint changes"
                    )
                    // Paged from inside this task, like the gate's lockout,
                    // and for the same reason: the outbound half is a
                    // separate connection and still works, so the owner
                    // learns that the half they are relying on has stopped.
                    await onDenied(denied)
                }
            }

            guard !Task.isCancelled else { return }
            await sleeper(nextPause())
        }
    }

    private func readStream(endpoint: RemoteReplyEndpoint) async throws {
        for try await line in transport.stream(url: endpoint.streamURL()) {
            if Task.isCancelled { throw CancellationError() }
            // A line that arrives at all proves the connection works, so the
            // failure run resets here rather than only at stream end: a
            // stream that delivers for an hour and then drops must reconnect
            // at the bottom rung, not at the top of an hour-old ladder.
            resetFailures()
            await ingest(line)
        }
    }

    private func pollOnce(endpoint: RemoteReplyEndpoint, since: String) async {
        do {
            let lines = try await transport.poll(url: endpoint.pollURL(since: since))
            trace.emit("remote", "remote.inbox_polled host=\(endpoint.loggableHost) lines=\(lines.count)")
            for line in lines {
                if Task.isCancelled { return }
                await ingest(line)
            }
        } catch {
            trace.emit(
                "remote",
                "remote.inbox_poll_error host=\(endpoint.loggableHost) error=\(Self.traceSafeMessage(for: error))"
            )
        }
    }

    /// Decode one line and, when it carries owner text, hand it on. The
    /// cursor advances for EVERY decodable object including keepalives, so a
    /// poll after a long quiet period does not replay the backlog.
    ///
    /// The body is never traced here. It is text of unknown content arriving
    /// over a channel a stranger may hold, and the gate downstream is what
    /// decides whether any of it is safe to say out loud.
    func ingest(_ line: String) async {
        guard let decoded = RemoteInboxMessage.decode(line: line) else { return }
        advanceCursor(to: decoded.id)
        guard decoded.isMessage else { return }
        await handler(decoded)
    }

    /// Same rule as `RemoteNotifier.traceSafeMessage`: a URLError becomes its
    /// numeric code and nothing else, because its userInfo carries the full
    /// failing URL and the topic is in that URL's path.
    static func traceSafeMessage(for error: Error) -> String {
        switch error {
        case let e as RemoteInboxTransportError:
            switch e {
            case .notHTTP:               return "non-HTTP response"
            case .rejected(let status):  return "http_\(status)"
            case .lineTooLong(let cap):  return "line_too_long_cap_\(cap)"
            }
        case let e as URLError:
            return "URLError \(e.code.rawValue)"
        default:
            return String(describing: type(of: error))
        }
    }
}
