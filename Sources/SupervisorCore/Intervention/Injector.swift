// Injector.swift, v0.3.0 (targeting corrected v0.6+).
//
// Delivers text into the SPECIFIC app hosting a Claude Code session.
// TARGETED, never global: the injector resolves the session pid to its
// hosting app (findHostingApp), then either
//   - posts keystrokes with CGEvent.postToPid(hostPid) for terminals
//     (Terminal.app, iTerm2, Ghostty, Warp), focus-independent, so the
//     text lands in that terminal even if a DIFFERENT app is frontmost, and
//   - for the Electron desktop app, brings that host forward, pastes, then
//     restores the prior frontmost app.
// If the host can't be resolved (no hosting app / unsupported bundle / no
// pid) it THROWS, it never falls back to a global frontmost post. That is
// the no-leak guard: text cannot spray into whatever app happens to be
// frontmost. (The earlier v0.3.0 universal-CGEventPost-to-frontmost design,
// described in prior revisions of this header, was the leak source and is
// gone.)
//
// Per the spike note (spikes/cgevent-bypass-ax-spike-README.md) and
// the v0.3.0 A1 scratch test, CGEventPost(.cghidEventTap) for mouse
// events bypasses the Accessibility permission. Keyboard events use
// the same kernel-level tap, so the symmetry argument extends, but
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

/// Abstract injector, lets the router test inject without depending on
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

/// The parked-draft guard's read side (Fix #1): "is the owner's terminal input
/// line empty right now?" Abstracted (like `HumanActivityProbe`) so the submit
/// gate can be unit-tested with a deterministic stub instead of the live AX
/// tree. Returns `true` (confirmed empty → safe to submit), `false` (confirmed
/// non-empty → a parked draft, must not append+submit), or `nil` (could not
/// read → the caller stages the answer WITHOUT auto-submitting).
public protocol TerminalComposerProbe: Sendable {
    func inputLineIsEmpty(hostPid: pid_t, bundleID: String) -> Bool?
}

/// Production probe: reads the hosting terminal's focused AX text and judges
/// whether the CURRENT input line (the text after the last newline — the shell
/// prompt plus anything typed after it) is empty. Best-effort and conservative:
/// on any AX failure, or a prompt shape it can't recognize, it returns `nil`
/// (unknown) so the caller stages rather than risks auto-submitting onto a
/// draft it could not read. NOTE: reliable per-terminal input-line extraction is
/// inherently heuristic; this recognizes the common `$ % # >` prompt tails and
/// otherwise abstains. Validate against live Terminal/iTerm/Ghostty/Warp before
/// relying on the auto-submit (confirmed-empty) fast path.
public struct AXTerminalComposerProbe: TerminalComposerProbe {
    public init() {}

