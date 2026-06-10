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
}
