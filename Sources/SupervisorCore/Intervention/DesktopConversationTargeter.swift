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
                && !Self.isSupervisorBannerText($0.text)  // never our own stamp
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
        visiblePaneTitles(from: rows, screen: screen).map(\.title)
    }

    /// Every visible conversation title bar WITH its on-screen position — one per
    /// pane in the side-by-side multi-pane layout. The x is the pane's column,
    /// used to focus that pane's composer. Same parsing as
    /// visibleConversationTitles (keys on " / ", strips chrome), longest-first.
    public func visiblePaneTitles(
        from rows: [(text: String, point: CGPoint)],
        screen: CGRect = CGDisplayBounds(CGMainDisplayID())
    ) -> [(title: String, point: CGPoint)] {
        let decorations = CharacterSet(charactersIn: " ~›•-")
        return rows
            .filter { $0.point.y < screen.height * 0.055 && $0.text.contains(" / ") }
            .filter { !Self.isSupervisorBannerText($0.text) }  // never our own stamp
            .compactMap { row -> (title: String, point: CGPoint)? in
                let tail = row.text
                    .components(separatedBy: " / ")
                    .dropFirst()
                    .joined(separator: " / ")
                    .trimmingCharacters(in: decorations)
                let cleaned = Self.cleanTitle(tail)
                return cleaned.count >= 3 ? (cleaned, row.point) : nil
            }
            .sorted { $0.title.count > $1.title.count }
    }

    /// Strip leading bullets / icon glyphs and trailing ellipses OCR picks up.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading non-alphanumeric glyph cluster (•, <>, icons OCR'd as letters+space).
        while let first = s.first, "•·.<>&+✗⏵ ".contains(first) { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        // Cut at a truncation ellipsis: the desktop truncates long titles with
        // "…"/"...", and OCR appends window-chrome glyphs (close-button "x", "~",
        // "•-") AFTER it — none of it title text. Drop everything from the
        // ellipsis on, leaving a clean prefix that still prefix-matches the full
        // target title (e.g. "Unit tests for eval harness mo…•~ x" -> "Unit tests
        // for eval harness mo", which prefix-matches "Unit tests for eval harness
        // modules").
        if let r = s.range(of: "…") ?? s.range(of: "...") {
            s = String(s[..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // Drop trailing decoration glyphs (NOT letters — a real trailing "x" is
        // only ever window chrome after an ellipsis, already handled above).
        while let last = s.last, "•·~-–—✗⏵<>…. ".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// True if an OCR'd row is Supervisor's OWN injected banner/stamp, not a real
    /// conversation. The matcher kept picking the stamp text as the best
    /// candidate (conf=0.95 title="[ SUPERVISOR • automated - NOT from your
    /// operator ]"), wasting scroll attempts and risking self-targeting. The
    /// in-text banner was removed from NEW injections (see
    /// SupervisorInjectionMarker), but OLD turns still on screen keep showing it,
    /// so the targeter must filter it regardless.
    ///
    /// Matches on the three distinctive tokens that survive OCR ("supervisor",
    /// "automated", and the phrase "not from your operator"), case-insensitive
    /// and independent of the bracket glyphs (separators the OCR renders
    /// variably). Requiring all three together keeps it specific enough to never
    /// match a real conversation title.
    static func isSupervisorBannerText(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("supervisor")
            && lower.contains("automated")
            && lower.contains("not from your operator")
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

    /// Scroll the conversation sidebar (left column) to reveal off-screen
    /// conversations during scroll-to-find. `toTop: true` jumps to the top of
    /// the list with a strong upward scroll; otherwise it nudges one view down.
    /// The cursor is parked over the sidebar first so the wheel events target
    /// it, not the conversation pane. Scroll convention: positive wheel1 scrolls
    /// up (toward the top of the list), negative scrolls down.
    public func scrollSidebar(toTop: Bool) {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let src = CGEventSource(stateID: .hidSystemState)
        let hover = CGPoint(x: screen.width * 0.10, y: screen.height * 0.45)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: hover, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        // +up = toward top (large, to reach the top); -down = a partial page so
        // successive views overlap (the target can't fall between two scrolls).
        let bursts = toTop ? 14 : 3
        let lines: Int32 = toTop ? 6 : -5
        for _ in 0..<bursts {
            CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
    }

    // MARK: - Composer focus (Piece 1, owner-directed 2026-06-13)

    /// Locate the click point of the conversation's composer (the text input
    /// strip across the bottom of the main pane) from OCR rows.
    ///
    /// Why this exists: the targeting arc reliably lands on the right
    /// CONVERSATION, but landing on the conversation is not the same as the
    /// composer having keyboard focus. An already-active conversation never gets
    /// a sidebar click, and even a freshly switched one can leave focus off the
    /// input — so the subsequent Cmd-V vanishes and the turn-confirmation poll
    /// degrades to a banner (the live `paste_no_turn_landed` miss). Clicking the
    /// composer first gives it focus so the paste lands on the first attempt.
    ///
    /// Primary anchor: the composer placeholder ("Type / for commands", "Reply
    /// to Claude", …) in the bottom band — the exact on-screen element, robust
    /// to screen size. Fallback when the composer already holds text (no
    /// placeholder): a point just above the bottommost band row (the account/
    /// model footer), at the pane's horizontal center, so the click lands in the
    /// input rather than on a footer control. nil only when there's nothing in
    /// the bottom band to anchor on (caller then skips the focus click and the
    /// paste falls back to whatever has focus — today's behavior, never worse).
    /// `nearX`: the x-column of the TARGET conversation's window (its matched
    /// title bar). When several Claude windows are tiled, the bottom band holds
    /// several composers; without this the picker grabbed the leftmost/topmost
    /// one and pasted into the WRONG window (the 2026-06-14 multi-window mispick:
    /// clicked x=408 for a conversation whose composer was at ~1018). With it,
    /// the picker chooses the composer in the target window's column. nil =
    /// single-window / unknown → the original topmost-placeholder behavior.
    public func composerPoint(
        from rows: [(text: String, point: CGPoint)],
        screen: CGRect = CGDisplayBounds(CGMainDisplayID()),
        nearX: CGFloat? = nil
    ) -> CGPoint? {
        let bandTop = screen.height * 0.82
        let bottom = rows.filter { $0.point.y >= bandTop }
        guard !bottom.isEmpty else { return nil }

        let hints = ["type /", "for commands", "reply to claude",
                     "message claude", "ask claude", "how can i help"]
        let placeholders = bottom.filter { r in hints.contains { r.text.lowercased().contains($0) } }
        // Column tolerance for "same pane as nearX". A composer must sit within
        // the verified pane's column to be that pane's composer; anything farther
        // belongs to a NEIGHBOR pane. Bound it to a pane half-width so a
        // composer in the target column is accepted but a different pane's (e.g.
        // x=953 when nearX=407, the 2026-06-14 cross-pane mispick) is rejected.
        let columnTolerance = screen.width * 0.22
        if !placeholders.isEmpty {
            if let nearX {
                // Multi-window/pane: pick the composer in the TARGET pane's
                // column. Only accept a placeholder within the column tolerance of
                // nearX; if the target pane's own placeholder wasn't OCR'd, do NOT
                // grab a far-off neighbor's. Fall through to the nearX-column
                // click below (the verified title column at the composer band y).
                let inColumn = placeholders.filter { abs($0.point.x - nearX) <= columnTolerance }
                if let p = inColumn.min(by: { abs($0.point.x - nearX) < abs($1.point.x - nearX) }) {
                    return p.point
                }
            } else {
                // Single-window: original topmost-placeholder behavior.
                return placeholders.min { $0.point.y < $1.point.y }!.point
            }
        }

        // No placeholder (composer holds text), or none fell in the target
        // column. Click a touch above the lowest row (the footer). Prefer the
        // target column when known, else the pane center.
        let footY = bottom.map(\.point.y).max() ?? (screen.height * 0.95)
        let y = max(footY - screen.height * 0.04, bandTop)
        if let nearX { return CGPoint(x: nearX, y: y) }
        let paneRows = bottom.filter { $0.point.x > screen.width * 0.20 }
        let xs = (paneRows.isEmpty ? bottom : paneRows).map(\.point.x).sorted()
        let cx = xs.isEmpty ? screen.width * 0.45 : xs[xs.count / 2]
        return CGPoint(x: cx, y: y)
    }

    /// Screenshot the now-frontmost Claude window, locate the composer, and
    /// click it to give it keyboard focus before the caller pastes. Best-effort:
    /// a no-op (with a discriminating trace) if capture fails or the composer
    /// can't be located, so it never makes delivery worse than it is today.
    /// Runs on the targeting queue (the caller is already off-main).
    /// `nearX`: the target window's column (its title-bar x), so in a tiled
    /// multi-window layout the click lands on the TARGET conversation's composer,
    /// not a neighbor window's.
    public func focusComposer(nearX: CGFloat? = nil) {
        guard let img = captureMainDisplay() else {
            trace.emit("desktop", "composer_focus skip reason=capture_failed")
            return
        }
        let rows = recognizeRows(in: img)
        guard let pt = composerPoint(from: rows, nearX: nearX) else {
            trace.emit("desktop", "composer_focus skip reason=not_located rows=\(rows.count)")
            return
        }
        trace.emit("desktop", "composer_focus click at=(\(Int(pt.x)),\(Int(pt.y)))\(nearX.map { " nearX=\(Int($0))" } ?? "")")
        click(at: pt)
        usleep(150_000)  // let focus settle before the caller's paste
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
        let matcherFn = matcher ?? { c, t in self.bestMatch(target: t, candidates: c) }

        // Pass 1: the sidebar as currently shown (+ already-active shortcut).
        guard let img = captureMainDisplay() else {
            return .targetingFailed(reason: "capture_failed")
        }
        let rows = recognizeRows(in: img)
        let candidates = sidebarCandidates(from: rows)
        let titles = visibleConversationTitles(from: rows)
        trace.emit("desktop", "targeting ocr windows=\(titles.count) candidates=\(candidates.count) target=\"\(targetTitle.prefix(50))\"")

        // MULTI-PANE side-by-side layout: N panes each ALREADY showing a
        // conversation, with no sidebar list to click. The sidebar-find path
        // below is for the single-window-with-sidebar case and reads garbage here
        // (it scans for a conversation list that isn't on screen — the live
        // "only reacted to 1 of N" failure). Instead, match the target against
        // the visible PANE TITLES — which OCR reads cleanly, one per column — and
        // focus that pane's composer directly. The conversation is already
        // visible, so there's nothing to switch and nothing to verify beyond the
        // title match itself.
        let panes = visiblePaneTitles(from: rows)
        if panes.count > 1 {
            let paneCandidates = panes.map { DesktopConversationCandidate(text: $0.title, point: $0.point) }
            // Ambiguity guard: require an EXACT-unique title, or a clear-margin
            // winner. Two near-identical pane titles (the M8 collision) yield no
            // unique winner -> nil -> degrade to notify, instead of a guess.
            if let m = Self.resolveUniqueMatch(target: targetTitle, candidates: paneCandidates, threshold: confidenceThreshold, matcher: matcherFn, trace: trace) {
                trace.emit("desktop", "targeting pane_match panes=\(panes.count) match=\"\(m.candidate.text.prefix(30))\" conf=\(String(format: "%.2f", m.confidence)) exact=\(m.exact) x=\(Int(m.candidate.point.x))")
                focusComposer(nearX: m.candidate.point.x)
                return .focused(matchedTitle: m.candidate.text)
            }
            let considered = paneCandidates.map { "\"\($0.text.prefix(30))\"" }.joined(separator: ", ")
            trace.emit("desktop", "targeting pane_ambiguous_or_no_match panes=\(panes.count) target=\"\(targetTitle.prefix(40))\" candidates=[\(considered)]")
            return .targetingFailed(reason: "no_unique_pane_match panes=\(panes.count) target=\"\(targetTitle.prefix(40))\"")
        }

        // Already-active shortcut, but ONLY with exactly one visible window.
        if titles.count == 1, Self.titlesMatch(titles[0], targetTitle) {
            trace.emit("desktop", "targeting already_active title=\"\(titles[0])\"")
            // Already active = no sidebar click happened, so focus may be off
            // the input. Focus the composer in THIS window's column (the matched
            // title bar's x) before the caller pastes — so a partially-visible
            // neighbor window's composer in the band can't be grabbed instead.
            let titleX = rows.first {
                $0.point.y < CGDisplayBounds(CGMainDisplayID()).height * 0.055 && $0.text.contains(" / ")
            }?.point.x
            focusComposer(nearX: titleX)
            return .focused(matchedTitle: titles[0])
        }

        // Ambiguity guard (see resolveUniqueMatch): an exact-unique title, or a
        // clear-margin winner, otherwise nil, so two colliding sidebar titles
        // degrade to notify instead of a wrong-chat paste.
        var matched: (cand: DesktopConversationCandidate, conf: Double)?
        if let m = Self.resolveUniqueMatch(target: targetTitle, candidates: candidates, threshold: confidenceThreshold, matcher: matcherFn, trace: trace) {
            matched = (m.candidate, m.confidence)
        }

        // Pass 2 (scroll-to-find): the target wasn't confidently in the visible
        // sidebar -- it's scrolled off-screen. Jump to the top of the list and
        // scroll DOWN through it, re-matching each view, so an off-screen
        // conversation is FOUND instead of degrading straight to notify.
        // Bounded; stops when found or a scroll yields no new conversations
        // (end of list). The matched candidate's coordinates are from the view
        // it was found in, so the click below lands on its current position.
        if matched == nil {
            scrollSidebar(toTop: true)
            var seen = Set(candidates.map(\.text))
            for attempt in 0..<6 {
                usleep(350_000)
                guard let v = captureMainDisplay() else { break }
                let scrolled = sidebarCandidates(from: recognizeRows(in: v))
                if let m = Self.resolveUniqueMatch(target: targetTitle, candidates: scrolled, threshold: confidenceThreshold, matcher: matcherFn, trace: trace) {
                    trace.emit("desktop", "targeting found_after_scroll attempt=\(attempt) match=\"\(m.candidate.text.prefix(30))\" conf=\(String(format: "%.2f", m.confidence)) exact=\(m.exact)")
                    matched = (m.candidate, m.confidence); break
                }
                let fresh = scrolled.map(\.text).filter { !seen.contains($0) }
                if fresh.isEmpty {
                    trace.emit("desktop", "targeting scroll_end attempt=\(attempt) candidates=\(scrolled.count) (no new conversations)")
                    break
                }
                scrolled.forEach { seen.insert($0.text) }
                scrollSidebar(toTop: false)
            }
        }

        guard let (cand, confidence) = matched else {
            return .targetingFailed(reason: "not_found_after_scroll candidates=\(candidates.count) target=\"\(targetTitle.prefix(40))\"")
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
            let hitRow = top.first { row in
                Self.tokensConfirmSwitch(Self.titleTokens(row.text), targetTokens)
            }
            if let hitRow {
                trace.emit("desktop", "targeting switch_verified attempt=\(attempt) target=\"\(targetTitle.prefix(40))\" titleX=\(Int(hitRow.point.x))")
                // The sidebar click switched the conversation but may have left
                // focus on the sidebar; focus the composer in the MATCHED window's
                // column (its title-bar x) so a tiled neighbor window's composer
                // isn't grabbed instead.
                focusComposer(nearX: hitRow.point.x)
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

    /// Resolve the ONE candidate that uniquely IS the target, or return nil so
    /// the caller degrades to a notify. This is the ambiguity guard that stops a
    /// wrong-conversation inject when two titles collide (the M8 failure: an
    /// auto-dispatch for "Supervisor Product Launch Readiness" landed in
    /// "Supervisor Launch Readiness" because the fuzzy matcher just took the top
    /// score with no check that a second, structurally-different conversation
    /// also cleared the gate).
    ///
    /// Resolution order (most-specific identity first):
    ///   1. EXACT, UNIQUE title equality (normalized). If exactly one candidate's
    ///      title equals the target, that's the answer (no fuzzy guessing). If
    ///      TWO OR MORE candidates equal the target (genuine duplicates on
    ///      screen), it is ambiguous -> nil.
    ///   2. Otherwise fall to the scoring `matcher`, but apply a UNIQUENESS /
    ///      MARGIN guard: the top score must clear `threshold` AND beat the
    ///      runner-up by at least `margin`. A near-tie means two candidates are
    ///      both plausibly the target (exactly the collision case), so we refuse
    ///      to guess and return nil. Zero candidates -> nil.
    ///   3. IDENTITY FLOOR (the 2026-07-08 misroute fix): the WINNER'S OWN local
    ///      identity score must itself clear the threshold. The margin guard only
    ///      proves the winner beat the OTHER candidates — it does NOT prove the
    ///      winner actually resembles the target. When the matcher is the LLM
    ///      (Path A/B), `winnerScore` is the model's self-reported confidence,
    ///      which can be high for a candidate whose text bears NO real
    ///      relationship to the target (the live misroute: a dispatch for
    ///      "discussion" pasted into "memory/skill audit" — an overconfident LLM
    ///      pick whose local token/prefix overlap with the target is ~0). A wide
    ///      margin over unrelated runners-up let that slip the margin guard. So we
    ///      additionally require the winner's LOCAL score (its literal
    ///      cwd/title/session-identity overlap with the target) to clear
    ///      `threshold`. For the fuzzy default this is a no-op — its reported
    ///      confidence IS the local score, so `winnerScore >= threshold` already
    ///      implies `winnerLocal >= threshold`, and the confident path is
    ///      unchanged. It only bites the LLM path, degrading a confidently-picked
    ///      but textually-unrelated winner to notify instead of pasting it.
    ///
    /// nil is the safe outcome: the caller (focusConversation) turns it into a
    /// `.targetingFailed` that the injector degrades to a logged notify, never a
    /// blind paste into the wrong chat.
    ///
    /// `trace` (optional) logs the SPECIFIC degrade reason on a nil return so the
    /// recorded outcome is honest ("ambiguous margin" vs "winner identity below
    /// floor"). nil by default keeps existing callers/tests source-compatible.
    static func resolveUniqueMatch(
        target: String,
        candidates: [DesktopConversationCandidate],
        threshold: Double,
        margin: Double = 0.10,
        matcher: ([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)?,
        trace: TraceLog? = nil
    ) -> (candidate: DesktopConversationCandidate, confidence: Double, exact: Bool)? {
        guard !candidates.isEmpty else { return nil }

        // 1. Exact, UNIQUE normalized-title equality wins outright. Prefer the
        //    strongest identity available (full-title equality) over any
        //    substring/fuzzy score, per the safety rule.
        let t = normalize(target)
        let exactMatches = candidates.filter { normalize($0.text) == t }
        if exactMatches.count == 1 {
            return (exactMatches[0], 1.0, true)
        }
        if exactMatches.count > 1 {
            // Two on-screen conversations share the exact target title: we
            // cannot tell them apart, so do NOT inject.
            return nil
        }

        // 2. No exact match: fall to the scoring matcher, but never accept a top
        //    score that a runner-up sits right beside. Score EVERY candidate so
        //    we can measure the margin between the best and second-best (the
        //    matcher itself only hands back its single pick).
        guard let (winner, winnerScore) = matcher(candidates, target),
              winnerScore >= threshold else { return nil }

        // The runner-up is the highest-scoring OTHER candidate under the same
        // local scoring the matcher's confidence is comparable to. (We score all
        // candidates locally to get a stable, matcher-independent margin; the
        // winner's reported confidence still has to clear the threshold above.)
        let nt = t
        var runnerUp = 0.0
        for c in candidates where c != winner {
            runnerUp = max(runnerUp, score(normalize(c.text), nt))
        }
        let winnerLocal = score(normalize(winner.text), nt)
        if winnerLocal - runnerUp < margin {
            // Near-tie: a second conversation is just as plausibly the target.
            // The collision case -> refuse to guess.
            trace?.emit("desktop", "targeting degrade_to_notify reason=ambiguous_margin candidates=\(candidates.count) winnerLocal=\(String(format: "%.2f", winnerLocal)) runnerUp=\(String(format: "%.2f", runnerUp)) margin<\(String(format: "%.2f", margin)) target=\"\(target.prefix(40))\"")
            return nil
        }
        // Identity floor (2026-07-08 misroute fix): the winner must itself
        // resemble the target, not merely beat unrelated runners-up. A high
        // matcher confidence (an overconfident LLM pick) whose LOCAL identity
        // overlap with the target is below the gate is exactly the wrong-chat
        // paste we must never produce -> degrade to notify. No-op for the fuzzy
        // default (winnerLocal == winnerScore there).
        if winnerLocal < threshold {
            trace?.emit("desktop", "targeting degrade_to_notify reason=winner_identity_below_floor candidates=\(candidates.count) winner=\"\(winner.text.prefix(30))\" winnerScore=\(String(format: "%.2f", winnerScore)) winnerLocal=\(String(format: "%.2f", winnerLocal)) floor=\(String(format: "%.2f", threshold)) target=\"\(target.prefix(40))\"")
            return nil
        }
        return (winner, winnerScore, false)
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

    /// Read the LIVE conversation title Claude Desktop currently shows for a
    /// Claude Code session — the title in the sidebar and window title bar, which
    /// is the identity the OCR actually sees. Claude Desktop RENAMES a
    /// conversation as its content evolves (e.g. "Ship pause and kill
    /// interventions" became "The token-overlap verify fix ..."), but the
    /// `aiTitle` baked into the JSONL transcript stays frozen at the original.
    /// Targeting the frozen title aims at a name no longer on screen — it
    /// degrades to a banner (can't find it) or, worse, fuzzy-matches the wrong
    /// conversation. This reads the ground truth instead.
    ///
    /// Claude Desktop's `claude-code-sessions` store holds one JSON per session
    /// mapping `cliSessionId` (== our sessionId) to the live `title`. Returns nil
    /// if the store or a matching entry isn't found (caller falls back to the
    /// frozen aiTitle, then the branch).
    public static func readDesktopTitle(
        sessionId: String,
        storeDir: URL? = nil
    ) -> String? {
        let base = storeDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker {
            guard url.pathExtension == "json" else { continue }
            // Cheap prefilter: only parse files that even mention the sessionId,
            // so we don't JSON-decode every session's store on each inject.
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(sessionId),
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Confirm this file IS our session (not just a stray mention).
            guard obj["cliSessionId"] as? String == sessionId else { continue }
            if let title = obj["title"] as? String, !title.isEmpty {
                // Titles are normally short. Cap an anomalously long one (a stray
                // paragraph titled from content) to its distinctive head — which
                // is all the sidebar shows anyway — so it can't over-match
                // unrelated conversations on incidental shared tokens.
                var head = String(title.prefix(80))
                if title.count > 80, let lastSpace = head.lastIndex(of: " ") {
                    head = String(head[..<lastSpace])
                }
                return head
            }
        }
        return nil
    }

    /// Locate a session's JSONL transcript -- the same file readAiTitle scans.
    /// The router uses this to CONFIRM an injected message actually became a
    /// turn: the injector returns keystroke bytes POSTED, which is not proof of
    /// delivery (a paste into an unfocused composer vanishes and still reports
    /// "success"), so the router watches this file grow before claiming success.
    public static func transcriptURL(sessionId: String, projectsDir: URL? = nil) -> URL? {
        let base = projectsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return nil }
        for proj in projects {
            let jsonl = proj.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: jsonl.path) { return jsonl }
        }
        return nil
    }
}
