// SessionTail.swift
//
// kqueue-backed tail of a single Claude Code session JSONL.
//
// Lifecycle:
//   1. Open file at saved offset (from SessionStore.jsonlOffset) or EOF.
//   2. Register DispatchSourceFileSystemObject(.write|.extend|.delete|.rename)
//      on the fd. Handler reads to EOF, buffers partial lines, parses
//      complete lines via EventParser, publishes to EventBus.
//   3. Persist offset to SessionStore every 30s.
//   4. On stop: cancel sources, close fd, flush offset.
//
// Spike 1 confirmed kqueue reliability — see spikes/kqueue-spike-README.md.
// One implementation note from that spike: events COALESCE. Two writes in
// the same kqueue notification window arrive as ONE event with possibly
// zero source.data. We always read-to-EOF; if there's nothing new, the
// read returns 0 and we move on. Buffer-and-wait is the right pattern.

import Foundation

public final class SessionTail: @unchecked Sendable {

    public let sessionId: String

    private let path: URL
    private let parser: EventParser
    private let bus: EventBus
    private let sessionStore: SessionStore?
    private let trace: TraceLog
    private let offsetPersistInterval: TimeInterval

    /// Set once the real cwd has been persisted to the session record, so we
    /// only write the UPDATE once per tail (the placeholder -> real transition).
    private var persistedResolvedCwd = false

    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offsetTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var lastPersistedOffset: Int64 = 0
    private var currentOffset: Int64 = 0

    public init(
        sessionId: String,
        path: URL,
        projectHash: String,
        bus: EventBus,
        sessionStore: SessionStore?,
        startOffset: Int64? = nil,
        offsetPersistInterval: TimeInterval = 30,
        trace: TraceLog = .shared
    ) {
        self.sessionId = sessionId
        self.path = path
        self.parser = EventParser(projectHash: projectHash, jsonlPath: path.path)
        self.bus = bus
        self.sessionStore = sessionStore
        self.offsetPersistInterval = offsetPersistInterval
        self.trace = trace
        self.queue = DispatchQueue(label: "supervisor.tail.\(sessionId)", qos: .utility)
        self.lastPersistedOffset = startOffset ?? 0
        self.currentOffset = startOffset ?? 0
    }

    // MARK: - Start / stop

    /// Begin tailing. Synchronous; the handler dispatches on its own queue.
    /// Throws on open/lseek failure.
    public func start() throws {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        self.fd = fd

        // Seek policy:
        //   - savedOffset == 0 (we've never observed this session): read
        //     from byte 0. This means the first events of the session —
        //     sessionStart, the user's opening prompt — flow through the
        //     pipeline so Triage has context. Cost: if Supervisor is
        //     installed mid-session over an existing large JSONL, the
        //     whole history replays through Haiku once. Acceptable for
        //     v0.1.0; v0.1.1 adds a mtime heuristic that skips backfill
        //     on multi-MB pre-existing files.
        //   - savedOffset > 0 and <= EOF: resume from saved.
        //   - savedOffset > EOF (file truncated/rotated since last run):
        //     reset to byte 0 — the saved offset is stale.
        let endOff = lseek(fd, 0, SEEK_END)
        let resumeOff: off_t
        if lastPersistedOffset > 0 && lastPersistedOffset <= endOff {
            resumeOff = lseek(fd, off_t(lastPersistedOffset), SEEK_SET)
        } else {
            resumeOff = lseek(fd, 0, SEEK_SET)
        }
        currentOffset = Int64(resumeOff)
        lastPersistedOffset = currentOffset
        trace.emit("tail", "start session=\(sessionId) path=\(path.path) resumeOffset=\(currentOffset)")

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent(mask: src.data)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        self.source = src

        // Drain whatever's already past the resume offset (catch-up after a
        // crash or after Supervisor was killed for a while). The first
        // event handler call would also do this, but kqueue won't fire if
        // the file isn't being actively written; explicit drain ensures we
        // don't sit on stale content forever.
        queue.async { [weak self] in
            self?.handleEvent(mask: [])
        }

        // Periodic offset persistence.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + offsetPersistInterval, repeating: offsetPersistInterval)
        t.setEventHandler { [weak self] in self?.persistOffsetIfNeeded() }
        t.resume()
        self.offsetTimer = t
    }

    public func stop() {
        queue.sync {
            self.offsetTimer?.cancel()
            self.offsetTimer = nil
            self.source?.cancel()
            self.source = nil
            // Final offset persist on the way out.
        }
        persistOffsetIfNeeded(force: true)
        trace.emit("tail", "stop session=\(sessionId) finalOffset=\(currentOffset)")
    }

    /// Block until any in-flight events have been processed. Test-only.
    public func flush() {
        queue.sync { /* drain */ }
    }

    // MARK: - Event handler

    private func handleEvent(mask: DispatchSource.FileSystemEvent) {
        if mask.contains(.delete) || mask.contains(.rename) {
            trace.emit("tail", "session=\(sessionId) file disappeared (delete/rename) — stopping tail")
            source?.cancel()
            source = nil
            return
        }

        guard fd >= 0 else { return }

        // Drain everything new from the fd into our buffer.
        let chunk = 65_536
        var scratch = Data(count: chunk)
        while true {
            let n = scratch.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, chunk)
            }
            if n <= 0 { break }
            buffer.append(scratch.prefix(n))
            currentOffset += Int64(n)
        }

        // Split on newlines. Lines without a trailing newline stay in the
        // buffer for the next event (kqueue coalesces; we may have read a
        // partial last line).
        while let nlIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nlIndex)
            buffer.removeSubrange(0...nlIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let events = parser.parse(line: line)
            for event in events {
                bus.publish(event)
                // Persist the real cwd to the session record the first time a
                // cwd-bearing event surfaces it, replacing "<resolving>".
                if !persistedResolvedCwd,
                   case .sessionStart(let info) = event,
                   info.cwd != "<resolving>", info.cwd != "<unknown>", !info.cwd.isEmpty {
                    try? sessionStore?.updateResolvedCwd(sessionId: sessionId, cwd: info.cwd)
                    persistedResolvedCwd = true
                    trace.emit("tail", "session=\(sessionId) resolved cwd=\(info.cwd) branch=\(info.gitBranch ?? "?")")
                }
            }
        }
    }

    // MARK: - Offset persistence

    private func persistOffsetIfNeeded(force: Bool = false) {
        let current = currentOffset
        let last = lastPersistedOffset
        guard force || current != last else { return }
        do {
            try sessionStore?.updateOffset(sessionId: sessionId, offset: current)
            lastPersistedOffset = current
            trace.emit("tail", "session=\(sessionId) persisted offset=\(current)")
        } catch {
            trace.emit("tail", "session=\(sessionId) offset persist failed: \(error)")
        }
    }
}