    public func inputLineIsEmpty(hostPid: pid_t, bundleID: String) -> Bool? {
        let axApp = AXUIElementCreateApplication(hostPid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // focused is an AXUIElement (a CF type); read its full text value.
        let element = focused as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty else {
            return nil
        }
        let lastLine = value.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? value
        return Self.lineIsEmptyAfterPrompt(lastLine)
    }

    /// Pure heuristic (unit-testable): given the current terminal line, decide
    /// whether it ends AT the shell prompt with nothing typed after it. Returns
    /// `true` when only whitespace follows a recognized PRIMARY prompt
    /// terminator, `false` when real characters follow it (a parked draft), and
    /// `nil` when no recognizable prompt terminator is present (we can't judge —
    /// abstain, and the caller stages the answer WITHOUT auto-submitting).
    ///
    /// Fix (Finding 2): the primary prompt is `$` (sh/bash), `%` (zsh), or `#`
    /// (root), each rendered by PS1 with a trailing space before the cursor. Two
    /// tightenings keep a real draft ending in a prompt-like char from being
    /// misread as an empty composer (which would append our answer and press
    /// Return onto the owner's parked draft):
    ///   1. `>` is NOT a primary prompt — it is the CONTINUATION prompt (PS2) or
    ///      a redirection operator, so a line ending in `>` ("cat notes.md > ")
    ///      is a draft/incomplete command, never "empty and ready". Dropping it
    ///      makes such a line abstain (nil) instead of reporting empty.
    ///   2. The glyph must be followed by at least one whitespace char: a real
    ///      prompt is "<glyph> " (glyph, space, cursor), so a bare trailing
    ///      glyph with nothing after it ("echo $") is command content, not a
    ///      prompt, and abstains rather than reporting empty.
    /// When uncertain we ABSTAIN (nil) — the safe direction is to not submit.
    static func lineIsEmptyAfterPrompt(_ line: String) -> Bool? {
        // `[%$#]` — primary prompt glyphs only (no `>`); `\s+` — the prompt's
        // trailing space is required, so a bare trailing glyph is not a prompt.
        guard let re = try? NSRegularExpression(pattern: #"[%$#]\s+"#) else { return nil }
        let ns = line as NSString
        let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        let tail = ns.substring(from: last.range.location + last.range.length)
        return tail.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Test probe: returns a fixed composer reading so the submit gate can be
/// exercised deterministically.
public struct StubTerminalComposerProbe: TerminalComposerProbe {
    public let state: Bool?
    public init(state: Bool?) { self.state = state }
    public func inputLineIsEmpty(hostPid: pid_t, bundleID: String) -> Bool? { state }
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

    /// Off-main serial queue for the blocking desktop conversation targeting
    /// (screenshot + OCR + click + verify). Keeps the ~4s of work off the
    /// @MainActor so it can't freeze the UI or the triage/catch engine.
    private static let desktopTargetingQueue = DispatchQueue(
        label: "live.supervisor.desktop-targeting", qos: .userInitiated)

    /// Off-main serial queue for TERMINAL keystroke synthesis. postToPid types
    /// char-by-char with a per-character usleep (~15ms/char), so a multi-hundred-
    /// byte answer blocks for seconds. On the @MainActor that froze the UI AND
    /// the triage/catch loop for the whole inject. The desktop path already runs
    /// its slow work off-main on `desktopTargetingQueue`; this is the symmetric
    /// queue for the terminal path so the synthesis can't stall the main actor.
    private static let terminalTypingQueue = DispatchQueue(
        label: "live.supervisor.terminal-typing", qos: .userInitiated)

    /// Inter-character delay during keystroke synthesis. Terminal apps
    /// need a few ms between events or coalescing/buffering can drop
    /// characters. 15ms was the value the v0.3.0 A1 scratch test
    /// settled on after a few drops at 5ms.
    private let interCharDelayMicros: useconds_t

    /// Delay between activating the host app and starting to type.
    /// Lets the OS finish bringing the app frontmost.
    private let focusSettleNanos: UInt64

    private let trace: TraceLog

    /// Optional LLM client for Path B semantic conversation matching on the
    /// desktop targeting path. nil keeps the local token-overlap matcher, so
    /// existing callers and tests are unaffected.
    private let llm: LLMClient?

    /// The parked-draft guard (Fix #1): before pressing Return on the terminal
    /// path, we ask this probe whether the owner's input line is empty. A
    /// half-typed draft parked in the composer must NEVER be merged with our
    /// answer and auto-submitted. Injected so tests can drive the submit gate
    /// deterministically; production reads the terminal's AX text.
    private let composerProbe: TerminalComposerProbe

    public init(
        interCharDelayMicros: useconds_t = 15_000,
        focusSettleNanos: UInt64 = 250_000_000,
        trace: TraceLog = .shared,
        llm: LLMClient? = nil,
        composerProbe: TerminalComposerProbe = AXTerminalComposerProbe()
    ) {
        self.interCharDelayMicros = interCharDelayMicros
        self.focusSettleNanos = focusSettleNanos
        self.trace = trace
        self.llm = llm
        self.composerProbe = composerProbe
    }

    public func inject(text rawText: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
        // Single choke point (the injector boundary every injection must cross)
        // funnels every path through `wrap`. Per the no-stamp decision, `wrap`
        // is now a clean passthrough (it only strips a legacy banner from any
        // re-queued pre-decision dispatch): injections read clean, with no
        // in-text provenance marker. Provenance for Supervisor's own triage is
        // carried out of band by the InjectionLedger, which the router records
        // at inject time. `wrap` is idempotent, so a caller that already passed
        // the body through it (the router, to record the exact ledger form
        // before typing) is unaffected.
        let text = SupervisorInjectionMarker.wrap(rawText)
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

        // 2. Resolve the host app's PID, the TARGET for every keystroke.
        let hostPid = hostApp.processIdentifier
        guard hostPid > 0 else {
            trace.emit("inject", "degraded reason=target_unresolvable detail=no_host_pid host=\(bundleID) cc_pid=\(claudeCodePID)")
            throw InjectError.targetUnresolvable(reason: "no_host_pid")
        }

        // 3. Claude desktop is Electron, it DROPS synthesized keystrokes
        //    while backgrounded, so a background post types a partial message
        //    that breaks the instant the owner switches away. The only
        //    reliable delivery is to bring its OWN window forward, PASTE the
        //    text atomically (not char-by-char), Return, then restore the
        //    owner's prior frontmost app. Brief focus flicker, only when the
        //    owner isn't already in Claude Code, never a partial spray into
        //    another app, never a global post.
        if bundleID == "com.anthropic.claudefordesktop" {
            // The Claude desktop app is one Electron window that multiplexes
            // conversations, with an opaque AX tree, we can't address a
            // conversation through AX. So we target it the way a human does:
            // screenshot the window, OCR the sidebar, find the conversation whose
            // title matches the one we're answering, click it to make it active,
            // VERIFY the switch, then paste. The target's identity is its
            // ai-title, passed in as `targetWindowTitle`.
            let originalPrior = NSWorkspace.shared.frontmostApplication
            let target = (targetWindowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                trace.emit("inject", "degraded reason=desktop_no_target_title host=\(bundleID) cc_pid=\(claudeCodePID)")
                throw InjectError.targetUnresolvable(reason: "desktop_no_target_title")
            }
            let targeter = DesktopConversationTargeter(trace: trace)
            // Run the ~4s screenshot+OCR+poll OFF the @MainActor so it never
            // freezes the UI or blocks the @MainActor triage/catch engine. A
            // dedicated serial queue (NOT the cooperative pool) avoids the
            // pool-starvation failure mode; activateClaudeApp hops to main.
            let llm = self.llm
            let trace = self.trace
            let outcome: DesktopTargetingOutcome = await withCheckedContinuation { cont in
                Self.desktopTargetingQueue.async {
                    // Path B semantic matcher (active text provider) when a
                    // client is wired; the desktop sidebar truncates/rewords
                    // titles, which the local token matcher scores under the
                    // gate. Falls back to the local matcher on any LLM failure
                    // so targeting never regresses below today's behavior. The
                    // matcher is built and used entirely on this queue, so no
                    // non-Sendable closure crosses a concurrency boundary.
                    let matcher: (([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)?)?
                    if let llm = llm {
                        let semantic = LLMConversationMatcher(client: llm, trace: trace)
                        matcher = { candidates, target in
                            // Fuzzy stays the default: it's fast and free, so
                            // trust it when it's clearly confident (>= 0.80, an
                            // exact/near-exact window title). Escalate to the
                            // semantic LLM matcher ONLY for the ambiguous,
                            // truncated, or reworded cases the token math can't
                            // resolve (the 18:07 conf=0.50 miss), falling back to
                            // the fuzzy result if the LLM call fails. Screen
                            // recording is already a precondition here: a denied
                            // grant short-circuits to .screenRecordingDenied
                            // upstream, so no candidates (and no matcher call)
                            // ever happen without OCR text available.
                            let local = targeter.bestMatch(target: target, candidates: candidates)
                            if let local = local, local.1 >= 0.80 { return local }
                            return semantic.match(target: target, candidates: candidates) ?? local
                        }
                    } else {
                        matcher = nil
                    }
                    cont.resume(returning: targeter.focusConversation(targetTitle: target, matcher: matcher))
                }
            }
            switch outcome {
            case .focused(let matched):
                // Claude.app is now frontmost with the target conversation
                // active. Paste into it, then restore the owner's prior app.
                let bytes = pasteIntoFrontmost(text: text, hostPid: hostPid)
                originalPrior?.activate(options: [])
                trace.emit("inject", "fired method=desktop_targeted_paste host=\(bundleID) host_pid=\(hostPid) cc_pid=\(claudeCodePID) bytes=\(bytes) target=\"\(matched.prefix(40))\" restored=\(originalPrior?.bundleIdentifier ?? "?")")
                return bytes
            case .targetingFailed(let reason):
                // confident-match-or-notify: could not confirm the right
                // conversation, so we DO NOT paste. Loud targeting-FAILURE trace
                // (not routine) and degrade to a notify the owner can act on.
                originalPrior?.activate(options: [])
                trace.emit("inject", "degraded reason=desktop_targeting_failed host=\(bundleID) cc_pid=\(claudeCodePID) detail=\(reason)")
                throw InjectError.targetUnresolvable(reason: "desktop_targeting_failed")
            case .screenRecordingDenied:
                // Can't screenshot without Screen Recording. Surface it; never a
                // silent degrade, the permission layer prompts for the grant.
                trace.emit("inject", "degraded reason=desktop_screen_recording_denied host=\(bundleID) cc_pid=\(claudeCodePID)")
                throw InjectError.targetUnresolvable(reason: "screen_recording_denied")
            }
        }

        // 4. Terminal hosts. CGEventPostToPid to a BACKGROUNDED terminal
        //    silently DROPS the keystrokes, confirmed on screen 2026-06-07:
        //    posting to a non-frontmost Terminal.app never reached the claude
        //    tab (and didn't leak to the frontmost app either, it just
        //    vanished). The old "focus-independent" claim was wrong. So we use
        //    the same bring-forward-then-restore shape as the Electron path:
        //    save the owner's frontmost app, activate the terminal (its
        //    selected tab is the target, see selectTerminalTab below), post
        //    the keystrokes into that now-frontmost tab, then restore the prior
        //    frontmost. Targeted (never a global post); lands in the session,
        //    not whatever app the owner is looking at.
        // Terminal hosts. CGEventPostToPid delivers focus-independently to the
        // host terminal's SELECTED tab even while it's backgrounded, confirmed
        // on screen 2026-06-08: a keystroke probe landed in the claude tab's
        // input box with TextEdit still frontmost. (Paste/Cmd-V did NOT land for
        // Terminal; per-char synthesis does.) We select the session's tab first
        //, so the post hits the RIGHT session, not whatever tab the owner last
        // used, WITHOUT stealing focus, then post. Never a global tap, never
        // the frontmost app.
        Self.selectTerminalTab(forClaudePID: claudeCodePID, hostBundleID: bundleID, trace: trace)
        // Fix #2: run the char-by-char synthesis (per-character usleep, seconds
        // of blocking for a long answer) OFF the @MainActor on a dedicated serial
        // queue so it can't freeze the UI or the triage/catch loop — symmetric
        // with the desktop path's `desktopTargetingQueue`. Only a value-typed
        // result (Int, or an InjectError to re-throw) crosses back to main.
        let delay = interCharDelayMicros
        let probe = composerProbe
        let trace = self.trace
        let synth: Result<Int, InjectError> = await withCheckedContinuation { cont in
            Self.terminalTypingQueue.async {
                do {
                    let bytes = try Self.synthesizeTerminalKeystrokes(
                        text: text, hostPid: hostPid, bundleID: bundleID,
                        interCharDelayMicros: delay, composerProbe: probe, trace: trace)
                    cont.resume(returning: .success(bytes))
                } catch let e as InjectError {
                    cont.resume(returning: .failure(e))
                } catch {
                    cont.resume(returning: .failure(.eventCreationFailed))
                }
            }
        }
        let bytes = try synth.get()
        trace.emit("inject", "fired method=postToPid host=\(bundleID) host_pid=\(hostPid) cc_pid=\(claudeCodePID) bytes=\(bytes)")
        return bytes
    }

    /// What the terminal submit gate (Fix #1) decided from the composer state.
    enum TerminalSubmitDecision: Equatable, Sendable, CustomStringConvertible {
        /// The input line is CONFIRMED non-empty (a parked owner draft): refuse
        /// to type at all — never append+submit onto their draft.
        case blockNonEmpty
        /// The input line is CONFIRMED empty: safe to type AND press Return.
        case typeAndSubmit
        /// The composer state could not be read: type the answer but do NOT
        /// auto-submit, so a draft we couldn't see is never merged+sent; the
        /// owner presses Enter. (The safe direction for the unreachable case.)
        case typeNoSubmit
        public var description: String {
            switch self {
            case .blockNonEmpty: return "block_nonempty"
            case .typeAndSubmit: return "type_and_submit"
            case .typeNoSubmit:  return "type_no_submit"
            }
        }
    }

    /// Pure mapping from composer-emptiness (true=empty, false=non-empty,
    /// nil=unknown) to the submit decision. Extracted so the parked-draft gate
    /// is unit-testable without a live event tap.
    nonisolated static func terminalSubmitDecision(composerEmpty: Bool?) -> TerminalSubmitDecision {
        switch composerEmpty {
        case .some(false): return .blockNonEmpty
        case .some(true):  return .typeAndSubmit
        case .none:        return .typeNoSubmit
        }
    }

    /// Char-by-char targeted keystroke synthesis via CGEventPostToPid. For
    /// terminal hosts, which accept background posts (focus-independent). Static
    /// + nonisolated so it can run OFF the @MainActor (Fix #2) — it captures no
    /// actor state, every dependency is passed in.
    ///
    /// Fix #1 (parked-draft merge-and-submit): before we type — let alone press
    /// Return — we consult the composer probe. A CONFIRMED non-empty input line
    /// means the owner has a half-typed draft parked there; appending our answer
    /// and submitting would send one mangled message, and the 2s HID gate does
    /// NOT catch a draft parked longer than that. So a confirmed-non-empty
    /// composer throws BEFORE typing (the router degrades to a notify surfacing
    /// the answer for manual paste); an unreadable composer types WITHOUT Return
    /// (staged, never auto-submitted); only a confirmed-empty composer submits.
    ///
    /// Modifier-safe by construction: the per-character events carry an EMPTY
    /// flag mask (text typing never holds a modifier), and the whole sequence
    /// is bracketed by a "release all modifiers" guard, emitted up front AND
    /// in a `defer` so it runs even on an early throw. So a stray modifier from
    /// a prior, interrupted injection can never combine with a typed character
    /// (the Cmd+Tab / app-switcher / keyboard-hijack failure mode), and this
    /// sequence never strands one of its own.
    nonisolated private static func synthesizeTerminalKeystrokes(
        text: String,
        hostPid: pid_t,
        bundleID: String,
        interCharDelayMicros: useconds_t,
        composerProbe: TerminalComposerProbe,
        trace: TraceLog
    ) throws -> Int {
        let composerEmpty = composerProbe.inputLineIsEmpty(hostPid: hostPid, bundleID: bundleID)
        let decision = terminalSubmitDecision(composerEmpty: composerEmpty)
        trace.emit("inject", "terminal_submit_gate composer=\(composerEmpty.map { $0 ? "empty" : "nonempty" } ?? "unknown") decision=\(decision) host=\(bundleID)")
        // Parked-draft guard: a CONFIRMED non-empty input line is the owner's
        // draft. Never append onto it — throw before a single keystroke; the
        // router degrades to a notify banner with the answer for manual paste.
        if decision == .blockNonEmpty {
            throw InjectError.targetUnresolvable(reason: "terminal_composer_nonempty")
        }

        let source = CGEventSource(stateID: .hidSystemState)
        // Self-closing guard: whatever happens below, success, early throw, or
        // a partial sequence, every modifier is released afterward.
        defer { postReleaseAllModifiers(source: source, hostPid: hostPid, interCharDelayMicros: interCharDelayMicros) }
        // Clear any modifier a previous (possibly interrupted) injection may
        // have left held BEFORE we type a single character.
        postReleaseAllModifiers(source: source, hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)

        var bytes = 0
        for ch in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                trace.emit("inject", "degraded reason=event_creation_failed host=\(bundleID)")
                throw InjectError.eventCreationFailed
            }
            // Explicitly zero the flags so a character key can never inherit a
            // modifier from any earlier event in the system's keyboard state.
            keyDown.flags = []
            keyUp.flags = []
            var c = UniChar(ch.value)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            keyDown.postToPid(hostPid)
            usleep(interCharDelayMicros)
            keyUp.postToPid(hostPid)
            usleep(interCharDelayMicros / 3)
            bytes += String(ch).utf8.count
        }
        // Submit gate. Press Return ONLY when the composer was confirmed empty
        // (`.typeAndSubmit`). On `.typeNoSubmit` (composer unreadable) we leave
        // the answer staged so a draft we couldn't see is never auto-submitted.
        // SUPERVISOR_INJECT_NO_SUBMIT still forces no-submit for on-screen
        // verification, symmetric with the Electron paste path.
        let envNoSubmit = ProcessInfo.processInfo.environment["SUPERVISOR_INJECT_NO_SUBMIT"] != nil
        if decision == .typeAndSubmit && !envNoSubmit {
            // Return is a no-modifier chord; postChord brackets it with the
            // release-all guards too, so even the submit can't strand a key.
            postChord(source: source, virtualKey: 36, modifiers: [], hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)
        } else {
            trace.emit("inject", "terminal_staged_no_submit reason=\(envNoSubmit ? "env_no_submit" : "composer_unknown") host=\(bundleID) bytes=\(bytes)")
        }
        return bytes
    }

    /// Test seam: the submit decision the terminal path would take for
    /// `hostPid`, using THIS injector's wired composer probe. Posts nothing —
    /// lets a test prove the injector consults its probe and gates the submit.
    func terminalSubmitDecisionForTest(hostPid: pid_t, bundleID: String) -> TerminalSubmitDecision {
        Self.terminalSubmitDecision(composerEmpty: composerProbe.inputLineIsEmpty(hostPid: hostPid, bundleID: bundleID))
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

        let hostBundle = hostApp.bundleIdentifier ?? "?"
        guard hostApp.activate(options: []) else {
            restoreClipboard(savedClipboard, pasteboard)
            trace.emit("inject", "degraded reason=host_activate_failed host=\(hostBundle)")
            throw InjectError.targetUnresolvable(reason: "host_activate_failed")
        }
        try? await Task.sleep(nanoseconds: focusSettleNanos)

        let source = CGEventSource(stateID: .hidSystemState)
        // Each chord brackets itself with release-all guards (see postChord), so
        // the Cmd of the Cmd-V paste is always released before Return is posted
        //, the modifier can never strand into a Cmd+Return or, worse, a Cmd+Tab.
        Self.postChord(source: source, virtualKey: 9, modifiers: [.command], hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)  // Cmd-V (paste)
        usleep(interCharDelayMicros * 2)
        // SUPERVISOR_INJECT_NO_SUBMIT lets a verification run paste WITHOUT
        // submitting (so an on-screen test doesn't fire a real message).
        // Unset in production, the Return submits the answer/dispatch.
        if ProcessInfo.processInfo.environment["SUPERVISOR_INJECT_NO_SUBMIT"] == nil {
            Self.postChord(source: source, virtualKey: 36, modifiers: [], hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)      // Return
        }
        try? await Task.sleep(nanoseconds: focusSettleNanos / 2)

        restoreClipboard(savedClipboard, pasteboard)
        prior?.activate(options: [])

        trace.emit("inject", "fired method=foreground_paste host=\(hostBundle) host_pid=\(hostPid) bytes=\(text.utf8.count) restored=\(prior?.bundleIdentifier ?? "?")")
        return text.utf8.count
    }

    private func restoreClipboard(_ saved: String?, _ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    /// Paste `text` into the already-frontmost app via Cmd-V (+ Return unless
    /// SUPERVISOR_INJECT_NO_SUBMIT). Used after the desktop targeter has brought
    /// the target Claude conversation to the front, so we DON'T re-activate or
    /// restore here, the caller manages focus restore to the owner's prior app.
    /// Saves and restores the clipboard.
    private func pasteIntoFrontmost(text: String, hostPid: pid_t) -> Int {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .hidSystemState)
        // Cmd-V then Return as two self-closing chords (see postChord): the
        // paste's Command is released before Return, so nothing strands.
        Self.postChord(source: source, virtualKey: 9, modifiers: [.command], hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)  // Cmd-V
        usleep(interCharDelayMicros * 2)
        if ProcessInfo.processInfo.environment["SUPERVISOR_INJECT_NO_SUBMIT"] == nil {
            Self.postChord(source: source, virtualKey: 36, modifiers: [], hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)      // Return
        }
        usleep(interCharDelayMicros)
        restoreClipboard(saved, pasteboard)
        return text.utf8.count
    }

    /// Post a single key chord (key + held modifiers) targeted to a pid.
    ///
    /// Modifier-safe by construction (the crash/keyboard-hijack fix): the chord
    /// is expanded by the pure `KeyEventSequence.chord` builder into an explicit
    /// press-modifiers -> tap-key -> release-modifiers sequence, BRACKETED by a
    /// "release all modifiers" guard on both ends. So:
    ///   - every modifier this chord presses is explicitly released (the old
    ///     code set the modifier flag on the key-up but never released the
    ///     modifier itself, leaving e.g. Command latched),
    ///   - a modifier stranded by a PRIOR interrupted injection is cleared
    ///     before this chord taps its key, and
    ///   - nothing is left held afterward even if posting is interrupted.
    /// The Cmd+Tab combination is refused at the builder level so an injection
    /// can never drive the macOS app switcher.
    nonisolated private static func postChord(source: CGEventSource?, virtualKey: CGKeyCode, modifiers: [SyntheticModifier], hostPid: pid_t, interCharDelayMicros: useconds_t) {
        postSequence(KeyEventSequence.chord(virtualKey: virtualKey, modifiers: modifiers), source: source, hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)
    }

    /// Post key-up events for every modifier (Command, Option, Control, Shift)
    /// with a draining flag mask, so none is left held. The explicit guard the
    /// task calls for: run it before AND after any injection sequence so a
    /// modifier is never stranded, even across a previously interrupted
    /// injection. Cheap and idempotent: releasing an already-up modifier is a
    /// harmless no-op at the window-server level.
    nonisolated private static func postReleaseAllModifiers(source: CGEventSource?, hostPid: pid_t, interCharDelayMicros: useconds_t) {
        postSequence(KeyEventSequence.releaseAllModifiers(), source: source, hostPid: hostPid, interCharDelayMicros: interCharDelayMicros)
    }

    /// Low-level poster: turn each pure `KeyEvent` into a real CGEvent, set its
    /// flags EXACTLY (never inheriting from a previous event), and post it to
    /// the target pid. The single choke point where the tested event sequence
    /// becomes live keystrokes.
    nonisolated private static func postSequence(_ events: [KeyEvent], source: CGEventSource?, hostPid: pid_t, interCharDelayMicros: useconds_t) {
        for ev in events {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: ev.virtualKey, keyDown: ev.keyDown) else { continue }
            // Set flags explicitly on EVERY event so a modifier bit can never
            // leak from one event into the next.
            cg.flags = ev.flags
            cg.postToPid(hostPid)
            usleep(interCharDelayMicros)
        }
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
        // Use sysctl(KERN_PROC_PID), NOT proc_pidinfo(PROC_PIDTBSDINFO):
        // proc_pidinfo FAILS on root-owned processes in the chain, notably
        // `login`, which sits between a terminal's shell and Terminal.app, so
        // the old walk gave up at `login` and returned noHostingApp for EVERY
        // terminal-hosted claude session. sysctl reads kinfo_proc for any
        // process regardless of owner. (Confirmed 2026-06-07: claude→zsh→login
        // →Terminal.app; proc_pidinfo broke at login, sysctl walked through.)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = pid_t(kp.kp_eproc.e_ppid)
        return ppid > 0 ? ppid : nil
    }

    /// Best-effort: select the terminal TAB hosting the claude session (matched
    /// by its controlling tty) so the activate+post lands in the RIGHT session,
    /// not whatever tab the owner last touched. No-op on unsupported terminals
    /// or AppleScript/Automation failure, the caller still posts into the
    /// currently-selected tab, so this only ADDS targeting, never breaks it.
    static func selectTerminalTab(forClaudePID pid: pid_t, hostBundleID: String, trace: TraceLog) {
        guard let tty = ttyPath(of: pid) else {
            trace.emit("inject", "terminal_tab_select skip reason=no_tty pid=\(pid)")
            return
        }
        let script: String
        switch hostBundleID {
        case "com.apple.Terminal":
            script = #"""
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if (tty of t) is "\#(tty)" then
                      set selected of t to true
                      return "ok"
                    end if
                  end try
                end repeat
              end repeat
            end tell
            return "no_match"
            """#
        case "com.googlecode.iterm2":
            script = #"""
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    try
                      if (tty of s) is "\#(tty)" then
                        select t
                        return "ok"
                      end if
                    end try
                  end repeat
                end repeat
              end repeat
            end tell
            return "no_match"
            """#
        default:
            trace.emit("inject", "terminal_tab_select skip reason=unsupported_host=\(hostBundleID) tty=\(tty)")
            return
        }
        var errInfo: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&errInfo)
        trace.emit("inject", "terminal_tab_select tty=\(tty) host=\(hostBundleID) result=\(out?.stringValue ?? "nil")\(errInfo == nil ? "" : " err=\(errInfo!)")")
    }

    /// Controlling-terminal device path for `pid`, e.g. "/dev/ttys000", via
    /// kinfo_proc.kp_eproc.e_tdev. nil if the process has no controlling tty.
    static func ttyPath(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kp.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
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

    public func inject(text rawText: String, claudeCodePID: pid_t, targetWindowTitle: String? = nil) async throws -> Int {
        // Mirror the production injector's choke-point seam so tests exercise the
        // SAME boundary: whatever a caller hands the injector passes through
        // `wrap` here, idempotently. Per the no-stamp decision `wrap` is a clean
        // passthrough, so the recorded text and the injected text match exactly
        // (ledger correlation stays intact).
        let text = SupervisorInjectionMarker.wrap(rawText)
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
