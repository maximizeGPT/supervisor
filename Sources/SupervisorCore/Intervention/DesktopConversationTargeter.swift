// DesktopConversationTargeter.swift — desktop (Claude.app) conversation
// targeting via screenshot + on-device OCR (+ optional vision model) + click.
//
// The Claude desktop app is one Electron window whose Accessibility tree is
// opaque: a single featureless AXGroup, no per-conversation handle, window
// titles all just "Claude". So we cannot address a specific conversation
// through AX. Instead we do what a human does: look at the sidebar, find the
// conversation whose title matches the one we need to answer, click it to make
// it active, confirm it switched, THEN type.
//
// Two transcription paths (a session's identity is its `ai-title` from the
// JSONL):
//   Path B (default, free, on-device): screencapture -> Vision OCR -> a list of
//     (title, screen-point) candidates + the active conversation read from the
//     title bar. A text model (or local fuzzy match) picks the candidate that
//     matches the target title. Works with ANY provider, including text-only
//     ones like deepseek — that's the whole point: no image ever leaves the box.
//   Path A (when the configured vision provider has a vision model): send the
//     screenshot image to that model and let it return the target's coordinates.
//
// Verified on screen 2026-06-08: OCR read the full sidebar with coordinates,
// the coordinate scale is 1:1, and clicking an OCR'd coordinate switched the
// active conversation (title bar changed to the clicked conversation).
//
// HARD RULE (owner-set): confident-match-or-notify. A wrong-conversation inject
// is a failure equal to the cross-session bleed. If the match isn't confident,
// or the switch can't be verified, we DO NOT click-and-guess — we return a
// targeting failure so the router degrades to a logged notify.

import Foundation
import CoreGraphics
import Vision
import AppKit

/// One conversation candidate recognised on screen: its OCR'd text and the
/// screen point to click to open it.
public struct DesktopConversationCandidate: Sendable, Equatable {
    public let text: String
    public let point: CGPoint
}

/// Result of trying to focus a target conversation.
public enum DesktopTargetingOutcome: Sendable, Equatable {
    /// The target was found, clicked, and the switch verified. Safe to inject.
    case focused(matchedTitle: String)
    /// No confident match (target not in the visible sidebar, ambiguous, or the
    /// switch didn't verify). Caller must degrade to a LOGGED notify, never blind-paste.
    case targetingFailed(reason: String)
    /// Screen Recording permission is missing — can't screenshot. Caller surfaces
    /// the one-time grant prompt; never a silent degrade.
    case screenRecordingDenied
}

public struct DesktopConversationTargeter {

    private let trace: TraceLog
    public init(trace: TraceLog = .shared) { self.trace = trace }

    // MARK: - Screen capture

    /// True if Screen Recording (TCC) is granted. Does not prompt.
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Capture the full main display as a CGImage. We capture the whole display
    /// (not just the Claude window) so OCR'd coordinates are already global
    /// screen points — the scale is 1:1 on the verified setup, and clicking
    /// expects global points. Returns nil if capture fails (no permission, etc.).
    public func captureMainDisplay() -> CGImage? {
        CGDisplayCreateImage(CGMainDisplayID())
    }

    // MARK: - OCR (Path B transcription)

    /// Run on-device text recognition over `image` and return every recognised
    /// row as (text, center-screen-point). Coordinates are converted from
    /// Vision's normalised bottom-left space to top-left screen points using the
    /// main display's logical size (1:1 with the captured pixels on the
    /// verified setup; we scale defensively in case of HiDPI).
    public func recognizeRows(in image: CGImage) -> [(text: String, point: CGPoint)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch {
            trace.emit("desktop", "ocr_failed error=\(error)")
            return []
        }
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let screen = CGDisplayBounds(CGMainDisplayID())
        let sx = screen.width / imgW, sy = screen.height / imgH
        var rows: [(String, CGPoint)] = []
        for obs in (req.results ?? []) {
            guard let top = obs.topCandidates(1).first else { continue }
            let bb = obs.boundingBox  // normalised, origin bottom-left
            let x = bb.midX * imgW * sx
            let y = (1 - bb.midY) * imgH * sy  // flip to top-left origin
            rows.append((top.string, CGPoint(x: x, y: y)))
        }
        return rows
    }

