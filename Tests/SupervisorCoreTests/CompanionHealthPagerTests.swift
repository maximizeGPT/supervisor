// CompanionHealthPagerTests.swift
//
// The transition edges that decide when the status-bar companion pages the
// owner about a dead or hung engine. Pure state machine, so every rule is a
// table here: one page per transition, stopped only after 60s of unbroken
// red (the definitive death signal is the reparent path, not staleness),
// hung only past 2 minutes of degraded (amber or red), a hang may escalate
// to a stop, recovery reports once, and nothing pages before the first
// green (the companion boots into red("starting")).
//
// The postSystemMessage half — the delivery the page rides on — is covered
// at the bottom against the stub transport: gates, per-kind dedupe with
// per-call windows, and the trace/privacy posture it inherits.

import XCTest
@testable import SupervisorCore

final class CompanionHealthPagerTests: XCTestCase {

    private typealias Pager = CompanionHealthPager

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Run a sequence of (offsetSeconds, health) ticks and collect the
    /// pages, simulating an executor whose every delivery succeeds
    /// instantly. The C3 feedback loop (failures, retries, in-flight
    /// upgrades) has its own tests below against explicit outcomes.
    private func run(_ ticks: [(TimeInterval, HeartbeatHealth)]) -> [Pager.Page] {
        var state = Pager.State()
        var pages: [Pager.Page] = []
        for (offset, health) in ticks {
            let (next, page) = Pager.step(state: state, health: health, now: t0.addingTimeInterval(offset))
            state = next
            if let page {
                pages.append(page)
                state = Pager.delivered(state: state, page: page)
            }
        }
        return pages
    }

    // MARK: - Arming

    func testNeverPagesBeforeTheFirstGreen() {
        // Boot straight into red (the companion's initial state) and stay
        // there: opening just the icon next to an already-dead app must not
        // page on every boot.
        let pages = run([(0, .red(reason: "starting")), (2, .red(reason: "heartbeat stale (40s)")), (600, .red(reason: "heartbeat stale (640s)"))])
        XCTAssertEqual(pages, [])
    }

    func testAmberBeforeFirstGreenNeverPages() {
        let pages = run([(0, .amber), (200, .amber), (400, .amber)])
        XCTAssertEqual(pages, [])
    }

    // MARK: - Sustained red

    func testShortRedBlipNeverPagesAndNeverFakesARecovery() {
        // The 31s main-thread stall: staleness walks amber into red in 20s,
        // then the writers catch up. Before the sustained-red rule this
        // paged "stopped" + "recovered" seconds apart for a stall.
        let pages = run([
            (0, .green),
            (12, .amber),
            (32, .red(reason: "heartbeat stale (31s)")),
            (58, .red(reason: "heartbeat stale (57s)")),
            (60, .green),
            (120, .green),
        ])
        XCTAssertEqual(pages, [], "a transient stall is not an incident, and nothing paged means nothing recovers")
    }

    func testSustainedRedPagesStoppedOnceAndOnlyOnce() {
        let pages = run([
            (0, .green),
            (2, .red(reason: "heartbeat stale (31s)")),
            (30, .red(reason: "heartbeat stale (59s)")),
            (62, .red(reason: "heartbeat stale (91s)")),
            (3600, .red(reason: "heartbeat stale (3629s)")),
        ])
        XCTAssertEqual(pages, [.engineStopped(reason: "heartbeat stale (91s)")],
                       "60s of unbroken red pages exactly once, however long it stays red")
    }

    func testRecoveryReportsOnceThenRearms() {
        let pages = run([
            (0, .green),
            (2, .red(reason: "x")),
            (62, .red(reason: "x2")),
            (100, .green),
            (102, .green),
            (120, .red(reason: "y")),
            (185, .red(reason: "y2")),
        ])
        XCTAssertEqual(pages, [
            .engineStopped(reason: "x2"),
            .recovered,
            .engineStopped(reason: "y2"),
        ], "recovery clears the incident, so a NEW sustained death pages again")
    }

