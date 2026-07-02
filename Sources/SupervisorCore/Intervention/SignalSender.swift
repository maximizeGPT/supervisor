// SignalSender.swift — v0.1.4 Part A3.
//
// Abstracts the POSIX `kill(2)` syscall so the router can be unit-tested
// without actually signaling real processes. Production code uses
// `DarwinSignalSender` (which posts the signal via `kill(2)`); tests
// inject a `CapturingSignalSender` and assert against the recorded calls.
//
// v0.9.x: `sendToGroup` signals the whole process group (`kill(-pgid)`),
// which the pause/kill paths use so an already-forked child of the
// `claude` process is stopped/terminated along with it.

import Darwin
import Foundation

public protocol SignalSender: Sendable {
    /// Send `signal` to `pid`. Throws `SignalError` on POSIX failure;
    /// the router maps each error class to a discriminating trace tag
    /// + notify-fallback. Successful send returns void.
    func send(_ signal: Int32, to pid: pid_t) throws

    /// Send `signal` to the process GROUP containing `pid`. The pause/kill
    /// paths need this: SIGSTOP to the `claude` node process alone does NOT
    /// stop an already-forked child (`bash -c 'rm -rf …'` keeps running).
    /// Implementations resolve the group via `getpgid(2)` and signal
    /// `-pgid`, falling back to the single-pid send when the group can't
    /// be resolved. A default implementation forwards to `send(_:to:)` so
    /// existing conformers (test mocks) stay source-compatible.
    func sendToGroup(_ signal: Int32, of pid: pid_t) throws
}

public extension SignalSender {
    func sendToGroup(_ signal: Int32, of pid: pid_t) throws {
        try send(signal, to: pid)
    }
}

public struct SignalError: Error, CustomStringConvertible {
    public let errnoValue: Int32

    public init(errnoValue: Int32) {
        self.errnoValue = errnoValue
    }

    /// `ESRCH` — the target process exited between locator lookup and
    /// signal dispatch. Race-condition outcome; harmless once handled.
    public var isProcessGone: Bool { errnoValue == ESRCH }

    /// `EPERM` — Supervisor lacks permission to signal the target.
    /// Should be rare for same-user processes; surface for diagnosis.
    public var isPermissionDenied: Bool { errnoValue == EPERM }

    public var description: String {
        "SignalError errno=\(errnoValue) (\(String(cString: strerror(errnoValue))))"
    }
}

public struct DarwinSignalSender: SignalSender {
    public init() {}
    public func send(_ signal: Int32, to pid: pid_t) throws {
        let ret = kill(pid, signal)
        if ret != 0 {
            throw SignalError(errnoValue: errno)
        }
    }

    public func sendToGroup(_ signal: Int32, of pid: pid_t) throws {
        let pgid = getpgid(pid)
        // Group unresolvable (process gone, EPERM), or the target somehow
        // shares Supervisor's own process group (never signal ourselves):
        // fall back to the single-pid send so the primary target is still
        // hit and the error taxonomy stays the same.
        guard pgid > 0, pgid != getpgrp() else {
            try send(signal, to: pid)
            return
        }
        if kill(-pgid, signal) != 0 {
            throw SignalError(errnoValue: errno)
        }
    }
}
