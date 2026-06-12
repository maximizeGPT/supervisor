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

    public init(text: String, point: CGPoint) {
        self.text = text
        self.point = point
    }
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

public struct DesktopConversationTargeter: @unchecked Sendable {

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
    public func sidebarCandidates(
        from rows: [(text: String, point: CGPoint)],
        screen: CGRect = CGDisplayBounds(CGMainDisplayID())
    ) -> [DesktopConversationCandidate] {
        // The sidebar is a narrow LEFT COLUMN. The old "left 30%" bound
        // (x < 0.30*W) was fine for one window but in a multi-window layout it
        // swallowed the NEIGHBOR window's body text (x~360-540 on a 1920 screen)
        // as fake conversation candidates — ocr-dump showed 42 candidates, ~24
        // of them neighbor-window prose. So don't bound by a width fraction;
        // isolate the real sidebar by its x-COLUMN: conversation titles are
        // left-aligned at one consistent x and form the densest left-side
        // column, while a neighbor window's text sits in a different, sparser
        // x-spread. Cluster rows by left-x, keep only the densest column. This
        // is independent of how the windows are arranged.

        // Conversation list sits at/below the "Recents" header; anything above
        // it (nav rail, search) and the account footer is not a conversation.
        let recentsY = rows.first {
            $0.text.localizedCaseInsensitiveContains("Recent") && $0.point.x < screen.width * 0.40
        }?.point.y ?? 0

        let region = rows.filter {
            $0.point.x < screen.width * 0.40
                && $0.point.y >= recentsY
                && !$0.text.localizedCaseInsensitiveContains("Recent")
                && Self.cleanTitle($0.text).count >= 3
        }
        guard !region.isEmpty else { return [] }

        // Bucket by left-x (~50px) and take the LEFTMOST column that has at
        // least a few rows. The sidebar is structurally the leftmost column;
        // conversation BODY panes are always to its right, even when a pane's
        // prose is denser than the sidebar (a draft-tweet pane with 29 rows beat
        // the 18-row sidebar under the old "densest column" rule). Requiring a
        // minimum row count skips the sparse account footer; taking the leftmost
        // qualifying column — not the densest — locks onto the sidebar. When the
        // sidebar isn't on screen this yields [] -> safe notify, never body prose.
        let bucketW = 50.0
        let minColumnRows = 4
        var counts: [Int: Int] = [:]
        for r in region { counts[Int(r.point.x / bucketW), default: 0] += 1 }
        guard let sidebarBucket = counts.filter({ $0.value >= minColumnRows }).keys.min() else { return [] }
        let center = (Double(sidebarBucket) + 0.5) * bucketW
        let tolerance = 55.0

        return region
            .filter { abs($0.point.x - center) <= tolerance }
            .map { .init(text: Self.cleanTitle($0.text), point: $0.point) }
    }

    /// The conversation currently open, read from the window title bar (top
    /// strip, shaped "branch / Conversation Title"). We key on the "/" pattern
    /// — NOT just the longest top row — because the top strip also contains tab
    /// labels and sidebar rows that can be longer; keying on "/" reliably picks
    /// the title bar. nil if not found.
    public func activeConversationTitle(from rows: [(text: String, point: CGPoint)]) -> String? {
        visibleConversationTitles(from: rows).first
    }

