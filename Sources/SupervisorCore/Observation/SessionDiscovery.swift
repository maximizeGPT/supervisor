// SessionDiscovery.swift
//
// Enumerates Claude Code session JSONL files under
//   ~/.claude/projects/<projectHash>/<sessionId>.jsonl
// and spawns a SessionTail per file. Watches the projects directory for
// new project-hash directories AND each project-hash directory for new
// JSONL files.
//
// v0.1.0 watches every project we can see — we don't filter to a
// specific cwd. my machine has a single project (-Users-main),
// so the simple "all projects, all sessions" approach is fine. Multi-
// project filtering is a v0.1.2 setting.

import Foundation

public final class SessionDiscovery: @unchecked Sendable {

    public struct DiscoveredSession: Sendable {
        public let sessionId: String
        public let projectHash: String
        public let path: URL
    }

    private let claudeProjectsDir: URL
    private let bus: EventBus
    private let sessionStore: SessionStore?
    private let trace: TraceLog
    private let queue = DispatchQueue(label: "supervisor.discovery", qos: .utility)

    /// Active tails by sessionId.
    private var tails: [String: SessionTail] = [:]

    /// File descriptors for directory-watch sources.
    private var projectsDirSource: DispatchSourceFileSystemObject?
    private var projectsDirFD: Int32 = -1
    private var projectHashDirSources: [String: DispatchSourceFileSystemObject] = [:]
    private var projectHashDirFDs: [String: Int32] = [:]

    /// Belt-and-suspenders timer that re-scans on a slow interval even if
    /// kqueue misses an event (some macOS combinations don't fire NOTE_WRITE
    /// reliably on every directory mutation). Cheap; runs every few seconds.
    private var rescanTimer: DispatchSourceTimer?
    private let rescanInterval: TimeInterval

    public init(
        claudeProjectsDir: URL,
        bus: EventBus,
        sessionStore: SessionStore?,
        rescanInterval: TimeInterval = 3.0,
        trace: TraceLog = .shared
    ) {
        self.claudeProjectsDir = claudeProjectsDir
        self.bus = bus
        self.sessionStore = sessionStore
        self.rescanInterval = rescanInterval
        self.trace = trace
    }

    /// Start discovery: scan once, then watch for new sessions.
    ///
    /// Synchronous on purpose. Callers — and tests — need to be able to
    /// assume the watcher is live by the time `start()` returns; otherwise
    /// a session file created in the next instruction can be missed. The
    /// guard for "what if the directory grows between scan and watch":
    /// the watch handler runs `scanProjectHashDir` on every fire, so any
    /// file that landed between scan and watch install is picked up on
    /// the first event.
    public func start() {
        queue.sync {
            self.scanProjectsDir()
            self.watchProjectsDir()
            self.startRescanTimer()
        }
    }

    /// Force a rescan now. Lets the test deterministically verify that
    /// a newly-created session file is picked up, without relying on
    /// kqueue arming latency.
    public func probeNow() {
        queue.sync {
            self.scanProjectsDir()
        }
    }

    private func startRescanTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
        t.setEventHandler { [weak self] in self?.scanProjectsDir() }
        t.resume()
        self.rescanTimer = t
    }

    public func stop() {
        queue.sync {
            rescanTimer?.cancel()
            rescanTimer = nil

            // Tail teardown: each tail's stop() persists final offset.
            for (_, tail) in tails { tail.stop() }
            tails.removeAll()

            for (_, src) in projectHashDirSources { src.cancel() }
            projectHashDirSources.removeAll()
            for (_, fd) in projectHashDirFDs { if fd >= 0 { close(fd) } }
            projectHashDirFDs.removeAll()

            projectsDirSource?.cancel()
            projectsDirSource = nil
            if projectsDirFD >= 0 { close(projectsDirFD); projectsDirFD = -1 }
        }
    }

    public func activeSessions() -> [String] {
        queue.sync { Array(tails.keys) }
    }

    // MARK: - Discovery

    /// Iterate every project-hash directory and every JSONL inside it,
    /// adding a tail for any session we don't already know about. Idempotent.
    private func scanProjectsDir() {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            trace.emit("discovery", "no projects dir at \(claudeProjectsDir.path) — supervisor will idle until it exists")
            return
        }
        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            scanProjectHashDir(dir)
            watchProjectHashDir(dir)
        }
    }

    private func scanProjectHashDir(_ dir: URL) {
        let projectHash = dir.lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for entry in entries where entry.pathExtension == "jsonl" {
            let sessionId = entry.deletingPathExtension().lastPathComponent
            if tails[sessionId] != nil { continue }
            startTail(sessionId: sessionId, projectHash: projectHash, path: entry)
        }
    }

    private func startTail(sessionId: String, projectHash: String, path: URL) {
        let savedOffset = (try? sessionStore?.fetch(id: sessionId)?.jsonlOffset) ?? 0
        let tail = SessionTail(
            sessionId: sessionId,
            path: path,
            projectHash: projectHash,
            bus: bus,
            sessionStore: sessionStore,
            startOffset: savedOffset,
            trace: trace
        )
        do {
            try tail.start()
            tails[sessionId] = tail
            // Seed lastSeenAt from the JSONL's modification time, NOT Date().
            // startTail runs for EVERY historical session on the startup scan;
            // seeding `now` made all of them look "active," spiking
            // activeSessionCount to ~37 for the first 10 min after a relaunch
            // and over-tripping the multi-session inject gate. The file mtime is
            // the real last-activity proxy; SessionTail bumps it to now as live
            // events stream, so genuinely-active sessions stay current.
            let lastActivity = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date) ?? Date()
            try sessionStore?.upsert(StoredSession(
                id: sessionId,
                projectHash: projectHash,
                cwd: "<resolving>",       // EventParser will surface the real cwd from sessionStart
                startedAt: Date(),
                lastSeenAt: lastActivity,
                jsonlPath: path.path,
                jsonlOffset: savedOffset
            ))
            trace.emit("discovery", "tailing session=\(sessionId) project=\(projectHash) savedOffset=\(savedOffset)")
        } catch {
            trace.emit("discovery", "ERROR could not tail session=\(sessionId): \(error)")
        }
    }

    // MARK: - Directory watching

    private func watchProjectsDir() {
        let fd = open(claudeProjectsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            trace.emit("discovery", "couldn't watch projects dir: \(String(cString: strerror(errno)))")
            return
        }
        projectsDirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scanProjectsDir()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.projectsDirFD, fd >= 0 { close(fd) }
            self?.projectsDirFD = -1
        }
        src.resume()
        projectsDirSource = src
    }

    private func watchProjectHashDir(_ dir: URL) {
        let key = dir.lastPathComponent
        if projectHashDirSources[key] != nil { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            trace.emit("discovery", "couldn't watch project dir \(key): \(String(cString: strerror(errno)))")
            return
        }
        projectHashDirFDs[key] = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scanProjectHashDir(dir)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.projectHashDirFDs[key], fd >= 0 { close(fd) }
            self?.projectHashDirFDs[key] = nil
        }
        src.resume()
        projectHashDirSources[key] = src
    }
}
