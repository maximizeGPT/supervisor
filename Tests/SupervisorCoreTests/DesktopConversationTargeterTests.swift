import XCTest
import CoreGraphics
@testable import SupervisorCore

/// Regression tests for the multi-window OCR extraction. The fixture is real
/// OCR output captured (via SupervisorDevTools ocr-dump) from the owner's
/// actual two/three-window Claude layout on a 1920x1080 display: a left sidebar
/// conversation list, neighbor-window body prose bleeding in at x~360-540, the
/// "project / title" bars of each open window up top, and the menu-bar clock.
///
/// Before the fix, sidebarCandidates used `x < 0.30*W` and swallowed the
/// neighbor window's prose as fake candidates (42 candidates, ~24 garbage), and
/// activeConversationTitle picked the longest top row — the clock. These assert
/// the extraction now isolates the real sidebar column and the real title bars.
final class DesktopConversationTargeterTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Real rows from a multi-window ocr-dump (text as OCR'd, point in screen px).
    private let rows: [(text: String, point: CGPoint)] = [
        // --- top strip: title bars (one per open window) + menu-bar clock ---
        ("• supervisor / Pause and kill interventions ~", CGPoint(x: 999, y: 25)),
        ("• main / Supervisor landing page •", CGPoint(x: 1515, y: 26)),
        ("Wed Jun 10 6:13 AM", CGPoint(x: 1772, y: 12)),
        ("0- x", CGPoint(x: 784, y: 26)),
        // --- left nav rail (above Recents) ---
        ("+ New session", CGPoint(x: 73, y: 110)),
        ("& Routines", CGPoint(x: 62, y: 135)),
        // --- Recents header ---
        ("Recents", CGPoint(x: 46, y: 233)),
        // --- real sidebar conversation list (left column, x~108-150) ---
        ("Pause and kill interventions", CGPoint(x: 128, y: 287)),
        ("• Insurance form completion", CGPoint(x: 117, y: 315)),
        ("• Resume feedback and review", CGPoint(x: 125, y: 341)),
        ("• Supervisor landing page", CGPoint(x: 108, y: 368)),
        ("• Supervisor design proposal", CGPoint(x: 118, y: 396)),
        ("• claude-eval-harness build", CGPoint(x: 114, y: 447)),
        ("• netsuite-saved-search-mcp build", CGPoint(x: 136, y: 530)),
        // --- neighbor window's BODY PROSE (x~360-540) — must NOT be candidates ---
        ("Relaunching:", CGPoint(x: 382, y: 237)),
        ("Ran Corrected isolated pipeline with literal app lists", CGPoint(x: 516, y: 266)),
        ("Freeze + Sign + Verify (all on the isolated snapshot):", CGPoint(x: 510, y: 406)),
        ("Signed inside-out - and all three verify PASS:", CGPoint(x: 500, y: 488)),
        ("Notarization - all 3 submitted, now In Progress:", CGPoint(x: 506, y: 647)),
        ("TeamIdentifier=Q7HKTCTZXQ", CGPoint(x: 470, y: 591)),
        // --- account footer (left column, but below the list) ---
        ("Relaunch to update", CGPoint(x: 136, y: 993)),
        ("MW Mohammed • Max", CGPoint(x: 83, y: 1053)),
    ]

    func testSidebarCandidatesIsolateRealColumnNotNeighborWindow() {
        let targeter = DesktopConversationTargeter()
        let titles = targeter.sidebarCandidates(from: rows, screen: screen).map(\.text)

        // The real sidebar titles are present.
        XCTAssertTrue(titles.contains("Pause and kill interventions"))
        XCTAssertTrue(titles.contains("Insurance form completion"))
        XCTAssertTrue(titles.contains("Supervisor landing page"))
        XCTAssertTrue(titles.contains("claude-eval-harness build"))

        // The neighbor window's body prose is NOT picked up as a candidate.
        for t in titles {
            XCTAssertFalse(t.contains("Freeze"), "neighbor prose leaked in: \(t)")
            XCTAssertFalse(t.contains("Notarization"), "neighbor prose leaked in: \(t)")
            XCTAssertFalse(t.contains("Signed inside-out"), "neighbor prose leaked in: \(t)")
            XCTAssertFalse(t.contains("TeamIdentifier"), "neighbor prose leaked in: \(t)")
            XCTAssertFalse(t.contains("Relaunching"), "neighbor prose leaked in: \(t)")
        }

        // And the candidate set is tight (the real list + at most footer noise),
        // not the old ~42-with-24-garbage blowout.
        XCTAssertLessThanOrEqual(titles.count, 12)
    }

    func testVisibleConversationTitlesReadsTitleBarsNotClock() {
        let targeter = DesktopConversationTargeter()
        let visible = targeter.visibleConversationTitles(from: rows, screen: screen)

        // Both open windows' titles are read.
        XCTAssertTrue(visible.contains("Pause and kill interventions"))
        XCTAssertTrue(visible.contains("Supervisor landing page"))

        // The menu-bar clock (no " / ") is never mistaken for a title.
        XCTAssertFalse(visible.contains(where: { $0.contains("6:13") || $0.contains("Jun 10") }))

        // Exactly the two title bars, nothing else from the top strip.
        XCTAssertEqual(visible.count, 2)
    }

    func testActiveTitleReturnsARealTitleNotTheClock() {
        let targeter = DesktopConversationTargeter()
        let active = targeter.visibleConversationTitles(from: rows, screen: screen).first
        XCTAssertNotNil(active)
        // Longest-first ordering puts the longer real title at the head; either
        // real title is acceptable, but it must never be the clock.
        XCTAssertNotEqual(active, "Wed Jun 10 6:13 AM")
        XCTAssertTrue(active == "Pause and kill interventions" || active == "Supervisor landing page")
    }

    /// Regression for the second real failure: a conversation BODY pane whose
    /// prose lands in the left-40% region with MORE rows than the sidebar. The
    /// old "densest column" rule picked the prose (29 rows) over the sidebar (18);
    /// "leftmost dense column" must lock onto the sidebar, which is always to the
    /// left of any body pane. Fixture mirrors the real ocr-dump: 6 sidebar titles
    /// at x~120 plus 11 draft-tweet body rows at x~470.
    func testLeftmostColumnWinsWhenBodyPaneIsDenserThanSidebar() {
        var fixture: [(text: String, point: CGPoint)] = [
            ("Recents", CGPoint(x: 46, y: 233)),
            // sidebar: 6 real titles at x~120
            ("Pause and kill interventions", CGPoint(x: 119, y: 286)),
            ("• Supervisor landing page", CGPoint(x: 108, y: 259)),
            ("• Insurance form completion", CGPoint(x: 118, y: 366)),
            ("• Resume feedback and review", CGPoint(x: 125, y: 394)),
            ("• claude-eval-harness build", CGPoint(x: 114, y: 475)),
            ("• netsuite-saved-search-mcp build", CGPoint(x: 136, y: 530)),
        ]
        // body pane: 11 prose rows at x~470 — denser than the 6-row sidebar
        let prose = [
            "I'm a CPA. Not a CS grad.", "So don't make them. Build the loop",
            "That's what Supervisor does", "Workflows, routines, orchestration",
            "and why it locks most people out", "The win isn't everyone learning",
            "So I'm building it. Supervisor", "Mechanics: quote-tweet the post",
            "the Supervisor demo card resurfaces", "My pick is reach (screenshottable)",
            "the non-engineer-who-built-it angle",
        ]
        for (i, line) in prose.enumerated() {
            fixture.append((line, CGPoint(x: 470, y: 260 + Double(i) * 26)))
        }

        let targeter = DesktopConversationTargeter()
        let titles = targeter.sidebarCandidates(from: fixture, screen: screen).map(\.text)

        // Sidebar wins despite the denser body pane.
        XCTAssertTrue(titles.contains("Pause and kill interventions"))
        XCTAssertTrue(titles.contains("Supervisor landing page"))
        // None of the body prose is mistaken for a conversation.
        for t in titles {
            XCTAssertFalse(t.contains("CPA"), "body prose leaked: \(t)")
            XCTAssertFalse(t.contains("quote-tweet"), "body prose leaked: \(t)")
            XCTAssertFalse(t.contains("locks most people"), "body prose leaked: \(t)")
        }
    }

    /// Regression for the third real failure: a verified-0.95 match clicked the
    /// right conversation but the post-click verify (substring on the clicked
    /// text) false-negatived because the title bar showed a reworded/reordered
    /// form -> switch_not_verified -> degraded. Token overlap must confirm the
    /// switch across the differing forms, while still rejecting a wrong title.
    func testTokenOverlapConfirmsSwitchAcrossRewordedTitleForms() {
        typealias T = DesktopConversationTargeter
        let target = "Accessibility of loop engineering for non-technica" // ai-title
        let clicked = "Loop engineering accessibility for no!"            // sidebar text (reordered, truncated)

        // Title bar in the ai-title word order -> confirms against the target.
        XCTAssertTrue(T.tokensConfirmSwitch(
            T.titleTokens("supervisor / Accessibility of loop engineering for non-technical people"),
            T.titleTokens(target)))

        // Title bar in the sidebar word order -> confirms against the clicked text.
        XCTAssertTrue(T.tokensConfirmSwitch(
            T.titleTokens("supervisor / Loop engineering accessibility for non-technical"),
            T.titleTokens(clicked)))

        // OCR-merged top row carrying the target's full bar among others -> still confirms.
        XCTAssertTrue(T.tokensConfirmSwitch(
            T.titleTokens("Pause and kill interventions ~ x supervisor / Accessibility of loop engineering for non-technical people"),
            T.titleTokens(target)))

        // A different conversation's bar must NOT false-confirm (bleed guard).
        XCTAssertFalse(T.tokensConfirmSwitch(
            T.titleTokens("supervisor / Pause and kill interventions"),
            T.titleTokens(target)))
        XCTAssertFalse(T.tokensConfirmSwitch(
            T.titleTokens("main / Supervisor landing page"),
            T.titleTokens(target)))
    }

    /// Replays the live 2026-06-12T16:32 bleed: an engineering answer for the
    /// "pause and kill" session was matched at 0.95 onto a DIFFERENT
    /// conversation ("Supervisor macOS app signing and notarization") and the
    /// verify confirmed the title it LANDED on instead of the one it was AIMING
    /// for. The guard must confirm only against the intended target ai-title, so
    /// the wrong conversation fails (-> notify) and the right one still passes.
    func testVerifyRejectsWrongConversationLandedOn() {
        typealias T = DesktopConversationTargeter
        let intended = "Ship pause and kill interventions for Supervisor v0.1.2"

        // The wrong conversation the matcher clicked -> MUST fail the identity guard.
        XCTAssertFalse(T.tokensConfirmSwitch(
            T.titleTokens("supervisor / Supervisor macOS app signing and notarization"),
            T.titleTokens(intended)))

        // The intended conversation's title bar (reworded/truncated) -> still passes.
        XCTAssertTrue(T.tokensConfirmSwitch(
            T.titleTokens("supervisor / Pause and kill interventions"),
            T.titleTokens(intended)))
    }

    /// The root cause of both the wrong-chat bleed and the silent degrade: the
    /// `aiTitle` frozen in the JSONL transcript drifts from the title Claude
    /// Desktop actually displays once it renames a conversation. readDesktopTitle
    /// must read the LIVE title from the claude-code-sessions store, keyed by
    /// cliSessionId == our sessionId, so targeting aims at what's on screen.
    func testReadDesktopTitleResolvesLiveTitleByCliSessionId() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccs-\(UUID().uuidString)", isDirectory: true)
        // Nested two deep, like the real <uuid>/<uuid>/local_<uuid>.json layout.
        let nested = tmp.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"sessionId":"local_x","cliSessionId":"sess-123","title":"The token-overlap verify fix","titleSource":"user"}"#
            .write(to: nested.appendingPathComponent("local_x.json"), atomically: true, encoding: .utf8)

        // Resolves the live title for the matching cliSessionId.
        XCTAssertEqual(
            DesktopConversationTargeter.readDesktopTitle(sessionId: "sess-123", storeDir: tmp),
            "The token-overlap verify fix")
        // A session not in the store -> nil (caller falls back to the frozen aiTitle).
        XCTAssertNil(DesktopConversationTargeter.readDesktopTitle(sessionId: "absent", storeDir: tmp))
    }

    /// An anomalously long title (a paragraph titled from content, as seen live)
    /// is capped to its distinctive head so it can't over-match unrelated chats.
    func testReadDesktopTitleCapsRunawayTitle() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let long = "The token-overlap verify fix is committed deployed and live and then a very long runaway paragraph that keeps going far past any real title length"
        try "{\"cliSessionId\":\"s\",\"title\":\"\(long)\"}"
            .write(to: tmp.appendingPathComponent("local_s.json"), atomically: true, encoding: .utf8)

        let title = try XCTUnwrap(DesktopConversationTargeter.readDesktopTitle(sessionId: "s", storeDir: tmp))
        XCTAssertLessThanOrEqual(title.count, 80)
        XCTAssertTrue(title.hasPrefix("The token-overlap verify fix"))
        XCTAssertFalse(title.hasSuffix(" "), "should trim back to a word boundary")
    }

    // MARK: - composerPoint (Piece 1: focus the composer before pasting)

    func testComposerPointAnchorsOnPlaceholder() {
        // The empty Claude Code composer shows "Type / for commands" in the
        // bottom band — the precise on-screen anchor. composerPoint returns it.
        let targeter = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("some conversation body text", CGPoint(x: 900, y: 500)),
            ("Read 2 files", CGPoint(x: 700, y: 800)),
            ("Type / for commands", CGPoint(x: 703, y: 1015)),  // composer placeholder
            ("Mohammed Max", CGPoint(x: 87, y: 1050)),          // account footer
            ("Bypass permissions", CGPoint(x: 689, y: 1057)),
        ]
        let pt = targeter.composerPoint(from: rows, screen: screen)
        XCTAssertEqual(pt, CGPoint(x: 703, y: 1015),
                       "must anchor on the composer placeholder row")
    }

    func testComposerPointFallsBackAboveFooterWhenNoPlaceholder() {
        // Composer already holds text (no placeholder). Fallback clicks just
        // above the footer, right of the sidebar — in the input, not on a
        // footer control.
        let targeter = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("a draft the worker is mid-typing", CGPoint(x: 710, y: 1012)),
            ("Mohammed Max", CGPoint(x: 87, y: 1050)),
            ("Opus 4.8 Max", CGPoint(x: 1520, y: 1054)),
            ("Bypass permissions", CGPoint(x: 689, y: 1057)),
        ]
        let pt = try? XCTUnwrap(targeter.composerPoint(from: rows, screen: screen))
        let p = try! XCTUnwrap(pt)
        let footerY: CGFloat = 1057
        XCTAssertLessThan(p.y, footerY, "fallback must click ABOVE the lowest footer row")
        XCTAssertGreaterThanOrEqual(p.y, screen.height * 0.82, "still within the bottom band")
        XCTAssertGreaterThan(p.x, screen.width * 0.20, "right of the sidebar, in the main pane")
    }

    func testComposerPointNilWhenNothingInBottomBand() {
        // No rows in the bottom band → can't anchor → nil (caller skips the
        // focus click; paste falls back to current focus, never worse).
        let targeter = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("title bar", CGPoint(x: 900, y: 25)),
            ("conversation body", CGPoint(x: 800, y: 400)),
            ("more body", CGPoint(x: 820, y: 700)),  // still above 0.82*1080=885.6
        ]
        XCTAssertNil(targeter.composerPoint(from: rows, screen: screen))
    }

    func testComposerPointPicksTargetWindowColumnInMultiWindow() {
        // Three tiled Claude windows → three composers in the bottom band. With
        // nearX = the target window's title-bar column, pick THAT window's
        // composer, not the leftmost (the 2026-06-14 mispick: clicked 408 for a
        // conversation whose composer was at ~1018).
        let targeter = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("Type / for commands", CGPoint(x: 408, y: 1015)),    // left window
            ("Type / for commands", CGPoint(x: 1018, y: 1015)),   // MIDDLE — the target
            ("Type / for commands", CGPoint(x: 1495, y: 1015)),   // right window
            ("Mw Mohammed Max", CGPoint(x: 86, y: 1050)),
        ]
        // Target ("app state review") title bar sits at x~1001 — the middle window.
        XCTAssertEqual(targeter.composerPoint(from: rows, screen: screen, nearX: 1001),
                       CGPoint(x: 1018, y: 1015),
                       "must pick the composer in the target window's column, not the leftmost")
        // No nearX → original topmost behavior (leftmost at min y).
        XCTAssertEqual(targeter.composerPoint(from: rows, screen: screen)?.x, 408,
                       "without nearX, falls back to the original pick")
    }

    // MARK: - MCQ (AskUserQuestion widget) detection (2026-06-16)

    func testDetectMCQControlsFindsOtherFieldAndSubmit() {
        // An AskUserQuestion widget OCRs as option rows + a "Type your own"/"Other"
        // affordance + a "Submit" button. detectMCQControls locates the three.
        let rows: [(text: String, point: CGPoint)] = [
            ("Which database should we use?", CGPoint(x: 900, y: 400)),
            ("PostgreSQL", CGPoint(x: 880, y: 470)),
            ("SQLite", CGPoint(x: 880, y: 520)),
            ("Other", CGPoint(x: 880, y: 580)),
            ("Type your own answer", CGPoint(x: 900, y: 620)),
            ("Submit", CGPoint(x: 1100, y: 700)),
        ]
        let c = try! XCTUnwrap(DesktopConversationTargeter.detectMCQControls(in: rows),
                               "must detect MCQ controls when Other + Submit are present")
        XCTAssertEqual(c.field, CGPoint(x: 900, y: 620), "field anchors on 'Type your own'")
        XCTAssertEqual(c.other, CGPoint(x: 880, y: 580), "other anchors on the 'Other' row")
        XCTAssertEqual(c.submit, CGPoint(x: 1100, y: 700))
    }

    func testDetectMCQControlsFallsBackToOtherWhenNoTypeYourOwnRow() {
        let rows: [(text: String, point: CGPoint)] = [
            ("Other", CGPoint(x: 880, y: 580)),
            ("Submit", CGPoint(x: 1100, y: 700)),
        ]
        let c = try! XCTUnwrap(DesktopConversationTargeter.detectMCQControls(in: rows))
        XCTAssertEqual(c.field, CGPoint(x: 880, y: 580), "no 'Type your own' → field falls back to 'Other'")
        XCTAssertEqual(c.other, CGPoint(x: 880, y: 580))
    }

    func testDetectMCQControlsNilForFreeTextQuestion() {
        // A plain free-text question (no widget) has no Submit/Other → not an MCQ,
        // so the caller pastes into the composer instead of operating a widget.
        let rows: [(text: String, point: CGPoint)] = [
            ("What should I name this function?", CGPoint(x: 900, y: 400)),
            ("Type / for commands", CGPoint(x: 700, y: 1015)),
        ]
        XCTAssertNil(DesktopConversationTargeter.detectMCQControls(in: rows),
                     "no Submit/Other → not an MCQ")
    }

    func testDetectMCQControlsNilWhenSubmitMissing() {
        // "Other" present but no "Submit" → don't treat as an operable MCQ.
        let rows: [(text: String, point: CGPoint)] = [
            ("Other", CGPoint(x: 880, y: 580)),
        ]
        XCTAssertNil(DesktopConversationTargeter.detectMCQControls(in: rows))
    }

    func testColumnBoundsConfinesToTargetPaneColumn() {
        // Four tiled panes → the column for the 3rd spans the midpoints to its left
        // and right neighbors, so a neighbor pane's MCQ controls are excluded.
        let panes: [(title: String, point: CGPoint)] = [
            ("a", CGPoint(x: 415, y: 30)),
            ("b", CGPoint(x: 862, y: 30)),
            ("c", CGPoint(x: 1308, y: 30)),
            ("d", CGPoint(x: 1673, y: 30)),
        ]
        let col = DesktopConversationTargeter.columnBounds(panes: panes, at: 1308)
        XCTAssertEqual(col.minX, 1085, accuracy: 0.5, "left edge = midpoint to pane b")
        XCTAssertEqual(col.maxX, 1490.5, accuracy: 0.5, "right edge = midpoint to pane d")
    }

    func testColumnBoundsWholeWidthForSinglePane() {
        let panes: [(title: String, point: CGPoint)] = [("only", CGPoint(x: 900, y: 30))]
        let col = DesktopConversationTargeter.columnBounds(panes: panes, at: 900)
        XCTAssertEqual(col.minX, 0)
        XCTAssertGreaterThan(col.maxX, 9000, "single pane → effectively whole width")
    }

    // MARK: - Worktree-named Code panes (2026-06-19 — the bug that broke every take)

    func testVisiblePaneTitlesDetectsWorktreeNamedCodePanes() {
        // Claude Code panes title their strip with the worktree name and NO " / "
        // separator ("• sv-demo-pause sv-demo-pause", "sv-demo-answer C"). The old
        // slash-only filter returned 0 panes → the misrouting single-window path.
        let t = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("sv-demo-answer C", CGPoint(x: 200, y: 25)),
            ("• sv-demo-notify sv-demo-notify", CGPoint(x: 606, y: 25)),
            ("• sv-demo-kill sv-demo-kill", CGPoint(x: 1067, y: 25)),
            ("• sv-demo-pause sv-demo-pause", CGPoint(x: 1565, y: 25)),
            (">", CGPoint(x: 1827, y: 26)),                          // window-control glyph
            ("billing service body text", CGPoint(x: 300, y: 400)),  // below the top strip
        ]
        let panes = t.visiblePaneTitles(from: rows, screen: screen)
        XCTAssertEqual(panes.count, 4, "all four worktree-named panes detected (was 0 before the fix)")
        XCTAssertTrue(panes.contains { $0.title.contains("sv-demo-pause") })
        XCTAssertTrue(panes.contains { $0.title.contains("sv-demo-kill") })
        XCTAssertFalse(panes.contains { $0.title == ">" }, "the 1-glyph window control must not be a pane")
        XCTAssertFalse(panes.contains { $0.title.contains("body text") }, "body text below the strip is not a pane")
    }

    func testVisiblePaneTitlesExcludesMenuBar() {
        // The fallback must never read the macOS menu bar as conversations.
        let t = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("Claude", CGPoint(x: 30, y: 12)),
            ("File", CGPoint(x: 90, y: 12)),
            ("Window", CGPoint(x: 200, y: 12)),
            ("• sv-demo-pause sv-demo-pause", CGPoint(x: 800, y: 25)),  // the only real pane
        ]
        let panes = t.visiblePaneTitles(from: rows, screen: screen)
        XCTAssertEqual(panes.count, 1, "menu-bar words excluded; only the real pane detected")
        XCTAssertTrue(panes.first?.title.contains("sv-demo-pause") ?? false)
    }

    func testVisiblePaneTitlesStillHandlesSlashFormat() {
        // The legacy "prefix / title" strips must still work and take precedence.
        let t = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("Mw / Supervisor launch readiness", CGPoint(x: 1500, y: 25)),
            ("File", CGPoint(x: 90, y: 12)),
        ]
        let panes = t.visiblePaneTitles(from: rows, screen: screen)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.title, "Supervisor launch readiness")
    }

    // MARK: - MCQ verify-before-submit (2026-06-19: never submit a blank "Other")

    func testAnswerLandedTrueWhenAnswerOnScreen() {
        // After a successful paste, the answer's leading slice is in the field's
        // OCR rows → safe to Submit.
        let rows: [(text: String, point: CGPoint)] = [
            ("Use PostgreSQL because it handles concurrent writes", CGPoint(x: 800, y: 850)),
            ("Submit", CGPoint(x: 900, y: 920)),
        ]
        XCTAssertTrue(DesktopConversationTargeter.answerLanded(
            "Use PostgreSQL because it handles concurrent writes", in: rows))
    }

    func testAnswerLandedFalseWhenFieldBlank() {
        // THE bug Mohammed caught: two MCQs at once, the paste missed, the field
        // is still showing the placeholder → answer not on screen → must NOT submit.
        let rows: [(text: String, point: CGPoint)] = [
            ("Type your own answer", CGPoint(x: 800, y: 850)),
            ("Submit", CGPoint(x: 900, y: 920)),
        ]
        XCTAssertFalse(DesktopConversationTargeter.answerLanded(
            "Use PostgreSQL because it handles concurrent writes", in: rows))
    }

    func testAnswerLandedToleratesOcrMangling() {
        // OCR mangles the tail but the head is intact → still verified.
        let rows: [(text: String, point: CGPoint)] = [
            ("PostgreSQL becau5e it handlez", CGPoint(x: 800, y: 850)),
        ]
        XCTAssertTrue(DesktopConversationTargeter.answerLanded(
            "PostgreSQL because it handles writes", in: rows))
    }

    func testMcqFieldPointPrefersTypeYourOwn() {
        let rows: [(text: String, point: CGPoint)] = [
            ("Other", CGPoint(x: 800, y: 800)),
            ("Type your own answer", CGPoint(x: 820, y: 840)),
        ]
        XCTAssertEqual(DesktopConversationTargeter.mcqFieldPoint(in: rows), CGPoint(x: 820, y: 840))
    }
}
