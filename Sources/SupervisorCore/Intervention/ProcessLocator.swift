// ProcessLocator.swift — v0.1.4 Part A2.
//
// Resolves a target session's cwd to the PID of the Claude Code process
// running in that directory. Used by the pause/kill router to know which
// process to signal. Failure paths degrade gracefully via Optional return
// + trace tags; the router maps `nil` to a notify fallback.
//
// Discovery method: sysctl/libproc + cwd match (DESIGN.md §5.3, validated
// against the FakeClaudeCLI harness):
//
//   1. `proc_listallpids` to enumerate every PID the user can see (same UID,
//       no entitlements needed).
//   2. `proc_pidpath` to read each PID's executable path; filter to those
//       whose basename contains any of `execNamePatterns` (default ["claude",
//       "claude-code"]; tests inject "FakeClaudeCLI").
//   3. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` to read each remaining PID's
//       cwd; filter to those where cwd == targetCwd.
//   4. Map result count → outcome:
//        - 0 matches  → nil + log `locator.not_found`
//        - 1 match    → return handle + log `locator.found`
//        - 2+ matches → nil + log `locator.ambiguous`
//
// sysctl/libproc failures (permission denied, syscall errors) → nil + log
// `locator.sysctl_failed`. Supervisor's own PID is filtered out so the
// locator can never accidentally identify Supervisor as the target — that
// matters because Supervisor holds Claude Code's JSONL files open too,
// so a naive lsof-based approach would surface it as a candidate.

import AppKit
import Darwin
import Foundation

public struct ProcessHandle: Sendable, Equatable {
    public let pid: pid_t
    public let execPath: String
    public let cwd: String

    public init(pid: pid_t, execPath: String, cwd: String) {
        self.pid = pid
        self.execPath = execPath
        self.cwd = cwd
    }
}

/// Resolves a target cwd → the unique matching Claude Code PID. Returns nil
/// for any non-happy path (ambiguous / not found / syscall failure). Each
/// outcome emits a discriminating trace tag so the router's notify-fallback
/// path can be traced back to the precise cause.
public protocol ProcessLocator: Sendable {
    func locate(targetCwd: String) -> ProcessHandle?

    /// Same cwd walk, with the v0.3.1 Claude.app desktop fallback gated by
    /// `allowDesktopFallback`. The SIGNAL paths (pause/kill) pass `false`:
    /// the fallback PID is the SHARED desktop Electron process, and a POSIX
    /// SIGSTOP/SIGTERM to it would freeze/quit every conversation in the
    /// app — so a locate destined for `kill(2)` must return nil rather than
    /// that PID. Inject paths keep the fallback (typing into the desktop
    /// app is legitimate — delivery goes through keystrokes, not signals).
    /// Default forwards to `locate(targetCwd:)` so existing conformers
    /// (test stubs) stay source-compatible.
    func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle?

    /// Locate the process for a specific session by its session id (the
    /// transcript UUID), matched against the process argv (`--resume <id>`
    /// / `--session-id <id>`). This is the RELIABLE primitive when cwd
    /// can't pin the session: in practice the `claude` process cwd is the
    /// user's HOME dir, not the session's project dir (verified 2026-06-07),
    /// so cwd-matching alone always degrades. Session ids are globally
    /// unique, so an argv match has effectively zero false-positive risk —
    /// which is what lets the router inject into the right one of several
    /// concurrent sessions instead of safe-degrading. Default nil so the
    /// stub locators in tests opt out without implementing it.
    func locate(bySessionId sessionId: String) -> ProcessHandle?

    /// TOCTOU re-check (Finding 4): confirm `pid` STILL resolves to a
    /// Claude-shaped process, called immediately before a GROUP signal.
    /// Between the `locate…` above and `kill(-pgid)` the pid can be reused by
    /// an unrelated process, and a group signal would then hit a FOREIGN
    /// process group — the `getpgrp()` self-guard in DarwinSignalSender only
    /// protects Supervisor's OWN group, not a stranger's. The router calls
    /// this right before `sendToGroup` and degrades to notify on false.
    /// Default returns true so existing conformers / test stubs stay
    /// source-compatible (they resolve the pid themselves and don't model
    /// reuse).
    func stillClaudeProcess(pid: pid_t) -> Bool
}

public extension ProcessLocator {
    func locate(bySessionId sessionId: String) -> ProcessHandle? { nil }
    func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle? {
        locate(targetCwd: targetCwd)
    }
    func stillClaudeProcess(pid: pid_t) -> Bool { true }
}