    func testAnAmberTickBreaksTheRedRun() {
        // Red must hold CONTINUOUSLY: 50s red, one amber, 50s red is two
        // sub-sustained runs, not one 100s run.
        let pages = run([
            (0, .green),
            (2, .red(reason: "a")),
            (52, .red(reason: "b")),
            (54, .amber),
            (56, .red(reason: "c")),
            (106, .red(reason: "d")),
        ])
        XCTAssertEqual(pages, [], "each red run restarts its own 60s clock")
    }

    func testGreenAfterNoPageStaysSilent() {
        // A red the pager never paged (pre-first-green) must not produce a
        // recovery message either — there is nothing to recover FROM.
        let pages = run([(0, .red(reason: "starting")), (2, .green), (4, .green)])
        XCTAssertEqual(pages, [])
    }

    // MARK: - Sustained amber

    func testShortAmberBlipNeverPages() {
        let pages = run([(0, .green), (2, .amber), (60, .amber), (119, .amber), (121, .green)])
        XCTAssertEqual(pages, [], "amber under the 2-minute threshold is a blip, not a hang")
    }

    func testSustainedAmberPagesHungOnce() {
        let pages = run([
            (0, .green),
            (2, .amber),
            (61, .amber),
            (123, .amber),   // 121s into the run: past the threshold
            (180, .amber),
            (600, .amber),
        ])
        XCTAssertEqual(pages, [.engineHung], "one page for the whole hang, never one per tick")
    }

    func testAmberThresholdIsStrictlyExceeded() {
        // Exactly 120s of amber is the boundary, not past it.
        let pages = run([(0, .green), (2, .amber), (122, .amber)])
        XCTAssertEqual(pages, [])
    }

    func testAmberRunResetsWhenHealthRecovers() {
        // 100s of amber, green, then amber again: the second run starts its
        // own clock instead of inheriting the first run's age.
        let pages = run([
            (0, .green), (2, .amber), (100, .amber),
            (110, .green),
            (112, .amber), (200, .amber),
        ])
        XCTAssertEqual(pages, [])
    }

    func testHungEscalatesToStoppedWithOneMorePage() {
        let pages = run([
            (0, .green),
            (2, .amber),
            (150, .amber),                       // hung page
            (200, .red(reason: "engine stale (170s)")),  // the hang became a death
            (260, .red(reason: "engine stale (230s)")),  // 60s of unbroken red
        ])
        XCTAssertEqual(pages, [
            .engineHung,
            .engineStopped(reason: "engine stale (230s)"),
        ], "a hang turning into a sustained death is an escalation, paged once more")
    }

    func testStoppedNeverDeescalatesToHung() {
        // A paged stop, then amber for ages: the incident was already
        // reported at the stronger level; a weaker follow-up would read as
        // half a recovery.
        let pages = run([
            (0, .green),
            (2, .red(reason: "x")),
            (62, .red(reason: "x2")),
            (70, .amber),
            (400, .amber),
        ])
        XCTAssertEqual(pages, [.engineStopped(reason: "x2")])
    }

    func testFlappingAmberRedPagesHungAtTwoMinutesOfDegraded() {
        // A stall oscillating between amber and red never holds red for
        // 60s, but the degraded run crosses 2 minutes: that is the hung
        // verdict the threshold was designed for, and before red ticks
        // counted toward it, this stall could never page at all.
        let pages = run([
            (0, .green),
            (10, .amber),
            (40, .red(reason: "a")),
            (80, .amber),
            (100, .red(reason: "b")),
            (140, .red(reason: "c")),
        ])
        XCTAssertEqual(pages, [.engineHung])
    }

    // MARK: - Sleep/wake grace

