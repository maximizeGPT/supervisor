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
}

/// Production implementation backed by libproc on macOS. No entitlements
/// required for same-user processes.
public final class LiveProcessLocator: ProcessLocator, @unchecked Sendable {

    private let execNamePatterns: [String]
    private let trace: TraceLog
    private let supervisorPID: pid_t

    public init(
        execNamePatterns: [String] = ["claude", "claude-code"],
        trace: TraceLog = .shared
    ) {
        self.execNamePatterns = execNamePatterns
        self.trace = trace
        self.supervisorPID = getpid()
    }

    public func locate(targetCwd: String) -> ProcessHandle? {
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
        // Claude Code session but is launched as `node` / `python` /
        // `bun` / etc. (the interpreter case), we don't have argv
        // inspection yet (proper fix queued) but we can at least emit
        // a loud trace tag identifying the candidate that got skipped.
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
                // it's a candidate we silently dropped — surface it.
                if let cwd = Self.cwd(pid: pid), cwd == targetCwd {
                    unrecognizedInTargetCwd.append((pid: pid, exec: execPath))
                }
                continue
            }
            guard let cwd = Self.cwd(pid: pid) else { continue }
            guard cwd == targetCwd else { continue }
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
