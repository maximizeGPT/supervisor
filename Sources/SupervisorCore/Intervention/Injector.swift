// Injector.swift — v0.3.0 (targeting corrected v0.6+).
//
// Delivers text into the SPECIFIC app hosting a Claude Code session.
// TARGETED, never global: the injector resolves the session pid to its
// hosting app (findHostingApp), then either
//   - posts keystrokes with CGEvent.postToPid(hostPid) for terminals
//     (Terminal.app, iTerm2, Ghostty, Warp) — focus-independent, so the
//     text lands in that terminal even if a DIFFERENT app is frontmost, and
//   - for the Electron desktop app, brings that host forward, pastes, then
//     restores the prior frontmost app.
// If the host can't be resolved (no hosting app / unsupported bundle / no
// pid) it THROWS — it never falls back to a global frontmost post. That is
// the no-leak guard: text cannot spray into whatever app happens to be
// frontmost. (The earlier v0.3.0 universal-CGEventPost-to-frontmost design,
// described in prior revisions of this header, was the leak source and is
// gone.)
//
// Per the spike note (spikes/cgevent-bypass-ax-spike-README.md) and
// the v0.3.0 A1 scratch test, CGEventPost(.cghidEventTap) for mouse
// events bypasses the Accessibility permission. Keyboard events use
// the same kernel-level tap, so the symmetry argument extends — but
// the AX-revoked keyboard case has not been freshly verified post-
// v0.3.0; filed for follow-up. In practice, Supervisor users who have
// gone through onboarding have AX granted to Supervisor, so the inject
// path works regardless of which conclusion holds about the AX-free
// case.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Per-call result of an inject attempt.
public enum InjectError: Error, Sendable, Equatable {
    /// Couldn't find a foreground app for the target PID's parent process.
    case noHostingApp
    /// The hosting app's bundle ID isn't in the supported set.
    case unsupportedHost(bundleID: String)
    /// NSWorkspace.activate returned false or the OS reported failure.
    case activationFailed(bundleID: String)
    /// CGEvent creation returned nil (rare; usually means the API was
    /// called from a sandboxed context that blocks event creation).
    case eventCreationFailed
    /// The specific supervised session's target could not be resolved, so we
    /// refuse to post (the invariant: targeted-or-don't). `reason` discriminates
    /// the failure for the trace (§4b). Never falls back to a global post.
    case targetUnresolvable(reason: String)
}

/// Abstract injector — lets the router test inject without depending on
/// the live AppKit + CoreGraphics path. The protocol itself is not
/// MainActor-isolated so test mocks can construct without crossing an
/// actor boundary in a default parameter; the production
/// `CGEventInjector` is MainActor at the class level because it touches
/// NSWorkspace.
public protocol Injector: Sendable {
    /// Inject `text` into the terminal hosting `claudeCodePID`. On
    /// success returns the number of bytes injected (informational).
    /// On failure throws an `InjectError` so the router can decide
    /// how to degrade.
    ///
    /// `targetWindowTitle`: when non-nil, the injector attempts to
    /// focus the window whose title contains this substring before
    /// posting keystrokes. This targets the correct Claude.app tab
    /// when multiple tabs are open (Issue #9). When nil, falls back
    /// to the current frontmost window.
    func inject(text: String, claudeCodePID: pid_t, targetWindowTitle: String?) async throws -> Int
}

/// Production injector. Walks up the process tree from the Claude Code
/// PID, finds the hosting NSRunningApplication, activates it frontmost,
/// and posts the keystrokes via CGEventPost.
@MainActor
public final class CGEventInjector: Injector {