    func testWakeSuppressionDeadlineFiresOnlyOnALongTickGap() {
        XCTAssertNil(Pager.wakeSuppressionDeadline(lastTickAt: nil, now: t0),
                     "the first tick ever has no gap to judge")
        XCTAssertNil(Pager.wakeSuppressionDeadline(lastTickAt: t0, now: t0.addingTimeInterval(2)),
                     "the normal cadence is not a wake")
        XCTAssertNil(Pager.wakeSuppressionDeadline(lastTickAt: t0, now: t0.addingTimeInterval(5)),
                     "scheduling jitter up to the threshold is not a wake")
        XCTAssertEqual(
            Pager.wakeSuppressionDeadline(lastTickAt: t0, now: t0.addingTimeInterval(3600)),
            t0.addingTimeInterval(3600 + Pager.wakeGraceSeconds),
            "an hour-long gap is a sleep; verdicts hold for one refresh cycle"
        )
    }

    func testWakeResetClearsRunClocksButKeepsTheOpenIncident() {
        let slept = Pager.wakeReset(Pager.State(
            hasSeenGreen: true,
            degradedSince: t0,
            redSince: t0,
            pagedIncident: .stopped
        ))
        XCTAssertNil(slept.degradedSince, "a run interrupted by sleep is not one run")
        XCTAssertNil(slept.redSince)
        XCTAssertEqual(slept.pagedIncident, .stopped,
                       "an open incident survives sleep, or its recovery page would never go out")
        XCTAssertTrue(slept.hasSeenGreen)
    }

    func testPostWakeRedNeedsItsOwnSustainedRun() {
        // Simulates the tick loop around a sleep: green before, wakeReset at
        // wake, then the stale-file red the first post-grace ticks see. The
        // writers catch up inside a minute, so no page — and no recovery.
        var state = Pager.State()
        var pages: [Pager.Page] = []
        func feed(_ offset: TimeInterval, _ health: HeartbeatHealth) {
            let (next, page) = Pager.step(state: state, health: health, now: t0.addingTimeInterval(offset))
            state = next
            if let page { pages.append(page) }
        }
        feed(0, .green)
        state = Pager.wakeReset(state)  // the 8h lid-close, detected at wake
        feed(30_000, .red(reason: "heartbeat stale (28800s)"))
        feed(30_020, .red(reason: "heartbeat stale (28820s)"))
        feed(30_030, .green)
        XCTAssertEqual(pages, [], "a wake is not an incident")
    }

    // MARK: - Delivery feedback (C3)

    /// Drive the machine tick by tick with explicit delivery outcomes.
    private struct Harness {
        var state = Pager.State()
        let t0: Date
        mutating func tick(_ offset: TimeInterval, _ health: HeartbeatHealth) -> Pager.Page? {
            let (next, page) = Pager.step(state: state, health: health, now: t0.addingTimeInterval(offset))
            state = next
            return page
        }
        mutating func fail(_ page: Pager.Page, at offset: TimeInterval) {
            state = Pager.deliveryFailed(state: state, page: page, now: t0.addingTimeInterval(offset))
        }
        mutating func deliver(_ page: Pager.Page) {
            state = Pager.delivered(state: state, page: page)
        }
    }

    func testFailedPageRetriesOnBackoffAndOnlyDeliveryStampsTheIncident() {
        var h = Harness(t0: t0)
        XCTAssertNil(h.tick(0, .green))
        XCTAssertNil(h.tick(2, .red(reason: "r")))
        let first = h.tick(62, .red(reason: "r"))
        XCTAssertEqual(first, .engineStopped(reason: "r"), "sustained red emits the intent")

        h.fail(first!, at: 62)
        XCTAssertNil(h.state.pagedIncident, "a failed page must never be marked sent")
        XCTAssertNil(h.tick(64, .red(reason: "r")), "inside the 30s backoff: no per-tick hammer")
        XCTAssertNil(h.tick(90, .red(reason: "r")))
        let second = h.tick(92, .red(reason: "r"))
        XCTAssertEqual(second, .engineStopped(reason: "r"), "first retry lands 30s after the failure")

        h.fail(second!, at: 92)
        XCTAssertNil(h.tick(120, .red(reason: "r")))
        let third = h.tick(152, .red(reason: "r"))
        XCTAssertNotNil(third, "second retry lands 60s after the second failure")

        h.fail(third!, at: 152)
        XCTAssertNil(h.tick(300, .red(reason: "r")), "after two retries the ladder holds at 5 minutes")
        let fourth = h.tick(452, .red(reason: "r"))
        XCTAssertNotNil(fourth)

        h.deliver(fourth!)
        XCTAssertEqual(h.state.pagedIncident, .stopped, "delivery, and only delivery, stamps the incident")
        XCTAssertNil(h.tick(500, .red(reason: "r")), "a stamped stop never repeats")
    }