    /// Filter recognised rows to the sidebar conversation list. The sidebar is
    /// the left column; conversation rows sit below the "Recents" header and to
    /// the left of the main pane. Best-effort heuristic, refined by the matcher.
    public func sidebarCandidates(from rows: [(text: String, point: CGPoint)]) -> [DesktopConversationCandidate] {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let leftEdge = screen.width * 0.30   // sidebar is the left ~30%
        var started = false
        var out: [DesktopConversationCandidate] = []
        for row in rows where row.point.x < leftEdge {
            // Conversation list begins after the "Recents" header.
            if !started {
                if row.text.localizedCaseInsensitiveContains("Recent") { started = true }
                continue
            }
            let cleaned = Self.cleanTitle(row.text)
            guard cleaned.count >= 3 else { continue }
            out.append(.init(text: cleaned, point: row.point))
        }
        return out
    }

    /// The conversation currently open, read from the window title bar (top
    /// strip, shaped "branch / Conversation Title"). We key on the "/" pattern
    /// — NOT just the longest top row — because the top strip also contains tab
    /// labels and sidebar rows that can be longer; keying on "/" reliably picks
    /// the title bar. nil if not found.
    public func activeConversationTitle(from rows: [(text: String, point: CGPoint)]) -> String? {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let topRows = rows.filter { $0.point.y < screen.height * 0.055 }
        // Prefer the "branch / title" row; fall back to the longest centered row.
        let bar = topRows.filter { $0.text.contains("/") }.max(by: { $0.text.count < $1.text.count })
            ?? topRows.filter { $0.point.x > screen.width * 0.20 }.max(by: { $0.text.count < $1.text.count })
        guard let bar else { return nil }
        let parts = bar.text.components(separatedBy: "/")
        let tail = (parts.count > 1 ? parts.dropFirst().joined(separator: "/") : bar.text)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ~›•-"))
        return Self.cleanTitle(tail)
    }