/// Production implementation backed by libproc on macOS. No entitlements
/// required for same-user processes.
public final class LiveProcessLocator: ProcessLocator, @unchecked Sendable {

    private let execNamePatterns: [String]
    private let trace: TraceLog
    private let supervisorPID: pid_t

    public init(
        // "codex" added so a Codex CLI session is located + intervened on
        // exactly like a Claude Code one (the router routes purely by cwd, so
        // recognizing the process is the whole parity change). Case-sensitive
        // exact-basename match means Codex.app's GUI binary "Codex" (capital)
        // is NOT matched, and the desktop `codex app-server` backend is
        // additionally guarded out of the signal path (see isCodexServerProcess)
        // so a POSIX signal can never freeze the Codex GUI.
        execNamePatterns: [String] = ["claude", "claude-code", "codex"],
        trace: TraceLog = .shared
    ) {
        self.execNamePatterns = execNamePatterns
        self.trace = trace
        self.supervisorPID = getpid()
    }

    public func locate(targetCwd: String) -> ProcessHandle? {
        locate(targetCwd: targetCwd, allowDesktopFallback: true)
    }

    public func locate(targetCwd: String, allowDesktopFallback: Bool) -> ProcessHandle? {
        let pids: [pid_t]
        do {
            pids = try Self.enumerateAllPIDs()
        } catch {
            trace.emit("locator", "locator.sysctl_failed reason=\(error)")
            return nil
        }

        var matches: [ProcessHandle] = []
        // v0.3.0 Issue #1: track the "cwd-matched but exec-unrecognized"
        // case so a silent-nil here can be diagnosed post-mortem. If a
        // process is in the target cwd and looks like it could be the
        // Claude Code session but is launched as `node` / `bun` / etc.
        // (the interpreter case), we emit a loud trace tag identifying
        // the candidate that got skipped.
        //
        // v0.3.2 Issue #1: KERN_PROCARGS2 argv inspection lifts this
        // from "trace only" to actual recovery — when the exec basename
        // looks like a JS-runtime interpreter, we scan argv for Claude
        // Code markers and promote the candidate to a match if found.
        var unrecognizedInTargetCwd: [(pid: pid_t, exec: String)] = []
        for pid in pids {
            // Never match Supervisor itself — Supervisor holds the JSONL
            // files open and could otherwise look like a candidate to an
            // lsof-based cross-check; the cwd filter alone wouldn't
            // exclude it if Supervisor and Claude Code share a cwd.
            if pid == supervisorPID { continue }
            guard let execPath = Self.execPath(pid: pid) else { continue }
            let nameMatches = matchesExecName(execPath)
            if !nameMatches {
                // The exec name didn't match. Cheap follow-up check:
                // was this process in the target cwd anyway? If so,
                // it's a candidate we'd otherwise silently drop.
                guard let cwd = Self.cwd(pid: pid), cwd == targetCwd else {
                    continue
                }
                // v0.3.2: before deciding the candidate is unrecognized,
                // check if the exec basename is a JS-runtime interpreter
                // AND argv contains a Claude Code marker. If so, accept
                // the match. This covers the `node /usr/local/bin/claude/cli.mjs`
                // shape that the Claude.app fallback doesn't catch.
                let execBase = (execPath as NSString).lastPathComponent
                if Self.interpreterBasenames.contains(execBase),
                   let argv = Self.readProcessArgv(pid: pid),
                   Self.argvContainsClaudeCodeMarker(argv)
                {
                    trace.emit("locator", "locator.found_via_argv pid=\(pid) cwd=\(targetCwd) exec=\(execPath) markers_found_in_argv")
                    matches.append(ProcessHandle(pid: pid, execPath: execPath, cwd: cwd))
                    continue
                }
                // No argv-marker rescue. Surface as unrecognized.
                unrecognizedInTargetCwd.append((pid: pid, exec: execPath))
                continue
            }
            guard let cwd = Self.cwd(pid: pid) else { continue }
            guard cwd == targetCwd else { continue }
            // Never treat the Codex desktop app's own `codex app-server` (or
            // other server-mode) backend as an interactive session to signal —
            // a SIGSTOP/SIGTERM to it would freeze the Codex GUI (the same class
            // of incident that froze Supervisor via Claude.app). The cwd filter
            // already excludes it (its cwd is "/"), but this is belt-and-braces.
            if Self.isCodexServerProcess(execPath: execPath, pid: pid) {
                trace.emit("locator", "locator.codex_server_excluded pid=\(pid) cwd=\(targetCwd) exec=\(execPath) — server-mode codex is not an interactive session target")
                continue
            }
            matches.append(ProcessHandle(pid: pid, execPath: execPath, cwd: cwd))
        }

        // Surface unrecognized-but-cwd-matching candidates. This is
        // the loud-failure trace that turns a silent locator.nil into
        // a diagnosable "the process was there but we didn't recognize
        // it." The router still degrades to notify (the match list is
        // empty), but post-mortem can see what was skipped and why.
        if matches.isEmpty && !unrecognizedInTargetCwd.isEmpty {
            for entry in unrecognizedInTargetCwd {
                trace.emit("locator", "locator.exec_unrecognized pid=\(entry.pid) cwd=\(targetCwd) execPath=\(entry.exec) (note: full path included so post-mortem can identify interpreter+CLI shapes like `node /usr/local/bin/claude/cli.mjs`; see Issue #1)")
            }
        }

        switch matches.count {
        case 0:
            // v0.3.1: Claude.app fallback. The CLI-style locator
            // (exec name + cwd match) misses Claude.app because:
            //   1) Claude.app's binary is `Claude` (capital), not in
            //      the patterns set
            //   2) Claude.app's cwd is `/`, not the session's cwd
            // For users on the Claude desktop app (added to
            // claudeCodeHostApps in v0.1.6.1), inject still needs to
            // resolve to a PID — and Claude.app's PID is the right
            // target because CGEventInjector posts to that app
            // frontmost. Surfaced by v0.3.1 dogfood when the question-
            // pipeline answer hit `intervention.inject.degraded
            // reason=locator_nil` despite cwd resolving correctly.
            if let claudeAppPID = Self.findClaudeDesktopAppPID() {
                guard allowDesktopFallback else {
                    // Signal path: the fallback PID is the shared desktop
                    // Electron process — a POSIX signal to it would freeze/
                    // quit EVERY conversation in Claude Desktop. Surface the
                    // candidate PID for diagnosis, return nil so the caller
                    // degrades instead of signaling it.
                    trace.emit("locator", "locator.desktop_fallback_suppressed pid=\(claudeAppPID) targetCwd=\(targetCwd) note=caller disallowed the Claude.app fallback (signal path) — returning nil instead of the shared desktop PID")
                    return nil
                }
                trace.emit("locator", "locator.claude_app_fallback pid=\(claudeAppPID) targetCwd=\(targetCwd) note=cli-locator missed; using Claude.app NSRunningApplication PID for inject delivery")
                return ProcessHandle(pid: claudeAppPID, execPath: "/Applications/Claude.app/Contents/MacOS/Claude", cwd: "/")
            }
            trace.emit("locator", "locator.not_found targetCwd=\(targetCwd) patterns=\(execNamePatterns.joined(separator: ","))")
            return nil
        case 1:
            let m = matches[0]
            trace.emit("locator", "locator.found pid=\(m.pid) cwd=\(targetCwd) exec=\(m.execPath)")
            return m
        default:
            let pidList = matches.map { String($0.pid) }.joined(separator: ",")
            trace.emit("locator", "locator.ambiguous targetCwd=\(targetCwd) pids=\(pidList)")
            return nil
        }
    }