    /// Supported hosting bundle IDs. Same set as the hover panel's
    /// `claudeCodeHostApps`. Bundles outside this set fall through to
    /// the `unsupportedHost` error so the router can degrade rather
    /// than spray keystrokes at a random foreground app.
    public static let supportedHosts: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "com.anthropic.claudefordesktop",
    ]

    /// Inter-character delay during keystroke synthesis. Terminal apps
    /// need a few ms between events or coalescing/buffering can drop
    /// characters. 15ms was the value the v0.3.0 A1 scratch test
    /// settled on after a few drops at 5ms.
    private let interCharDelayMicros: useconds_t

    /// Delay between activating the host app and starting to type.
    /// Lets the OS finish bringing the app frontmost.
    private let focusSettleNanos: UInt64

    private let trace: TraceLog

    public init(
        interCharDelayMicros: useconds_t = 15_000,
        focusSettleNanos: UInt64 = 250_000_000,
        trace: TraceLog = .shared
    ) {
        self.interCharDelayMicros = interCharDelayMicros
        self.focusSettleNanos = focusSettleNanos
        self.trace = trace
    }

    public func inject(text: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
        // 1. Resolve the hosting app by walking up the process tree
        //    from claudeCodePID until we hit a running NSApplication.
        guard let hostApp = Self.findHostingApp(for: claudeCodePID) else {
            trace.emit("inject", "ERROR no hosting app for pid=\(claudeCodePID)")
            throw InjectError.noHostingApp
        }
        let bundleID = hostApp.bundleIdentifier ?? ""
        guard Self.supportedHosts.contains(bundleID) else {
            trace.emit("inject", "ERROR unsupported host bundle=\(bundleID) pid=\(claudeCodePID)")
            throw InjectError.unsupportedHost(bundleID: bundleID)
        }

        // 2. Resolve the host app's PID — the TARGET for every keystroke.
        let hostPid = hostApp.processIdentifier
        guard hostPid > 0 else {
            trace.emit("inject", "degraded reason=target_unresolvable detail=no_host_pid host=\(bundleID) cc_pid=\(claudeCodePID)")
            throw InjectError.targetUnresolvable(reason: "no_host_pid")
        }

        // 3. Claude desktop is Electron — it DROPS synthesized keystrokes
        //    while backgrounded, so a background post types a partial message
        //    that breaks the instant the owner switches away. The only
        //    reliable delivery is to bring its OWN window forward, PASTE the
        //    text atomically (not char-by-char), Return, then restore the
        //    owner's prior frontmost app. Brief focus flicker — only when the
        //    owner isn't already in Claude Code — never a partial spray into
        //    another app, never a global post.
        if bundleID == "com.anthropic.claudefordesktop" {
            // SAFETY (2026-06-07): the Claude desktop app is a SINGLE Electron
            // window that multiplexes sessions as TABS. foreground_paste brings
            // that window forward and pastes into whatever tab is focused — it
            // CANNOT target the session the dispatch is actually for. Observed
            // live: an answer generated for the CV/PM session got pasted into
            // the focused tab (cross-session bleed). There is no OS primitive to
            // address an Electron tab, so we DO NOT blind-paste: throw and let
            // the router degrade to a notify banner the owner can paste where
            // they want. Escape hatch (SUPERVISOR_ALLOW_DESKTOP_PASTE) is for the
            // controlled on-screen verification test ONLY — unset in production.
            if ProcessInfo.processInfo.environment["SUPERVISOR_ALLOW_DESKTOP_PASTE"] == nil {
                trace.emit("inject", "degraded reason=electron_no_tab_targeting host=\(bundleID) host_pid=\(hostPid) cc_pid=\(claudeCodePID) note=desktop is one multi-tab window; foreground_paste can't target the session — degrading to notify")
                throw InjectError.targetUnresolvable(reason: "electron_no_tab_targeting")
            }
            return try await injectViaForegroundPaste(text: text, hostApp: hostApp, hostPid: hostPid)
        }

        // 4. Terminals accept TARGETED background posts (CGEventPostToPid),
        //    which ARE focus-independent — the owner keeps using their
        //    frontmost app while the keystrokes flow to the session's host.
        //    THE INVARIANT: never post(tap:) (global); targeted-or-throw.
        let bytes = try postKeystrokes(text: text, hostPid: hostPid, bundleID: bundleID)
        trace.emit("inject", "fired method=postToPid host=\(bundleID) host_pid=\(hostPid) cc_pid=\(claudeCodePID) bytes=\(bytes)")
        return bytes
    }

    /// Char-by-char targeted keystroke synthesis via CGEventPostToPid. For
    /// terminal hosts, which accept background posts (focus-independent).
    private func postKeystrokes(text: String, hostPid: pid_t, bundleID: String) throws -> Int {
        let source = CGEventSource(stateID: .hidSystemState)
        var bytes = 0
        for ch in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                trace.emit("inject", "degraded reason=event_creation_failed host=\(bundleID)")
                throw InjectError.eventCreationFailed
            }
            var c = UniChar(ch.value)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            keyDown.postToPid(hostPid)
            usleep(interCharDelayMicros)
            keyUp.postToPid(hostPid)
            usleep(interCharDelayMicros / 3)
            bytes += String(ch).utf8.count
        }
        if let downRet = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
           let upRet = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            downRet.postToPid(hostPid)
            usleep(interCharDelayMicros)
            upRet.postToPid(hostPid)
        }
        return bytes
    }

    /// Electron delivery: save the owner's frontmost app + clipboard, bring
    /// the host forward, paste (Cmd-V) + Return targeted to the now-frontmost
    /// host, then restore clipboard and the prior frontmost app. Atomic, so it
    /// can never be truncated mid-message by an app switch. If the owner is
    /// already in Claude Code, `prior` is Claude Code itself, so there's no
    /// visible flicker.
    private func injectViaForegroundPaste(text: String, hostApp: NSRunningApplication, hostPid: pid_t) async throws -> Int {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        let prior = NSWorkspace.shared.frontmostApplication

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard hostApp.activate(options: []) else {
            restoreClipboard(savedClipboard, pasteboard)
            trace.emit("inject", "degraded reason=electron_activate_failed host=com.anthropic.claudefordesktop")
            throw InjectError.targetUnresolvable(reason: "electron_activate_failed")
        }
        try? await Task.sleep(nanoseconds: focusSettleNanos)

        let source = CGEventSource(stateID: .hidSystemState)
        postChord(source: source, virtualKey: 9, flags: .maskCommand, hostPid: hostPid)  // Cmd-V (paste)
        usleep(interCharDelayMicros * 2)
        // SUPERVISOR_INJECT_NO_SUBMIT lets a verification run paste WITHOUT
        // submitting (so an on-screen test doesn't fire a real message).
        // Unset in production — the Return submits the answer/dispatch.
        if ProcessInfo.processInfo.environment["SUPERVISOR_INJECT_NO_SUBMIT"] == nil {
            postChord(source: source, virtualKey: 36, flags: [], hostPid: hostPid)        // Return
        }
        try? await Task.sleep(nanoseconds: focusSettleNanos / 2)

        restoreClipboard(savedClipboard, pasteboard)
        prior?.activate(options: [])

        trace.emit("inject", "fired method=foreground_paste host=com.anthropic.claudefordesktop host_pid=\(hostPid) bytes=\(text.utf8.count) restored=\(prior?.bundleIdentifier ?? "?")")
        return text.utf8.count
    }

    private func restoreClipboard(_ saved: String?, _ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    /// Post a single key chord (key + modifier flags) targeted to a pid.
    private func postChord(source: CGEventSource?, virtualKey: CGKeyCode, flags: CGEventFlags, hostPid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.postToPid(hostPid)
        usleep(interCharDelayMicros)
        up.postToPid(hostPid)
    }

    // MARK: - AX window targeting (Issue #9)

    /// Enumerate the app's windows via AXUIElement and focus the one
    /// whose title contains `substring`. Best-effort: if AX is disabled,
    /// the app has no windows, or no title matches, this no-ops and the
    /// caller falls back to posting into whatever window is frontmost.
    static func focusWindow(
        app: NSRunningApplication,
        titleContaining substring: String,
        trace: TraceLog
    ) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement] else {
            trace.emit("inject", "ax_window_enum failed err=\(err.rawValue) pid=\(app.processIdentifier)")
            return
        }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else {
                continue
            }
            if title.localizedCaseInsensitiveContains(substring) {
                let raiseErr = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                trace.emit("inject", "ax_window_focused title=\"\(title.prefix(60))\" target=\"\(substring.prefix(40))\" raise_err=\(raiseErr.rawValue)")
                return
            }
        }

        trace.emit("inject", "ax_window_no_match target=\"\(substring.prefix(40))\" window_count=\(windows.count)")
    }

    // MARK: - Process-tree walking

    /// Walk up from `pid` looking for a NSRunningApplication. Bounded
    /// at 5 hops because the typical depth is 1-2 (claude → bash →
    /// terminal-app) and anything deeper is suspect.
    public static func findHostingApp(for pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<5 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.bundleIdentifier != nil {
                return app
            }
            guard let parent = parentPID(of: current), parent > 0 else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Look up parent PID via `proc_pidinfo(PROC_PIDTBSDINFO)`. Returns
    /// nil if the call fails (process gone, EPERM, etc.).
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        if n != Int32(size) { return nil }
        return pid_t(info.pbi_ppid)
    }
}

/// In-memory test injector. Records every inject call so tests can
/// assert without driving the live event tap. Optionally throws a
/// predetermined error. Emits a parity `[inject] wrote` trace line so
/// canary tests checking the trace pipeline see the same shape they
/// would in production.
public final class MockInjector: Injector, @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public let text: String
        public let pid: pid_t
        public let targetWindowTitle: String?
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    public var errorToThrow: InjectError?
    public var bytesToReturn: Int = 0
    public let trace: TraceLog?

    public init(trace: TraceLog? = nil) {
        self.trace = trace
    }

    public func inject(text: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
        lock.lock()
        _calls.append(Call(text: text, pid: claudeCodePID, targetWindowTitle: targetWindowTitle))
        lock.unlock()
        if let err = errorToThrow {
            throw err
        }
        let bytes = bytesToReturn == 0 ? text.utf8.count : bytesToReturn
        trace?.emit("inject", "wrote \(bytes) bytes to PID \(claudeCodePID) (mock)")
        return bytes
    }
}