    func testNoReemissionWhileAnAttemptIsInFlight() {
        var h = Harness(t0: t0)
        _ = h.tick(0, .green)
        _ = h.tick(2, .red(reason: "r"))
        XCTAssertNotNil(h.tick(62, .red(reason: "r")))
        // No outcome reported yet: the attempt is in flight. Ticks must not
        // pile a second POST onto the wire.
        XCTAssertNil(h.tick(64, .red(reason: "r")))
        XCTAssertNil(h.tick(90, .red(reason: "r")))
    }

    func testFailedRecoveryPageRetriesUntilDelivered() {
        var h = Harness(t0: t0)
        _ = h.tick(0, .green)
        _ = h.tick(2, .red(reason: "r"))
        h.deliver(h.tick(62, .red(reason: "r"))!)  // stopped, delivered
        let recovery = h.tick(100, .green)
        XCTAssertEqual(recovery, .recovered)
        h.fail(recovery!, at: 100)
        XCTAssertEqual(h.state.pagedIncident, .stopped,
                       "the incident stays open until the all-clear actually lands")
        XCTAssertNil(h.tick(110, .green), "inside the backoff")
        let retried = h.tick(131, .green)
        XCTAssertEqual(retried, .recovered)
        h.deliver(retried!)
        XCTAssertNil(h.state.pagedIncident)
        XCTAssertNil(h.tick(140, .green), "one recovery per incident")
    }

    func testUndeliveredStopIsDroppedOnRecoveryWithNoFalseAllClear() {
        var h = Harness(t0: t0)
        _ = h.tick(0, .green)
        _ = h.tick(2, .red(reason: "r"))
        let intent = h.tick(62, .red(reason: "r"))
        h.fail(intent!, at: 62)
        // The blip healed before the page ever left the machine: drop the
        // stop, and send no recovery for an incident nobody heard about.
        XCTAssertNil(h.tick(70, .green))
        XCTAssertNil(h.state.pending)
        XCTAssertNil(h.state.pagedIncident)
        XCTAssertNil(h.tick(80, .green))
    }

    func testUndeliveredRecoveryIsDroppedWhenTheIncidentRelapses() {
        var h = Harness(t0: t0)
        _ = h.tick(0, .green)
        _ = h.tick(2, .red(reason: "r"))
        h.deliver(h.tick(62, .red(reason: "r"))!)  // stopped, delivered
        let recovery = h.tick(100, .green)
        h.fail(recovery!, at: 100)
        // Red returns before the all-clear could be delivered: the
        // incident never ended, so the stale "recovered" must die, and the
        // already-delivered stop must not repeat.
        XCTAssertNil(h.tick(120, .red(reason: "r2")))
        XCTAssertNil(h.state.pending)
        XCTAssertNil(h.tick(190, .red(reason: "r2")), "same incident, already paged as stopped")
    }