    /// Multi-session targeting: pin the process for `sessionId` by scanning
    /// each Claude-shaped candidate's argv for the id (Claude Code carries it
    /// as `--resume <id>` / `--session-id <id>`). Returns the unique match, or
    /// nil on 0/2+ matches (caller safe-degrades). Unlike `locate(targetCwd:)`
    /// this is robust to the cwd≠project-dir reality, so it disambiguates
    /// concurrent sessions the cwd walk can't.
    public func locate(bySessionId sessionId: String) -> ProcessHandle? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trace.emit("locator", "locator.session.empty_id")
            return nil
        }
        let pids: [pid_t]
        do {
            pids = try Self.enumerateAllPIDs()
        } catch {
            trace.emit("locator", "locator.sysctl_failed reason=\(error) (bySessionId)")
            return nil
        }
        var matches: [ProcessHandle] = []
        for pid in pids {
            if pid == supervisorPID { continue }
            guard let execPath = Self.execPath(pid: pid) else { continue }
            // Consider only Claude-shaped processes: a recognized exec name,
            // or a JS-runtime interpreter (the `node …/cli.mjs` shape).
            let execBase = (execPath as NSString).lastPathComponent
            let nameMatches = matchesExecName(execPath)
            let interpreterShaped = Self.interpreterBasenames.contains(execBase)
            guard nameMatches || interpreterShaped else { continue }
            guard let argv = Self.readProcessArgv(pid: pid),
                  Self.argvContainsSessionId(argv, sessionId: trimmed) else { continue }
            // An interpreter process must ALSO carry a Claude Code marker so an
            // unrelated `node foo.js --resume <uuid>` can't be mistaken for it.
            if !nameMatches, !Self.argvContainsClaudeCodeMarker(argv) { continue }
            let cwd = Self.cwd(pid: pid) ?? "/"
            matches.append(ProcessHandle(pid: pid, execPath: execPath, cwd: cwd))
        }
        switch matches.count {
        case 0:
            trace.emit("locator", "locator.session.not_found sessionId=\(trimmed)")
            return nil
        case 1:
            let m = matches[0]
            trace.emit("locator", "locator.session.found pid=\(m.pid) sessionId=\(trimmed) exec=\(m.execPath) cwd=\(m.cwd)")
            return m
        default:
            let pidList = matches.map { String($0.pid) }.joined(separator: ",")
            trace.emit("locator", "locator.session.ambiguous sessionId=\(trimmed) pids=\(pidList)")
            return nil
        }
    }

    /// TOCTOU re-check (Finding 4): re-read `pid`'s exec path (and argv for
    /// the interpreter case) and confirm it's still Claude-shaped. A vanished
    /// pid (`proc_pidpath` fails) or a pid reused by an unrelated process
    /// returns false, so the router degrades to notify instead of group-
    /// signaling a stranger. Cheap: one `proc_pidpath`, plus one
    /// KERN_PROCARGS2 read only for the `node …/cli.mjs` interpreter shape —
    /// the same recognition logic `locate` uses, so a process this locator
    /// would have matched a moment ago still passes.
    public func stillClaudeProcess(pid: pid_t) -> Bool {
        // Supervisor is never a legitimate signal target (it holds Claude's
        // JSONLs open and could otherwise look Claude-shaped to a naive check).
        if pid == supervisorPID { return false }
        guard let execPath = Self.execPath(pid: pid) else {
            trace.emit("locator", "locator.recheck.gone pid=\(pid) (proc_pidpath failed — process exited)")
            return false
        }
        if matchesExecName(execPath) {
            // A server-mode codex (the desktop app-server backend) must never be
            // a signal target even if it passes the name match — refuse it here
            // too so the TOCTOU recheck can't re-admit it before a group signal.
            if Self.isCodexServerProcess(execPath: execPath, pid: pid) {
                trace.emit("locator", "locator.recheck.codex_server pid=\(pid) execPath=\(execPath) (server-mode codex — refusing group signal)")
                return false
            }
            return true
        }
        let execBase = (execPath as NSString).lastPathComponent
        if Self.interpreterBasenames.contains(execBase),
           let argv = Self.readProcessArgv(pid: pid),
           Self.argvContainsClaudeCodeMarker(argv) {
            return true
        }
        trace.emit("locator", "locator.recheck.reused pid=\(pid) execPath=\(execPath) (pid no longer resolves to a Claude-shaped process — refusing group signal)")
        return false
    }

    // MARK: - Codex server-mode guard

    /// Codex subcommands that run a long-lived SERVER, not an interactive
    /// session: these back the desktop app / IDE and must never be signalled.
    internal static let codexServerSubcommands: Set<String> = [
        "app-server", "mcp-server", "exec-server", "remote-control",
    ]

    /// True when `pid` is a `codex` binary running in a server mode (e.g. the
    /// Codex desktop app's `codex app-server` child). Only reads argv for
    /// codex-basename processes, so it costs nothing for Claude Code lookups.
    internal static func isCodexServerProcess(execPath: String, pid: pid_t) -> Bool {
        guard (execPath as NSString).lastPathComponent == "codex" else { return false }
        return isCodexServerArgv(readProcessArgv(pid: pid))
    }

    /// The pure argv → server-mode rule, split out so it's testable without a
    /// live process. Scans EVERY argv token (not just argv[1]) because global
    /// flags can precede the subcommand (`codex --log-level debug app-server`
    /// is still the server). A nil argv (KERN_PROCARGS2 unreadable: EPERM,
    /// racing exit, …) FAILS CLOSED — we can't prove a codex-named process is
    /// an interactive session, and mistaking the desktop app's server child
    /// for one means signalling it and freezing the GUI. Refusing an
    /// uninspectable codex costs only a degraded notify.
    internal static func isCodexServerArgv(_ argv: [String]?) -> Bool {
        guard let argv else { return true }
        return argv.contains { codexServerSubcommands.contains($0) }
    }

    // MARK: - Claude.app fallback (v0.3.1)

    /// Returns the PID of the running `com.anthropic.claudefordesktop`
    /// instance if any. Used as the locator's fallback when the
    /// CLI-style cwd-match misses (typical for users running their
    /// Claude Code session inside Claude.app, where the binary is
    /// `Claude` and cwd is `/`). Returns nil if Claude.app isn't
    /// running.
    private static func findClaudeDesktopAppPID() -> pid_t? {
        // NSRunningApplication lookup is cheap and bundle-id-keyed.
        // Filters down to the single Claude.app instance regardless
        // of how many helper processes Electron spawns.
        let claudeBundleID = "com.anthropic.claudefordesktop"
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == claudeBundleID {
                return app.processIdentifier
            }
        }
        return nil
    }

    // MARK: - KERN_PROCARGS2 argv inspection (v0.3.2 Issue #1)

    /// JS-runtime interpreter basenames that plausibly host Claude Code.
    /// Skipped: python, ruby, perl — Claude Code isn't distributed as
    /// those. If a new distribution shape appears, extend this set and
    /// add a corresponding marker to `claudeCodeArgvMarkers`.
    internal static let interpreterBasenames: Set<String> = [
        "node", "bun", "deno",
    ]

    /// Substrings that, when present in any joined argv, identify the
    /// process as Claude Code. Substring search is intentionally
    /// generous because the cwd filter has already constrained
    /// candidates — a false-positive substring match outside the
    /// target cwd never reaches this code path.
    internal static let claudeCodeArgvMarkers: [String] = [
        "cli.mjs",
        "cli.js",
        "@anthropic-ai/claude-code",
        "claude-code-cli",
    ]

    /// Returns the argv of the process via `sysctl(KERN_PROCARGS2)`.
    /// Each element of the returned array is one argv string. Returns
    /// nil if sysctl fails (process gone, EPERM, etc.) — caller treats
    /// nil as "no argv-marker match" without raising an error.
    ///
    /// KERN_PROCARGS2 layout:
    ///   [4 bytes: argc as Int32]
    ///   [execPath null-terminated string + alignment padding]
    ///   [argc null-terminated argv strings]
    ///   [envp null-terminated env strings]
    ///
    /// We only need argv, so we parse argc + execPath + argv-count
    /// strings and stop. Bounded by `kern.argmax` (defaults to ~1 MB
    /// on macOS); we pre-fetch the system limit to size the buffer.
    internal static func readProcessArgv(pid: pid_t) -> [String]? {
        // Step 1: get kern.argmax (the upper bound on argv+envp size
        // per process). This is the maximum buffer we'd ever need.
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        if sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) != 0 || argmax <= 0 {
            // Fallback to a reasonable default if kern.argmax is unreadable.
            argmax = 1 << 20  // 1 MB
        }

        // Step 2: KERN_PROCARGS2 sysctl for this PID.
        var argsMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var bufferSize = Int(argmax)
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(&argsMib, 3, ptr.baseAddress, &bufferSize, nil, 0)
        }
        if rc != 0 {
            return nil
        }
        // bufferSize now contains the actual byte count written.
        if bufferSize < MemoryLayout<Int32>.size {
            return nil
        }

        // Step 3: parse. Layout per `man sysctl` + Darwin kernel source.
        return buffer.withUnsafeBufferPointer { ptr -> [String]? in
            guard let base = ptr.baseAddress else { return nil }
            // First 4 bytes: argc as native Int32.
            let argc: Int32 = base.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
            guard argc > 0 else { return nil }

            // Cursor advances through the buffer. Start past argc (4 bytes).
            var cursor = 4
            let end = bufferSize

            // Skip the executable path (null-terminated).
            while cursor < end && base[cursor] != 0 { cursor += 1 }
            // Skip any padding (null bytes between execPath and argv[0]).
            while cursor < end && base[cursor] == 0 { cursor += 1 }

            // Read argc null-terminated argv strings.
            var argv: [String] = []
            argv.reserveCapacity(Int(argc))
            for _ in 0..<argc {
                guard cursor < end else { break }
                let startOfArg = cursor
                while cursor < end && base[cursor] != 0 { cursor += 1 }
                // Build a String from the byte range [startOfArg, cursor).
                let bytesPtr = base.advanced(by: startOfArg)
                let arg = String(cString: bytesPtr)
                argv.append(arg)
                // Skip the null terminator and advance to next.
                cursor += 1
            }
            return argv.isEmpty ? nil : argv
        }
    }

    /// True if any element of argv contains any of the Claude Code
    /// markers. Substring search across joined argv handles both
    /// per-arg-basename matches (`cli.mjs` as argv[1]) and path-form
    /// matches (`/usr/local/bin/claude/cli.mjs` as argv[1]).
    internal static func argvContainsClaudeCodeMarker(_ argv: [String]) -> Bool {
        let joined = argv.joined(separator: " ")
        for marker in claudeCodeArgvMarkers {
            if joined.contains(marker) {
                return true
            }
        }
        return false
    }

    /// True if `sessionId` (a globally-unique transcript UUID) appears as a
    /// token in argv — the value after `--resume` / `--session-id` / `-r`, or
    /// anywhere argv carries it. UUID uniqueness makes a plain containment
    /// check safe from false positives.
    static func argvContainsSessionId(_ argv: [String], sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        for a in argv where a == sessionId || a.contains(sessionId) { return true }
        return false
    }

    // MARK: - Pattern matching

    private func matchesExecName(_ execPath: String) -> Bool {
        // Exact basename match against the configured patterns. Substring
        // matching is intentionally NOT used here — "FakeClaudeCLI"
        // contains "claude", and we don't want production lookups for
        // pattern "claude" to find arbitrary other apps. Claude Code's
        // real binary basenames (`claude`, `claude-code`) are stable.
        // If Claude Code is ever launched as `node` with the CLI JS in
        // argv[1], a future PR adds KERN_PROCARGS2-based argv inspection;
        // for v0.1.4 we keep it to execPath basename.
        let base = (execPath as NSString).lastPathComponent
        return execNamePatterns.contains(base)
    }

    // MARK: - libproc wrappers

    enum LocatorError: Error, CustomStringConvertible {
        case proc_listallpids_failed(errno: Int32)
        case empty_pid_list

        var description: String {
            switch self {
            case .proc_listallpids_failed(let e):
                return "proc_listallpids errno=\(e) (\(String(cString: strerror(e))))"
            case .empty_pid_list:
                return "proc_listallpids returned 0 bytes (no processes visible)"
            }
        }
    }

    private static func enumerateAllPIDs() throws -> [pid_t] {
        // First call with NULL: returns the number of BYTES needed.
        let neededBytes = proc_listallpids(nil, 0)
        guard neededBytes > 0 else {
            throw LocatorError.proc_listallpids_failed(errno: errno)
        }
        let stride = Int32(MemoryLayout<pid_t>.stride)
        let capacityPids = Int(neededBytes) / Int(stride) + 32  // padding for new procs since the first call
        var buffer = [pid_t](repeating: 0, count: capacityPids)
        let writtenBytes = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_listallpids(ptr.baseAddress, Int32(capacityPids) * stride)
        }
        guard writtenBytes > 0 else {
            throw LocatorError.proc_listallpids_failed(errno: errno)
        }
        let actualCount = Int(writtenBytes) / Int(stride)
        return Array(buffer.prefix(actualCount).filter { $0 > 0 })
    }

    private static func execPath(pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is defined as `4 * MAXPATHLEN` in
        // sys/proc_info.h but Swift's macro importer rejects it (macros
        // for "unsupported structures" are filtered). Hardcode the
        // equivalent literal — MAXPATHLEN is 1024 on macOS, so 4096.
        let cap = 4 * Int(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: cap)
        let ret = proc_pidpath(pid, &buf, UInt32(cap))
        if ret <= 0 { return nil }
        return String(cString: buf)
    }

    private static func cwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard ret == Int32(size) else { return nil }
        // pvi_cdir.vip_path is a C `char[MAXPATHLEN]` — read it as a CChar
        // buffer by rebinding memory; standard pattern for Swift-bridged
        // C fixed arrays.
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }
}
