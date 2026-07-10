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

    // MARK: - resolveUniqueMatch (M8: exact-unique-or-notify ambiguity guard)

    /// Build a candidate list from plain titles (point is irrelevant to matching).
    private func cands(_ titles: [String]) -> [DesktopConversationCandidate] {
        titles.enumerated().map { i, t in
            DesktopConversationCandidate(text: t, point: CGPoint(x: 120, y: 280 + Double(i) * 28))
        }
    }

    /// The exact M8 collision: a dispatch for "Supervisor Product Launch
    /// Readiness" must select that EXACT conversation, not the shorter near-match
    /// "Supervisor Launch Readiness" that the fuzzy matcher also scores above the
    /// gate. Exact-unique title equality wins outright.
    func testResolveSelectsExactTitleNotShorterNearMatch() throws {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        let candidates = cands(["Supervisor Launch Readiness", "Supervisor Product Launch Readiness"])
        let r = try XCTUnwrap(T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }))
        XCTAssertEqual(r.candidate.text, "Supervisor Product Launch Readiness",
                       "must pick the exact full title, never the shorter collision")
        XCTAssertTrue(r.exact, "exact-unique path should fire")
    }

    /// Reverse direction: target is the SHORTER title and the LONGER near-match
    /// is also on screen. Exact-unique equality still selects the right (shorter)
    /// one, never the longer superset.
    func testResolveSelectsExactShorterTitleOverLongerSuperset() throws {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        let candidates = cands(["Supervisor Launch Readiness", "Supervisor Product Launch Readiness"])
        let r = try XCTUnwrap(T.resolveUniqueMatch(
            target: "Supervisor Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }))
        XCTAssertEqual(r.candidate.text, "Supervisor Launch Readiness")
    }

    /// No exact title on screen (Claude Desktop truncated it), but the correct
    /// conversation still clearly out-scores the collision -> a clear-margin
    /// winner is selected rather than degrading.
    func testResolveAcceptsClearMarginWinnerWhenNoExact() throws {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        // "Supervisor Product Launch Read" (truncated, prefix of target ~0.93)
        // vs "Supervisor Launch Readiness" (token overlap ~0.75): margin > 0.10.
        let candidates = cands(["Supervisor Launch Readiness", "Supervisor Product Launch Read"])
        let r = try XCTUnwrap(T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }))
        XCTAssertEqual(r.candidate.text, "Supervisor Product Launch Read")
        XCTAssertFalse(r.exact, "no exact title present -> scored path")
    }

    /// AMBIGUITY GUARD, duplicate exact titles. Two on-screen conversations both
    /// equal the target: cannot tell them apart -> nil -> caller degrades to
    /// notify, instead of a guess.
    func testResolveReturnsNilOnDuplicateExactTitles() {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        let candidates = cands(["Supervisor Product Launch Readiness",
                                "Supervisor Product Launch Readiness"])
        XCTAssertNil(T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }),
            "duplicate exact titles are ambiguous -> no target")
    }

    /// AMBIGUITY GUARD, near-tie with no exact match. Two candidates score
    /// within the margin of each other (both plausibly the target), so there is
    /// no unique winner -> nil. A forced matcher returns the wrong one at high
    /// confidence; the local-margin guard still catches the collision.
    func testResolveReturnsNilOnNearTieNoExact() {
        typealias T = DesktopConversationTargeter
        // Two truncated forms that BOTH overlap the target heavily and sit within
        // the margin of each other. A matcher that confidently picks the WRONG
        // one must NOT lead to an inject; the margin guard overrides it.
        let candidates = cands(["Supervisor Launch Readiness review",
                                "Supervisor Launch Readiness report"])
        // Force the matcher to return candidate 0 at 0.95 (simulating an
        // overconfident LLM). resolveUniqueMatch must still refuse: the two
        // local scores are a near-tie.
        let forcedWrong: ([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)? = { c, _ in
            (c[0], 0.95)
        }
        XCTAssertNil(T.resolveUniqueMatch(
            target: "Supervisor Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: forcedWrong),
            "a near-tie between two candidates must degrade, even if the matcher is confident")
    }

    /// No candidate clears the confidence threshold -> nil (the target isn't on
    /// screen). Caller degrades to notify rather than clicking the closest stray.
    func testResolveReturnsNilWhenNothingClearsThreshold() {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        let candidates = cands(["Insurance form completion", "Resume feedback and review"])
        XCTAssertNil(T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }),
            "no candidate is the target -> no inject")
    }

    /// Empty candidate set -> nil (nothing to match).
    func testResolveReturnsNilOnEmptyCandidates() {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        XCTAssertNil(T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: [],
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }))
    }

    /// IDENTITY FLOOR (2026-07-08 misroute fix). Replays the live misroute: a
    /// dispatch for a short/generic target ("discussion") was pasted into a
    /// textually-UNRELATED conversation ("memory/skill audit") because the LLM
    /// matcher picked it with high self-reported confidence. The margin guard did
    /// not catch it — the wrong winner beat the OTHER (equally unrelated)
    /// candidates by a wide margin. The winner's OWN local identity overlap with
    /// the target is ~0, so the identity floor must degrade this to notify: even a
    /// confident matcher cannot paste a candidate that doesn't resemble the target.
    func testResolveReturnsNilWhenConfidentMatcherPicksTextuallyUnrelatedWinner() {
        typealias T = DesktopConversationTargeter
        // The real open conversations, none of which is the target "discussion".
        let candidates = cands(["memory/skill audit",
                                "landing page redesign",
                                "notarization pipeline"])
        // An overconfident LLM: returns "memory/skill audit" at 0.92. Its LOCAL
        // token/prefix overlap with "discussion" is 0, and it beats the other
        // (also-0) candidates by a wide margin — so ONLY the identity floor stops
        // the paste, not the threshold-on-matcher-confidence and not the margin.
        let overconfidentLLM: ([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)? = { c, _ in
            (c[0], 0.92)
        }
        XCTAssertNil(T.resolveUniqueMatch(
            target: "discussion",
            candidates: candidates,
            threshold: 0.6,
            matcher: overconfidentLLM),
            "a confidently-picked but textually-unrelated winner must degrade to notify (identity floor), not paste into the wrong chat")
    }

    /// The identity floor must NOT weaken the confident path. When the winner
    /// actually resembles the target (its local score clears the floor) AND it
    /// out-margins the runners-up, the SAME confident LLM pick still resolves to a
    /// real target — the fix only bites the textually-unrelated case above.
    func testIdentityFloorLeavesGenuineLLMMatchUnchanged() throws {
        typealias T = DesktopConversationTargeter
        // Target present on screen in a truncated form the LLM correctly maps.
        let candidates = cands(["Ship pause and kill interventions for Supervi",  // truncated target
                                "Insurance form completion",
                                "Resume feedback and review"])
        // A confident LLM that picks the RIGHT (truncated) candidate.
        let goodLLM: ([DesktopConversationCandidate], String) -> (DesktopConversationCandidate, Double)? = { c, _ in
            (c[0], 0.90)
        }
        let r = try XCTUnwrap(T.resolveUniqueMatch(
            target: "Ship pause and kill interventions for Supervisor v0.1.2",
            candidates: candidates,
            threshold: 0.6,
            matcher: goodLLM),
            "a genuine (textually-overlapping) LLM match must still resolve — the floor must not degrade the confident path")
        XCTAssertEqual(r.candidate.text, "Ship pause and kill interventions for Supervi")
        XCTAssertFalse(r.exact, "truncated, so the scored path (not exact) fired")
    }

    /// The fuzzy DEFAULT matcher is unaffected by the identity floor: its reported
    /// confidence IS its local score, so a fuzzy winner that clears the threshold
    /// also clears the floor by construction. This locks in "confident path
    /// unchanged" for the production default (no LLM wired).
    func testIdentityFloorIsNoOpForFuzzyDefaultMatcher() throws {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()
        // A clear, unambiguous fuzzy match (exact-truncated prefix, no collision).
        let candidates = cands(["Insurance form completion",
                                "Resume feedback and review",
                                "netsuite-saved-search-mcp build"])
        let r = try XCTUnwrap(T.resolveUniqueMatch(
            target: "Insurance form completion",
            candidates: candidates,
            threshold: 0.6,
            matcher: { c, t in targeter.bestMatch(target: t, candidates: c) }))
        XCTAssertEqual(r.candidate.text, "Insurance form completion",
                       "the fuzzy confident path resolves exactly as before the floor")
    }

    /// End-to-end of the guard's CONTRACT: the M8 ambiguity case yields no target
    /// (nil). The injector translates that into a degrade-to-notify (its
    /// `.targetingFailed` -> throws `.targetUnresolvable` -> router posts
    /// injectDegraded), so a nil here is precisely "do NOT inject". This asserts
    /// the decision boundary that prevents the wrong-chat paste.
    func testAmbiguityYieldsNoTargetSoInjectIsSkipped() {
        typealias T = DesktopConversationTargeter
        // Genuine ambiguity (duplicate exact titles): the resolver returns nil,
        // which is the signal the injector uses to skip the paste and notify.
        let duplicates = cands(["Supervisor Product Launch Readiness",
                                "Supervisor Product Launch Readiness"])
        let resolved = T.resolveUniqueMatch(
            target: "Supervisor Product Launch Readiness",
            candidates: duplicates,
            threshold: 0.6,
            matcher: { c, t in (c.first!, 1.0) })  // even a 1.0 matcher cannot rescue ambiguity
        XCTAssertNil(resolved, "ambiguous target must produce NO match (inject skipped, degrade to notify)")
    }

    // MARK: - Supervisor banner filter (never self-target our own stamp)

    /// The matcher repeatedly picked Supervisor's OWN injected banner as the best
    /// candidate (conf=0.95). The banner must be excluded from both the sidebar
    /// candidate set and the visible pane titles, in both bracket forms and an
    /// OCR-mangled variant, while a real title in the same column is kept.
    func testSupervisorBannerExcludedFromSidebarAndPaneTitles() {
        typealias T = DesktopConversationTargeter
        let targeter = DesktopConversationTargeter()

        // Predicate recognizes the known forms + an OCR-mangled variant, and
        // never a real title.
        XCTAssertTrue(T.isSupervisorBannerText("[ SUPERVISOR • automated - NOT from your operator ]"))
        XCTAssertTrue(T.isSupervisorBannerText("⟦ SUPERVISOR · automated — NOT from your operator ⟧"))
        // OCR-mangled variant: brackets dropped to bare glyphs, dot separators,
        // odd spacing, and the three distinctive tokens still survive.
        XCTAssertTrue(T.isSupervisorBannerText("l SUPERVISOR  .  automated   NOT from your operator  l"))
        XCTAssertFalse(T.isSupervisorBannerText("Supervisor landing page"))
        XCTAssertFalse(T.isSupervisorBannerText("Pause and kill interventions"))

        // Sidebar: a banner row in the sidebar column is dropped; the real title
        // beside it is kept.
        let sidebarRows: [(text: String, point: CGPoint)] = [
            ("Recents", CGPoint(x: 46, y: 233)),
            ("⟦ SUPERVISOR · automated — NOT from your operator ⟧", CGPoint(x: 120, y: 287)),
            ("[ SUPERVISOR • automated - NOT from your operator ]", CGPoint(x: 118, y: 315)),
            ("Pause and kill interventions", CGPoint(x: 128, y: 341)),
            ("Supervisor landing page", CGPoint(x: 108, y: 368)),
            ("Insurance form completion", CGPoint(x: 117, y: 396)),
            ("Resume feedback and review", CGPoint(x: 125, y: 424)),
        ]
        let sidebar = targeter.sidebarCandidates(from: sidebarRows, screen: screen).map(\.text)
        XCTAssertTrue(sidebar.contains("Pause and kill interventions"))
        XCTAssertTrue(sidebar.contains("Supervisor landing page"))
        for t in sidebar {
            XCTAssertFalse(T.isSupervisorBannerText(t), "banner leaked into sidebar: \(t)")
        }

        // Pane titles: a banner masquerading as a "project / Title" top-strip row
        // is dropped; the real pane title is kept.
        let paneRows: [(text: String, point: CGPoint)] = [
            ("supervisor / Pause and kill interventions ~", CGPoint(x: 999, y: 25)),
            ("⟦ SUPERVISOR · automated — NOT from your operator ⟧", CGPoint(x: 1200, y: 26)),
            ("[ SUPERVISOR • automated - NOT from your operator ]", CGPoint(x: 600, y: 24)),
        ]
        let panes = targeter.visiblePaneTitles(from: paneRows, screen: screen).map(\.title)
        XCTAssertTrue(panes.contains("Pause and kill interventions"))
        for t in panes {
            XCTAssertFalse(T.isSupervisorBannerText(t), "banner leaked into pane titles: \(t)")
        }
    }

    /// ITEM 2 root cause: after switch_verified resolves a title at one column
    /// (titleX=407), the placeholder branch picked the CLOSEST placeholder to
    /// nearX even when it was a DIFFERENT pane's composer (x=953), pasting into
    /// the wrong pane. The pick must stay in the verified pane's column: with only
    /// far-off placeholders, fall back to clicking at x≈nearX, never x=953.
    func testComposerPointStaysInVerifiedColumnWhenNoNearPlaceholder() {
        let targeter = DesktopConversationTargeter()
        let rows: [(text: String, point: CGPoint)] = [
            ("Type / for commands", CGPoint(x: 953, y: 1015)),   // neighbor pane
            ("Type / for commands", CGPoint(x: 1018, y: 1015)),  // another neighbor pane
            ("Mw Mohammed Max", CGPoint(x: 86, y: 1050)),
        ]
        let pt = targeter.composerPoint(from: rows, screen: screen, nearX: 407)
        let p = try! XCTUnwrap(pt)
        XCTAssertEqual(p.x, 407, accuracy: 1,
                       "no placeholder in the verified column → click at the verified column x, not a far-off pane's composer")
        XCTAssertNotEqual(p.x, 953, "must never land on the wrong pane's composer")

        // A placeholder WITHIN the column tolerance of nearX is returned as-is.
        let near: [(text: String, point: CGPoint)] = [
            ("Type / for commands", CGPoint(x: 420, y: 1015)),   // same column as nearX=407
            ("Type / for commands", CGPoint(x: 1018, y: 1015)),  // far pane
        ]
        XCTAssertEqual(targeter.composerPoint(from: near, screen: screen, nearX: 407),
                       CGPoint(x: 420, y: 1015),
                       "an in-column placeholder is selected directly")
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
}