    func testEscalationWhileHungPageIsInFlight() {
        var h = Harness(t0: t0)
        _ = h.tick(0, .green)
        _ = h.tick(2, .amber)
        let hung = h.tick(130, .amber)
        XCTAssertEqual(hung, .engineHung)
        // While the hung POST is in flight the hang becomes a sustained
        // death. The stronger page replaces the pending slot; nothing
        // double-emits while the wire is busy.
        _ = h.tick(140, .red(reason: "r"))
        XCTAssertNil(h.tick(205, .red(reason: "r")))
        // The late hung result lands: stamped as hung, but the pending
        // stop survives and goes out on the next tick.
        h.deliver(hung!)
        XCTAssertEqual(h.state.pagedIncident, .hung)
        let escalated = h.tick(207, .red(reason: "r"))
        XCTAssertEqual(escalated, .engineStopped(reason: "r"))
        h.deliver(escalated!)
        XCTAssertEqual(h.state.pagedIncident, .stopped,
                       "a late hung delivery never downgrades an escalated stop")
    }

    func testRetryLadderValues() {
        XCTAssertEqual(Pager.retryDelay(afterFailures: 1), 30)
        XCTAssertEqual(Pager.retryDelay(afterFailures: 2), 60)
        XCTAssertEqual(Pager.retryDelay(afterFailures: 3), 300)
        XCTAssertEqual(Pager.retryDelay(afterFailures: 9), 300, "the ladder holds, it never grows unbounded")
    }

    // MARK: - Webhook cache refresh (C3a)

    func testCacheRefreshKeepsTheCacheOnAFailedReadAndHonorsDeletion() {
        XCTAssertEqual(
            Pager.refreshedWebhookCache(readSucceeded: false, readValue: nil, current: "https://x"),
            "https://x",
            "a transient Keychain error must not wipe a working URL"
        )
        XCTAssertNil(
            Pager.refreshedWebhookCache(readSucceeded: true, readValue: nil, current: "https://x"),
            "a successful nil read means the owner deleted the URL; do not resurrect it"
        )
        XCTAssertEqual(
            Pager.refreshedWebhookCache(readSucceeded: true, readValue: "https://y", current: "https://x"),
            "https://y"
        )
    }

    // MARK: - Reparent death (C1)

    func testReparentWithDeployMarkerExitsQuietly() {
        // A deploy pkills the running app on purpose and relaunches seconds
        // later; paging on that would cry wolf on every update.
        guard case .exitQuietly = Pager.reparentAction(deployMarkerPresent: true) else {
            return XCTFail("deploy relaunch must not page")
        }
    }

    func testReparentWithoutDeployMarkerPagesThenExits() {
        // The headline case: the app died while nobody was looking. The
        // reparent IS the death signal (it lands within 2s, before staleness
        // could ever fire), so it must page on the way out.
        XCTAssertEqual(Pager.reparentAction(deployMarkerPresent: false), .pageStoppedThenExit)
    }

    /// The remedy must not page as an outage. The hung-engine page tells the
    /// owner "Restart Supervisor from the menu bar icon"; Restart escalates to
    /// forceTerminate() for exactly the hung app that ignores a polite quit,
    /// so no SIGTERM handler runs, the companion is orphaned, and within one
    /// tick it saw getppid()==1 with no deploy marker. The owner got
    /// "Supervisor stopped" and then "recovered" for doing what they were
    /// told, which is the fastest way to teach someone to mute the channel.
    func testMenuBarRestartIsExemptFromTheDeathPage() {
        XCTAssertEqual(
            Pager.reparentAction(deployMarkerPresent: false, restartMarkerPresent: true),
            .exitQuietly(reason: "intentional-restart marker present (menu bar Restart)")
        )
    }

    /// The exemption is exactly as wide as the two deliberate kills and no
    /// wider: absent both markers, an unexplained death still pages.
    func testNeitherMarkerStillPages() {
        XCTAssertEqual(
            Pager.reparentAction(deployMarkerPresent: false, restartMarkerPresent: false),
            .pageStoppedThenExit
        )
    }

    /// Both markers present (a Restart racing a deploy) is still one quiet
    /// exit, not two decisions.
    func testDeployMarkerWinsWhenBothArePresent() {
        XCTAssertEqual(
            Pager.reparentAction(deployMarkerPresent: true, restartMarkerPresent: true),
            .exitQuietly(reason: "self-rebuild marker present (deploy relaunch)")
        )
    }

