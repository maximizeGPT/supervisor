// ResumeResolver.swift — the hover panel's Resume button, made honest.
//
// Resume is a SIGNAL-SENDING action (SIGCONT), so it carries the same hazard
// the router's pause/kill path carries: the locator's Claude.app fallback
// resolves to the SHARED desktop Electron host, not to any one session's CLI
// process. Sending SIGCONT there continues a process nobody stopped, while the
// session the owner actually paused stays frozen — and the old handler then
// returned `true`, so the panel cleared the paused state and claimed a resume
// that never happened.
//
// Two rules follow, and this type exists to hold both in one place:
//
//   1. Resolve by SESSION ID first. The paused session's id is pinned at pause
//      time (HoverViewModel.pausedSessionId), and an argv id match pins exactly
//      one process even when several sessions share a cwd. cwd alone cannot:
//      the `claude` process cwd is usually the user's home dir.
//   2. Never accept the desktop fallback. The cwd walk runs with
//      `allowDesktopFallback: false`, and any handle that still looks like the
//      shared host is refused outright.
//
// Failure is reported, never swallowed: `ResumeOutcome` names WHY nothing was
// signalled so the panel can say so instead of showing a resumed session.
//
// Lives in Core (not in main.swift's wiring closure) so it is reachable from
// tests — SupervisorApp is an executable target and XCTest cannot import it.

import Darwin
import Foundation

/// What a Resume attempt actually did. Every non-`resumed` case means NO signal
/// was sent, and each one carries a plain-voice line for the panel.
public enum ResumeOutcome: Equatable, Sendable {
    /// SIGCONT was delivered to `pid`.
    case resumed(pid: pid_t)
    /// Neither the session id nor the cwd pinned a process we are allowed to
    /// signal. The session may have exited, or it may be hosted somewhere the
    /// locator cannot pin (see `refusedSharedDesktopHost`).
    case notResolved
    /// The only thing that resolved was the shared Claude desktop host. Refused:
    /// its pid is every conversation at once, so signalling it would be both
    /// wrong and dangerous.
    case refusedSharedDesktopHost(pid: pid_t)
    /// A process was pinned, but `kill(2)` failed (process exited between the
    /// lookup and the signal, permission denied, …).
    case signalFailed(reason: String)

    /// True only when a real SIGCONT landed. The caller clears the paused state
    /// on this and on nothing else.
    public var didResume: Bool {
        if case .resumed = self { return true }
        return false
    }

    /// The line the panel shows when the resume did not happen, in the app's
    /// plain voice (no pids, no signal names, no jargon). nil on success.
    public var userFacingReason: String? {
        switch self {
        case .resumed:
            return nil
        case .notResolved:
            return "Could not resume: Supervisor could not find the paused session's process. It may have already exited."
        case .refusedSharedDesktopHost:
            return "Could not resume: the only match was the Claude desktop app itself, which runs every conversation at once. Resume that session from the app instead."
        case .signalFailed:
            return "Could not resume: the session's process refused the resume signal."
        }
    }
}

/// Resolves the paused session to a process and sends it SIGCONT, refusing any
/// target a signal must not touch. Held by the app and called from the hover
/// view model's `resumeHandler`.
public struct ResumeResolver: Sendable {

    private let locator: any ProcessLocator
    private let signalSender: any SignalSender
    private let trace: TraceLog

    public init(
        locator: any ProcessLocator,
        signalSender: any SignalSender,
        trace: TraceLog = .shared
    ) {
        self.locator = locator
        self.signalSender = signalSender
        self.trace = trace
    }

    /// Resume the session pinned by `sessionId` (preferred) or `cwd` (fallback).
    /// Either may be empty; when both are, nothing can be resolved and the
    /// attempt reports `.notResolved` rather than guessing.
    public func resume(sessionId: String, cwd: String) -> ResumeOutcome {
        guard let handle = resolveSignalTarget(sessionId: sessionId, cwd: cwd) else {
            trace.emit("hover", "resume.not_resolved session=\(sessionId.isEmpty ? "-" : sessionId) cwd=\(cwd.isEmpty ? "-" : cwd)")
            return .notResolved
        }
        // Belt-and-braces on top of `allowDesktopFallback: false`: the by-session
        // path is a separate lookup with its own matching rules, so the refusal
        // is asserted on the HANDLE that is about to be signalled, not only on
        // the one code path known to produce a desktop handle.
        if handle.isSharedDesktopHost {
            trace.emit("hover", "resume.refused_desktop_host pid=\(handle.pid) session=\(sessionId.isEmpty ? "-" : sessionId) — SIGCONT to the shared Claude.app host would target every conversation, not the paused session")
            return .refusedSharedDesktopHost(pid: handle.pid)
        }
        do {
            try signalSender.send(SIGCONT, to: handle.pid)
            trace.emit("hover", "resume.sigcont_sent pid=\(handle.pid) session=\(sessionId.isEmpty ? "-" : sessionId) cwd=\(cwd)")
            return .resumed(pid: handle.pid)
        } catch let err as SignalError {
            let reason = err.isProcessGone ? "process_gone"
                : (err.isPermissionDenied ? "permission_denied" : "errno=\(err.errnoValue)")
            trace.emit("hover", "resume.sigcont_failed pid=\(handle.pid) reason=\(reason)")
            return .signalFailed(reason: reason)
        } catch {
            trace.emit("hover", "resume.sigcont_failed pid=\(handle.pid) reason=unexpected_throw=\(error)")
            return .signalFailed(reason: "unexpected_throw")
        }
    }

    /// Session id first, then the cwd walk with the desktop fallback DISALLOWED.
    /// Mirrors the router's `resolveTarget` precedence, minus the fallback the
    /// router's inject path is allowed to keep.
    private func resolveSignalTarget(sessionId: String, cwd: String) -> ProcessHandle? {
        if !sessionId.isEmpty, let byId = locator.locate(bySessionId: sessionId) {
            trace.emit("hover", "resume.target_by_session_id pid=\(byId.pid) session=\(sessionId) exec=\(byId.execPath)")
            return byId
        }
        if !cwd.isEmpty, let byCwd = locator.locate(targetCwd: cwd, allowDesktopFallback: false) {
            trace.emit("hover", "resume.target_by_cwd pid=\(byCwd.pid) cwd=\(cwd) exec=\(byCwd.execPath)")
            return byCwd
        }
        return nil
    }
}
