// FakeNtfyServer.swift
//
// A real HTTP server, on a real socket, bound to 127.0.0.1 on a port the
// kernel picks. It exists so RemoteInboxSubscriber can be driven over the
// REAL URLSession path instead of a scripted transport stub.
//
// WHY THIS EXISTS AT ALL. RemoteInboxSubscriberTests covers the loop
// against a stub that never opens a connection, which is the right shape
// for testing the ladder and the gates. What no stub can cover is the half
// of `URLSessionRemoteInboxTransport` that only runs against a socket: that
// a response with no Content-Length streams line by line rather than
// arriving in one lump at the end, that a non-2xx surfaces as
// `.rejected(status:)` rather than as an empty stream, that a server-side
// FIN ends the stream cleanly, and that a poll's query string is built the
// way ntfy reads it. That is the gap this closes.
//
// Rules this file holds itself to:
//
//   127.0.0.1 only, port 0. It binds the loopback interface and lets the
//   kernel choose the port, so two of these can run at once and neither
//   can be reached from another machine.
//
//   No wall clock. Nothing here sleeps and nothing here is scheduled. The
//   server responds when it is asked; the tests wait on expectations that
//   the server and the subscriber fulfil.
//
//   Teardown is unconditional. `stop()` cancels the listener AND every
//   connection it ever accepted, and the tests call it from `defer` and
//   from `tearDown`, so a failing assertion cannot leave a listening
//   socket or a parked connection behind for the rest of the suite.

import Foundation
import Network
import XCTest

final class FakeNtfyServer: @unchecked Sendable {

    /// What the server does with the NEXT request for the stream endpoint.
    /// A queue, so one test can drive several reconnects in a row.
    enum StreamEpisode {
        /// 200 with no Content-Length, these lines, then a clean FIN. This
        /// is the shape of a real ntfy stream that the server closed.
        case lines([String])
        /// A non-2xx answer. 404 is a topic that is gone; 500 is a blip.
        case status(Int)
        /// 200 and headers, then nothing, forever. A healthy quiet
        /// channel, and the state the loop should come to rest in rather
        /// than spinning.
        case hang
    }

    /// One request the server was asked to serve, for assertions about
    /// what the subscriber actually put on the wire.
    struct Request: Equatable {
        let method: String
        let path: String
        let query: [String: String]
    }

    private let queue = DispatchQueue(label: "fake-ntfy-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var episodes: [StreamEpisode] = []
    /// What every stream request past the script gets. `hang` by default,
    /// so a loop that keeps reconnecting comes to rest instead of hammering
    /// this server for the rest of the test.
    private var streamFallback: StreamEpisode = .hang
    /// Lines every poll returns. The re-delivery case sets this to the
    /// SAME message the stream already delivered.
    private var pollLines: [String] = []
    /// Status every poll answers with, when it is not 200.
    private var pollStatus = 200
    private var _requests: [Request] = []
    private var onRequest: (@Sendable (Request) -> Void)?
    private var ready = DispatchSemaphore(value: 0)
    private var boundPort: UInt16?

    // MARK: - Script

    func scriptStream(_ episodes: [StreamEpisode], fallback: StreamEpisode = .hang) {
        lock.lock(); self.episodes = episodes; self.streamFallback = fallback; lock.unlock()
    }

    func scriptPoll(lines: [String], status: Int = 200) {
        lock.lock(); self.pollLines = lines; self.pollStatus = status; lock.unlock()
    }

    /// Called on the server's own queue for every request served. Used to
    /// fulfil an expectation the moment a poll arrives, so no test has to
    /// guess how long a reconnect takes.
    func observeRequests(_ handler: @escaping @Sendable (Request) -> Void) {
        lock.lock(); self.onRequest = handler; lock.unlock()
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    // MARK: - Lifecycle

    /// Bind and start listening. Returns once the kernel has given us a
    /// port, so the caller can build a URL from it.
    ///
    /// The wait is a startup handshake with a generous ceiling, not a
    /// timing assumption: nothing about the test's meaning changes if the
    /// bind takes ten milliseconds or two seconds.
    func start(file: StaticString = #filePath, line: UInt = #line) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback, and port 0 so the kernel picks a free one.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.boundPort = listener.port?.rawValue
                self.lock.unlock()
                self.ready.signal()
            case .failed, .cancelled:
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.readRequest(on: connection, buffer: Data())
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 30) == .success else {
            XCTFail("fake ntfy server never came up", file: file, line: line)
            throw NSError(domain: "FakeNtfyServer", code: 1)
        }
        lock.lock()
        let port = boundPort
        lock.unlock()
        guard port != nil else {
            XCTFail("fake ntfy server bound no port", file: file, line: line)
            throw NSError(domain: "FakeNtfyServer", code: 2)
        }
    }

    /// The base URL an endpoint is built from. http, not https: the topic
    /// derivation this test drives is fed the base and the topic directly,
    /// and TLS on a loopback socket would test OpenSSL rather than the
    /// stream loop.
    var baseURL: URL {
        lock.lock(); let port = boundPort ?? 0; lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Unconditional teardown: the listener stops accepting and every
    /// connection ever handed to us is cancelled, including the ones parked
    /// in a `hang` episode. Safe to call twice.
    func stop() {
        lock.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = []
        self.onRequest = nil
        lock.unlock()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    // MARK: - Serving

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if error != nil || (isComplete && accumulated.isEmpty) {
                connection.cancel()
                return
            }
            // Headers end at the blank line. A GET has no body, so that is
            // the whole request.
            guard let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel(); return }
                self.readRequest(on: connection, buffer: accumulated)
                return
            }
            let head = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
            self.respond(to: head, on: connection)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        guard let requestLine = head.split(separator: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        let request = Request(method: method, path: path, query: query)
        lock.lock()
        _requests.append(request)
        let observer = onRequest
        let isPoll = query["poll"] == "1"
        let episode: StreamEpisode
        if isPoll {
            episode = .lines(pollStatus == 200 ? pollLines : [])
        } else if !episodes.isEmpty {
            episode = episodes.removeFirst()
        } else {
            episode = streamFallback
        }
        let pollFailureStatus = pollStatus
        lock.unlock()
        observer?(request)

        if isPoll, pollFailureStatus != 200 {
            send(status: pollFailureStatus, on: connection)
            return
        }
        switch episode {
        case .lines(let lines):
            sendStream(lines: lines, on: connection, close: true)
        case .status(let status):
            send(status: status, on: connection)
        case .hang:
            // Headers only. The connection is held (and cancelled in
            // `stop()`), which is what a quiet ntfy topic looks like and
            // what stops a no-op sleeper from spinning the reconnect loop.
            sendStream(lines: [], on: connection, close: false)
        }
    }

    /// 200 with no Content-Length, so the body is delimited by the close.
    /// That is exactly how ntfy's `/json` endpoint behaves and it is the
    /// property that makes the transport stream rather than buffer.
    private func sendStream(lines: [String], on connection: NWConnection, close: Bool) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/x-ndjson\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        for line in lines { response += line + "\n" }
        let data = Data(response.utf8)
        if close {
            // `.finalMessage` sends the FIN after the bytes, so the client
            // sees a complete body then a clean EOF. The connection is not
            // cancelled here: cancelling can beat the flush and turn a
            // clean close into a reset.
            connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in })
        } else {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func send(status: Int, on connection: NWConnection) {
        let body = "not a stream\n"
        var response = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        response += "Content-Type: text/plain\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}