    func testStartupRecoveryFiresOnlyWhenAnIncidentMarkerSurvived() {
        // The dying companion cannot see the future; the marker hands the
        // recovery page to the next instance.
        XCTAssertEqual(
            Pager.startupRecoveryPage(incidentMarkerPresent: true, failedPageMarkerPresent: false),
            .recovered
        )
        XCTAssertNil(
            Pager.startupRecoveryPage(incidentMarkerPresent: false, failedPageMarkerPresent: false),
            "no marker means no unconfirmed death page; a recovery page would confuse"
        )
    }

    func testStartupFailedPageMarkerSendsTheOneCombinedPage() {
        // The failed-page marker means the owner never heard about the
        // outage: one combined stopped-earlier-and-recovered page, and it
        // wins over the incident marker when both survived (its copy
        // already covers the recovery).
        XCTAssertEqual(
            Pager.startupRecoveryPage(incidentMarkerPresent: false, failedPageMarkerPresent: true),
            .missedOutageRecovered
        )
        XCTAssertEqual(
            Pager.startupRecoveryPage(incidentMarkerPresent: true, failedPageMarkerPresent: true),
            .missedOutageRecovered,
            "one page, not two: the combined copy covers both markers"
        )
    }

    // MARK: - Startup recovery must not outrun the webhook cache

    /// The exact ordering bug. `startPolling` enqueues the cache warm on the
    /// serial poll queue and arms the tick timer at `.now()`; the warm blocks
    /// on a semaphore while the Keychain read runs elsewhere and only then
    /// hops its RESULT back to that same queue, so FIFO guarantees tick #1
    /// runs FIRST. Recovery therefore saw an unresolved cache. It must wait,
    /// not consume the markers, or the "Supervisor was down" page is lost on
    /// precisely the launch that exists to send it.
    func testFirstGreenTickBeforeTheCacheResolvesMustWaitNotConsume() {
        XCTAssertEqual(
            Pager.startupRecoveryReadiness(webhookCacheResolved: false, greenTicksWaited: 0),
            .waitForWebhookCache,
            "tick #1 always lands before the warm's hop-back; consuming there is the bug"
        )
    }

    func testRecoveryRunsAsSoonAsTheCacheResolves() {
        XCTAssertEqual(
            Pager.startupRecoveryReadiness(webhookCacheResolved: true, greenTicksWaited: 0),
            .proceed(cacheResolved: true),
            "a resolved cache needs no further waiting, even on the very first green tick"
        )
        XCTAssertEqual(
            Pager.startupRecoveryReadiness(webhookCacheResolved: true, greenTicksWaited: 3),
            .proceed(cacheResolved: true)
        )
    }

    /// The wait is bounded. A Keychain prompt nobody is present to answer
    /// never resolves, and a marker held forever would fire days late on some
    /// future launch, which this codebase already judges worse than a missing
    /// page. The `cacheResolved: false` arm is what the companion traces.
    func testTheWaitIsBoundedAndSaysSoWhenItTimesOut() {
        let bound = Pager.startupRecoveryMaxWaitTicks
        XCTAssertEqual(
            Pager.startupRecoveryReadiness(webhookCacheResolved: false, greenTicksWaited: bound - 1),
            .waitForWebhookCache
        )
        XCTAssertEqual(
            Pager.startupRecoveryReadiness(webhookCacheResolved: false, greenTicksWaited: bound),
            .proceed(cacheResolved: false),
            "past the bound recovery runs anyway, flagged so the trace is honest about it"
        )
        XCTAssertGreaterThanOrEqual(Double(bound) * 2.0, 30.0,
                                    "at the 2s cadence the wait must comfortably clear the companion's own 10s warm bound")
    }

