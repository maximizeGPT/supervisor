// SignalSender.swift — v0.1.4 Part A3.
//
// Abstracts the POSIX `kill(2)` syscall so the router can be unit-tested
// without actually signaling real processes. Production code uses
// `DarwinSignalSender` (which posts the signal via `kill(2)`); tests
// inject a `CapturingSignalSender` and assert against the recorded calls.

import Darwin
import Foundation

public protocol SignalSender: Sendable {
    /// Send `signal` to `pid`. Throws `SignalError` on POSIX failure;
    /// the router maps each error class to a discriminating trace tag
    /// + notify-fallback. Successful send returns void.
    func send(_ signal: Int32, to pid: pid_t) throws
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
}