    /// Strip leading bullets / icon glyphs and trailing ellipses OCR picks up.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading non-alphanumeric glyph cluster (•, <>, icons OCR'd as letters+space).
        while let first = s.first, "•·.<>&+✗⏵ ".contains(first) { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        // Drop a trailing ellipsis the sidebar uses for truncation.
        while s.hasSuffix(".") || s.hasSuffix("…") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Click

    /// Click at a global screen point (left button). Used to focus the matched
    /// conversation. The host app must be frontmost for the click to land in it;
    /// the caller activates Claude.app first.
    public func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: - Orchestration

    /// Bring the target conversation to the front: screenshot, read the sidebar,
    /// match `targetTitle`, click, and VERIFY the switch before returning
    /// `.focused`. confident-match-or-notify: anything short of a verified match
    /// returns `.targetingFailed` so the caller degrades to a logged notify
    /// (never a blind paste into the wrong conversation).
    ///
    /// `confidenceThreshold` is the floor for the (local fuzzy or LLM) match.
    /// `matcher` lets the integration swap the local matcher for an LLM one
    /// (Path A vision / Path B text); the default is the on-device fuzzy match.
    public func focusConversation(
        targetTitle: String,
        confidenceThreshold: Double = 0.6,
        matcher: (([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)?)? = nil
    ) -> DesktopTargetingOutcome {
        guard Self.hasScreenRecordingPermission() else {
            trace.emit("desktop", "targeting screen_recording_denied")
            return .screenRecordingDenied
        }
        activateClaudeApp()
        usleep(500_000)
        guard let img = captureMainDisplay() else {
            return .targetingFailed(reason: "capture_failed")
        }
        let rows = recognizeRows(in: img)
        let candidates = sidebarCandidates(from: rows)
        let active = activeConversationTitle(from: rows)
        trace.emit("desktop", "targeting ocr active=\"\(active ?? "?")\" candidates=\(candidates.count) target=\"\(targetTitle.prefix(50))\"")

        if let active, Self.titlesMatch(active, targetTitle) {
            trace.emit("desktop", "targeting already_active title=\"\(active)\"")
            return .focused(matchedTitle: active)
        }
        let match = (matcher ?? { c, t in self.bestMatch(target: t, candidates: c) })(candidates, targetTitle)
        guard let (cand, confidence) = match else {
            return .targetingFailed(reason: "no_candidate_match candidates=\(candidates.count) target=\"\(targetTitle.prefix(40))\"")
        }
        guard confidence >= confidenceThreshold else {
            return .targetingFailed(reason: "low_confidence=\(String(format: "%.2f", confidence)) best=\"\(cand.text.prefix(40))\" target=\"\(targetTitle.prefix(40))\"")
        }
        trace.emit("desktop", "targeting click match=\"\(cand.text)\" conf=\(String(format: "%.2f", confidence)) at=(\(Int(cand.point.x)),\(Int(cand.point.y)))")
        click(at: cand.point)

        let screen = CGDisplayBounds(CGMainDisplayID())
        // Poll for the switch: the title bar (top strip) should come to show the
        // clicked conversation. The bar re-renders a beat after the click, so a
        // single-shot read can catch it stale — poll up to ~3.2s. We check that
        // the CLICKED title now appears up top (substring/high-score), which is
        // robust to the "branch / title" framing.
        let needle = Self.normalize(cand.text)
        let topY = screen.height * 0.055, leftX = screen.width * 0.18
        for attempt in 0..<8 {
            usleep(400_000)
            guard let v = captureMainDisplay() else { continue }
            let top = recognizeRows(in: v).filter { $0.point.y < topY && $0.point.x > leftX }
            let hit = top.contains { row in
                let n = Self.normalize(row.text)
                return n.contains(needle) || Self.score(n, needle) > 0.6
            }
            if hit {
                trace.emit("desktop", "targeting switch_verified attempt=\(attempt) title=\"\(cand.text.prefix(40))\"")
                return .focused(matchedTitle: cand.text)
            }
        }
        // Clicked but the title bar never came to show the target — do NOT type.
        // Bleed guard: a wrong/unconfirmed switch must never lead to a paste.
        return .targetingFailed(reason: "switch_not_verified clicked=\"\(cand.text.prefix(30))\"")
    }

    /// Local fuzzy matcher (Path B default): the sidebar entry whose OCR'd
    /// (often truncated) title best matches the target ai-title.
    public func bestMatch(target: String, candidates: [DesktopConversationCandidate]) -> (DesktopConversationCandidate, Double)? {
        let t = Self.normalize(target)
        var best: (DesktopConversationCandidate, Double)?
        for c in candidates {
            let s = Self.score(Self.normalize(c.text), t)
            if best == nil || s > best!.1 { best = (c, s) }
        }
        return best
    }

    private func activateClaudeApp() {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == "com.anthropic.claudefordesktop" {
            app.activate(options: [])
            return
        }
    }

    // MARK: - String matching

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 0..1 similarity. The sidebar truncates titles, so a prefix relationship
    /// (one is the start of the other) scores high; otherwise token overlap.
    static func score(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        if longer.hasPrefix(shorter) {
            return 0.5 + 0.5 * (Double(shorter.count) / Double(longer.count))
        }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let inter = ta.intersection(tb).count, uni = ta.union(tb).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    /// True if two titles plausibly refer to the same conversation (used for the
    /// already-active check and switch verification). Requires a real prefix
    /// overlap of at least 6 chars to avoid matching short shared words.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        return longer.hasPrefix(shorter) && shorter.count >= 6
    }

    // MARK: - ai-title (the conversation's identity)

    /// Read a session's `ai-title` — the conversation title Claude shows in the
    /// desktop sidebar — from its JSONL transcript. This is the identity we
    /// match a desktop conversation on. Searches the standard projects dir for
    /// `<sessionId>.jsonl`; returns the LAST ai-title (titles can be revised).
    /// nil if the file or an ai-title event isn't found.
    public static func readAiTitle(
        sessionId: String,
        projectsDir: URL? = nil
    ) -> String? {
        let base = projectsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return nil }
        for proj in projects {
            let jsonl = proj.appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: jsonl.path),
                  let text = try? String(contentsOf: jsonl, encoding: .utf8) else { continue }
            var title: String?
            text.enumerateLines { line, _ in
                guard line.contains("\"ai-title\"") || line.contains("\"aiTitle\"") else { return }
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let t = obj["aiTitle"] as? String, !t.isEmpty {
                    title = t
                }
            }
            if let title { return title }
        }
        return nil
    }
}