    func testDeathMarkerFlavorFollowsTheAttempt() {
        XCTAssertEqual(Pager.deathMarker(after: .delivered), .incident)
        XCTAssertEqual(Pager.deathMarker(after: .failed), .failedPage,
                       "a page that never left the machine is an outage the owner never heard of")
        XCTAssertEqual(Pager.deathMarker(after: .unconfirmed), .failedPage,
                       "a hung attempt confirmed nothing; the owner has no confirmed word either way")
        XCTAssertEqual(Pager.deathMarker(after: .suppressed), Pager.DeathMarker.none,
                       "the owner's switch said silence; a marker would page them later anyway")
    }

    func testDeathAttemptConclusionGuardsReentryButKeepsTheFreeRetry() {
        XCTAssertTrue(Pager.deathAttemptConcluded(.delivered))
        XCTAssertTrue(Pager.deathAttemptConcluded(.unconfirmed),
                      "the hung attempt may have landed; a coalesced tick must not double-page one death")
        XCTAssertTrue(Pager.deathAttemptConcluded(.suppressed))
        XCTAssertFalse(Pager.deathAttemptConcluded(.failed),
                       "a clean failure sent nothing, so a coalesced tick before exit may retry")
    }

    func testDeathMessageCopyRules() {
        let (title, body) = Pager.deathMessage(hostname: "rayeds-mac-mini.local")
        XCTAssertEqual(title, "Supervisor stopped on rayeds-mac-mini.local")
        XCTAssertFalse(title.contains("/"), "no paths in a page title: \(title)")
        XCTAssertFalse(body.contains("/Users"), "no paths in a page body: \(body)")
        XCTAssertFalse(title.contains("\u{2014}"), "no em dashes in user-facing copy")
        XCTAssertFalse(body.contains("\u{2014}"), "no em dashes in user-facing copy")
        // The companion exits with the app, so the body must not point at a
        // menu bar icon that is no longer there.
        XCTAssertFalse(body.contains("menu bar"), body)
        XCTAssertEqual(Pager.deathPageKind, "supervisor_stopped")
    }

