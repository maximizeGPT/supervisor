// CodexSessionDiscovery.swift
//
// The Codex analog of SessionDiscovery. Watches ~/.codex/sessions (a
// YYYY/MM/DD date tree) and spawns a SessionTail per rollout file, INJECTING a
// CodexRolloutParser so the SAME hardened tail (byte offsets, backfill /
// fast-forward, inactivity close, offset persistence) drives Codex transcripts.
// Events land on the SAME EventBus the TriageEngine already subscribes to — a
// Codex session is triaged by the identical rubric with no downstream change.
//
// This is a SEPARATE watcher rather than a refactor of SessionDiscovery: the
// two agents' on-disk layouts differ (project-hash tree vs date tree) and
// SessionDiscovery is being edited by concurrent branches, so keeping Codex
// discovery additive avoids both runtime risk to Claude Code and merge risk.
// The tail logic — the hard part — is reused, not duplicated.
//
// Discovery strategy: a recursive enumerate of the date tree on a slow rescan
// timer (the tree grows a new YYYY/MM/DD dir each day; a timer re-scan adopts
// it without per-dir kqueue bookkeeping), plus a kqueue watch on the sessions
// root for promptness. Same recency filter as SessionDiscovery so a heavy user's
// backlog of historical rollouts is not all tailed at once.

import Foundation

public final class CodexSessionDiscovery: @unchecked Sendable {

    private let sessionsDir: URL
    private let source: CodexRolloutSource
    private let bus: EventBus
    private let sessionStore: SessionStore?
    private let trace: TraceLog
    private let queue = DispatchQueue(label: "supervisor.codex.discovery", qos: .utility)

    /// Active tails by sessionId.
    private var tails: [String: SessionTail] = [:]

    private var rootSource: DispatchSourceFileSystemObject?
    private var rootFD: Int32 = -1
    private var rescanTimer: DispatchSourceTimer?
    private let rescanInterval: TimeInterval

    /// Only adopt a rollout whose mtime is within this window at scan time (same
    /// rationale as SessionDiscovery: don't hold an fd + tail open for every
    /// historical transcript). Re-evaluated each scan, so a resumed session
    /// (mtime bumps) is adopted later.
    static let defaultDiscoveryRecencyWindowSeconds: TimeInterval = 172_800  // 48h
    private let discoveryRecencyWindow: TimeInterval
    private let tailInactivityTimeout: TimeInterval?
    private let tailOffsetPersistInterval: TimeInterval

    public init(
        codexSessionsDir: URL,
        source: CodexRolloutSource = CodexRolloutSource(),
        bus: EventBus,
        sessionStore: SessionStore?,
        rescanInterval: TimeInterval = 3.0,
        discoveryRecencyWindow: TimeInterval? = nil,
        tailInactivityTimeout: TimeInterval? = nil,
        tailOffsetPersistInterval: TimeInterval = 30,
        trace: TraceLog = .shared
    ) {
        self.sessionsDir = codexSessionsDir
        self.source = source
        self.bus = bus
        self.sessionStore = sessionStore
        self.rescanInterval = rescanInterval
        self.discoveryRecencyWindow = discoveryRecencyWindow ?? CodexSessionDiscovery.defaultDiscoveryRecencyWindowSeconds
        self.tailInactivityTimeout = tailInactivityTimeout
        self.tailOffsetPersistInterval = tailOffsetPersistInterval
        self.trace = trace
    }

    /// Start discovery: scan once, then watch + rescan on a timer. Synchronous
    /// so callers/tests can assume the watcher is live on return.
    public func start() {
        queue.sync {
            self.scan()
            self.watchRoot()
            self.startRescanTimer()
        }
    }

    /// Force a rescan now (tests).
    public func probeNow() { queue.sync { self.scan() } }

    public func stop() {
        queue.sync {
            rescanTimer?.cancel(); rescanTimer = nil
            for (_, tail) in tails { tail.stop() }
            tails.removeAll()
            rootSource?.cancel(); rootSource = nil
            if rootFD >= 0 { close(rootFD); rootFD = -1 }
        }
    }

    public func activeSessions() -> [String] { queue.sync { Array(tails.keys) } }

    // MARK: - Discovery

    private func startRescanTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        self.rescanTimer = t
    }

    /// Recursively enumerate the date tree, adopting any not-yet-tailed rollout
    /// within the recency window. Idempotent.
    private func scan() {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            trace.emit("codex.discovery", "no sessions dir at \(sessionsDir.path) — idle until it exists")
            return
        }
        for case let url as URL in en where source.isTranscript(url) {
            let sessionId = source.sessionId(for: url)
            if tails[sessionId] != nil { continue }
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                let age = Date().timeIntervalSince(mtime)
                if age > discoveryRecencyWindow {
                    continue  // stale historical rollout — adopt later if written to
                }
            }
            startTail(sessionId: sessionId, path: url)
        }
    }

    private func startTail(sessionId: String, path: URL) {
        let savedOffset = (try? sessionStore?.fetch(id: sessionId)?.jsonlOffset) ?? 0
        let parser = source.makeParser(sessionId: sessionId, path: path)
        let projectHash = source.projectNamespace(for: path)
        let tail = SessionTail(
            sessionId: sessionId,
            path: path,
            projectHash: projectHash,
            bus: bus,
            sessionStore: sessionStore,
            parser: parser,
            startOffset: savedOffset,
            offsetPersistInterval: tailOffsetPersistInterval,
            inactivityTimeout: tailInactivityTimeout,
            trace: trace
        )
        // Prune the entry when the tail self-terminates so the fd is freed and a
        // resumed session can be re-adopted. Identity-guarded so a recreated
        // same-id file's newer tail is never removed by an older tail's callback.
        let tailIdentity = ObjectIdentifier(tail)
        tail.onTerminated = { [weak self] sid in
            self?.queue.async {
                guard let self else { return }
                if let current = self.tails[sid], ObjectIdentifier(current) == tailIdentity {
                    self.tails.removeValue(forKey: sid)
                }
            }
        }
        do {
            try tail.start()
            tails[sessionId] = tail
            let lastActivity = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date) ?? Date()
            try sessionStore?.upsert(StoredSession(
                id: sessionId,
                projectHash: projectHash,
                cwd: "<resolving>",       // CodexRolloutParser surfaces the real cwd from session_meta
                startedAt: Date(),
                lastSeenAt: lastActivity,
                jsonlPath: path.path,
                jsonlOffset: savedOffset
            ))
            trace.emit("codex.discovery", "tailing codex session=\(sessionId) savedOffset=\(savedOffset) path=\(path.lastPathComponent)")
        } catch {
            trace.emit("codex.discovery", "ERROR could not tail codex session=\(sessionId): \(error)")
        }
    }

    // MARK: - Root watch

    private func watchRoot() {
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            trace.emit("codex.discovery", "couldn't watch sessions dir: \(String(cString: strerror(errno)))")
            return
        }
        rootFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.rootFD, fd >= 0 { close(fd) }
            self?.rootFD = -1
        }
        src.resume()
        rootSource = src
    }
}