    /// Every conversation title bar visible in the top strip, as title tails
    /// ("project / Title" -> "Title"), longest-first — one per open Claude
    /// window in a multi-window layout. Keys on " / " (slash with surrounding
    /// spaces), so it never mistakes a filesystem path ("/Users/main/…") or the
    /// menu-bar clock ("Wed Jun 10 6:13 AM") for a title. Returns [] when no
    /// title bar is readable; callers must NOT fall back to a random top row —
    /// the old "longest centered row" fallback is what grabbed the clock.
    public func visibleConversationTitles(
        from rows: [(text: String, point: CGPoint)],
        screen: CGRect = CGDisplayBounds(CGMainDisplayID())
    ) -> [String] {
        let decorations = CharacterSet(charactersIn: " ~›•-")
        return rows
            .filter { $0.point.y < screen.height * 0.055 && $0.text.contains(" / ") }
            .compactMap { row -> String? in
                let tail = row.text
                    .components(separatedBy: " / ")
                    .dropFirst()
                    .joined(separator: " / ")
                    .trimmingCharacters(in: decorations)
                let cleaned = Self.cleanTitle(tail)
                return cleaned.count >= 3 ? cleaned : nil
            }
            .sorted { $0.count > $1.count }
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
        let titles = visibleConversationTitles(from: rows)
        trace.emit("desktop", "targeting ocr windows=\(titles.count) candidates=\(candidates.count) target=\"\(targetTitle.prefix(50))\"")

        // Already-active shortcut, but ONLY with exactly one visible window.
        // With 2+ windows a matching title bar may not be the FRONTMOST one a
        // paste would land in, so fall through to click+verify, which
        // disambiguates by actually focusing the target and confirming it.
        if titles.count == 1, Self.titlesMatch(titles[0], targetTitle) {
            trace.emit("desktop", "targeting already_active title=\"\(titles[0])\"")
            return .focused(matchedTitle: titles[0])
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
        // clicked conversation. Match by SHARED-TOKEN OVERLAP, not substring: the
        // title bar's text form routinely differs from BOTH the clicked sidebar
        // text and the ai-title -- reworded, reordered ("Loop engineering
        // accessibility" vs "Accessibility of loop engineering"), truncated, or
        // OCR-merged with a neighbor window's bar. The old substring/Jaccard
        // check on the clicked text alone false-negatived on exactly that: a
        // verified-0.95 match degraded at switch_not_verified. So confirm each
        // top row against BOTH the clicked candidate AND the target, order-
        // independent, requiring several shared tokens (bleed guard).
        // IDENTITY GUARD: the post-click title must match the INTENDED target
        // ai-title -- NOT merely the clicked candidate. Confirming against the
        // clicked text is exactly what let a wrong match BLEED: the matcher
        // clicked "Supervisor macOS app signing" for target "Ship pause and kill
        // interventions" at 0.95, the title bar showed that wrong title, and a
        // clicked-text check happily "verified" it and typed there. Token
        // overlap (order-independent) still passes a reworded/truncated form of
        // the RIGHT title; a genuinely different conversation fails the guard
        // -> .targetingFailed -> notify, never a paste into the wrong chat.
        let targetTokens = Self.titleTokens(targetTitle)
        let topY = screen.height * 0.055, leftX = screen.width * 0.18
        for attempt in 0..<8 {
            usleep(400_000)
            guard let v = captureMainDisplay() else { continue }
            let top = recognizeRows(in: v).filter { $0.point.y < topY && $0.point.x > leftX }
            let hit = top.contains { row in
                Self.tokensConfirmSwitch(Self.titleTokens(row.text), targetTokens)
            }
            if hit {
                trace.emit("desktop", "targeting switch_verified attempt=\(attempt) target=\"\(targetTitle.prefix(40))\"")
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
        // focusConversation runs OFF the main actor (it blocks ~4s and must not
        // freeze the UI / the @MainActor triage engine), but NSWorkspace
        // activation is an AppKit call that belongs on the main thread. Hop
        // there non-blocking; the caller's settle-sleep covers the async gap.
        let work = {
            for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier == "com.anthropic.claudefordesktop" {
                app.activate(options: [])
                return
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
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

    /// Lowercased word tokens (>= 3 chars) for order-independent title matching.
    /// Splits on any non-alphanumeric so "/", bullets, and close-button glyphs
    /// the OCR picks up don't fuse into tokens.
    static func titleTokens(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    /// True when an OCR'd top-strip row shares enough tokens with a title to
    /// confirm a post-click switch — robust to reordering, truncation, and a row
    /// that OCR-merged several windows' title bars. Requires >= 2 shared tokens
    /// AND a solid majority of the smaller token set, so a short unrelated title
    /// (or an incidental token overlap) can't false-confirm and cause a paste
    /// into the wrong conversation.
    static func tokensConfirmSwitch(_ row: Set<String>, _ title: Set<String>) -> Bool {
        let shared = row.intersection(title).count
        let minCount = min(row.count, title.count)
        guard minCount >= 2, shared >= 2 else { return false }
        return Double(shared) / Double(minCount) >= 0.6
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