    func testIncidentMarkerContentsRecordWhatWasPaged() {
        let contents = Pager.incidentMarkerContents(kind: Pager.deathPageKind, at: t0)
        XCTAssertTrue(contents.hasPrefix("supervisor_stopped "), contents)
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    // MARK: - Message copy

    func testMessagesCarryTheHostnameAndNoPaths() {
        for page in [Pager.Page.engineStopped(reason: "heartbeat stale (31s)"), .engineHung, .recovered, .missedOutageRecovered] {
            let (title, body) = Pager.message(for: page, hostname: "rayeds-mac-mini.local")
            XCTAssertTrue(title.contains("rayeds-mac-mini.local"), title)
            XCTAssertFalse(title.contains("/"), "no paths in a page title: \(title)")
            XCTAssertFalse(body.contains("/Users"), "no paths in a page body: \(body)")
            XCTAssertFalse(title.contains("\u{2014}"), "no em dashes in user-facing copy")
            XCTAssertFalse(body.contains("\u{2014}"), "no em dashes in user-facing copy")
        }
        XCTAssertEqual(Pager.Page.engineStopped(reason: "x").kind, "engine_stopped")
        XCTAssertEqual(Pager.Page.engineHung.kind, "engine_hung")
        XCTAssertEqual(Pager.Page.recovered.kind, "engine_recovered")
        XCTAssertEqual(Pager.Page.missedOutageRecovered.kind, "supervisor_missed_outage")
    }

    // MARK: - postSystemMessage (the delivery the page rides on)

    private func makeSystemNotifier(
        enabled: Bool = true,
        transport: RemoteNotifierTests.StubTransport = RemoteNotifierTests.StubTransport(),
        clock: RemoteNotifierTests.TestClock = RemoteNotifierTests.TestClock()
    ) throws -> (RemoteNotifier, RemoteNotifierTests.StubTransport, RemoteNotifierTests.TestClock) {
        let notifier = RemoteNotifier(
            endpoint: try RemoteWebhookURL(validating: "https://discord.com/api/webhooks/1/token"),
            configuration: .init(enabled: enabled, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-pager-\(UUID()).log")),
            now: { [clock] in clock.now }
        )
        return (notifier, transport, clock)
    }

    func testSystemMessageRespectsTheEnabledSwitch() async throws {
        let (notifier, transport, _) = try makeSystemNotifier(enabled: false)
        let outcome = await notifier.postSystemMessage(
            title: "Supervisor engine stopped on host", body: "b", kind: "engine_stopped"
        )
        XCTAssertEqual(outcome, .skippedDeniedSilently)
        XCTAssertEqual(transport.callCount, 0,
                       "the companion inherits the app's off switch; off means nothing on the wire")
    }

    func testSystemMessageWithoutAnEndpointFailsInsteadOfStampingComplete() async {
        // enabled=false is the owner saying no (skip, stamp complete —
        // retrying changes nothing). An EMPTY endpoint slot is different:
        // the owner may have a URL stored that has not reached this
        // notifier yet (boot warm timed out; the 5-minute refresh fills it
        // later), so the caller's retry ladder must keep the page alive.
        let transport = RemoteNotifierTests.StubTransport()
        let notifier = RemoteNotifier(
            endpoint: nil,
            configuration: .init(enabled: true, retryDelay: 0),
            transport: transport,
            redactor: DefaultRedactor(),
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-pager-\(UUID()).log"))
        )
        let outcome = await notifier.postSystemMessage(
            title: "Supervisor engine stopped on host", body: "b", kind: "engine_stopped"
        )
        XCTAssertEqual(outcome, .failed(reason: "no_endpoint"))
        XCTAssertEqual(transport.callCount, 0, "nothing to POST to; failed, not attempted")
        XCTAssertEqual(notifier.deliveryHealth.consecutiveFailures, 0,
                       "a gate says nothing about whether sending works; delivery health stays untouched")
    }

    func testSystemMessageDeliversInTheEndpointFormat() async throws {
        let (notifier, transport, _) = try makeSystemNotifier()
        let outcome = await notifier.postSystemMessage(
            title: "Supervisor engine stopped on host",
            body: "Supervision is down.",
            kind: "engine_stopped"
        )
        XCTAssertEqual(outcome, .posted)
        let json = String(decoding: try XCTUnwrap(transport.sent.first).body, as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"content\":"), "discord endpoint gets a discord body: \(json)")
        XCTAssertTrue(json.contains("Supervisor engine stopped on host"), json)
    }

    func testSystemDedupeWindowIsPerKindAndPerCallWindow() async throws {
        let (notifier, transport, clock) = try makeSystemNotifier()
        // Same kind inside the window: suppressed. Different kind: goes.
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped", dedupeWindow: 300)
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped", dedupeWindow: 300)
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_recovered", dedupeWindow: 300)
        XCTAssertEqual(transport.callCount, 2)
        // Past the window the same kind goes again.
        clock.advance(301)
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped", dedupeWindow: 300)
        XCTAssertEqual(transport.callCount, 3)
    }

    func testSystemZeroWindowNeverSuppresses() async throws {
        let (notifier, transport, _) = try makeSystemNotifier()
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped")
        _ = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped")
        XCTAssertEqual(transport.callCount, 2)
    }

    func testSystemFailureDoesNotStampTheWindow() async throws {
        let transport = RemoteNotifierTests.StubTransport(results: [.success(500), .success(500), .success(204)])
        let (notifier, _, _) = try makeSystemNotifier(transport: transport)
        let dropped = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped", dedupeWindow: 3600)
        XCTAssertEqual(dropped, .failed(reason: "http_500"))
        let retried = await notifier.postSystemMessage(title: "t", body: "b", kind: "engine_stopped", dedupeWindow: 3600)
        XCTAssertEqual(retried, .posted,
                       "a failed page must not burn the window; the next transition's page has to arrive")
    }
}
