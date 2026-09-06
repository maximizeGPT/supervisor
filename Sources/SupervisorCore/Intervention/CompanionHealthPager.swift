// CompanionHealthPager.swift. When the engine's health turns bad, decide
// whether the SURVIVOR should page the owner's phone.
//
// The status-bar companion exists because the main app cannot report its own
// death: a crashed or hung Supervisor shows red/amber in the menu bar only
// because a separate process polls heartbeat.txt. But a menu-bar icon is a
// banner-grade surface — it helps only if someone is looking at the Mac, and
// the whole premise of Supervisor is that nobody is. So the companion is
// also the one process that can PAGE the owner about a dead engine: the
// remote escalation channel normally rides inside the main app, and the
// main app is exactly what just stopped.
//
// This type is only the DECISION, kept pure so the transition rules are
// exhaustively testable without a menu bar, a timer, or a network:
//
//   red, sustained >= 60s           page once ("engine stopped"). Staleness
//                                   red is circumstantial (a stalled writer,
//                                   a busy disk, a wake mid-catch-up), so it
//                                   must persist before it pages; the
//                                   DEFINITIVE stop signal is the reparent
//                                   path (see reparentAction), which does
//                                   not ride this state machine at all.
//   amber or red, degraded > 2m     page once ("engine hung"). Red ticks
//                                   count toward the degraded run, so a
//                                   stall that flaps between amber and red
//                                   without ever holding red for 60s still
//                                   gets the 2-minute verdict it deserves.
//   hung, then sustained red        page once more (the hang became a death;
//                                   that is an escalation, not a repeat)
//   anything -> green               one recovery message, only if a page
//                                   went out for this incident
//   before the first green          never page. The companion boots into
//                                   red("starting") and may be running
//                                   against an app that is still launching
//                                   (or was already dead when the OWNER
//                                   opened just the icon); paging on a
//                                   transition we never saw the good side
//                                   of would fire on every boot.
//
// One page per TRANSITION, never per tick: the caller feeds every poll tick
// through `step` and sends only when a `page` comes back; the state carries
// which incident was already paged so a red that stays red for an hour
// produces exactly one message.

import Foundation

public enum CompanionHealthPager {

    /// How long a degraded (amber OR red) run must persist before it is
    /// treated as a hang worth paging. Degradation is routinely transient
    /// (a busy main thread, a slow disk); two minutes of it is not.
    public static let sustainedAmberSeconds: TimeInterval = 120

    /// How long red must hold CONTINUOUSLY before the staleness path calls
    /// it a stop. Staleness crosses the 10-30s amber band into red in 20s,
    /// so an instant-red page turns any 31s main-thread stall into a
    /// "stopped" + "recovered" pair on the owner's phone. Sixty seconds of
    /// unbroken red is a writer that is genuinely not coming back on its
    /// own; the actually-crashed app never waits this long, because the
    /// reparent path pages within one tick.
    public static let sustainedRedSeconds: TimeInterval = 60

    /// Per-kind dedupe window the companion passes with each health page.
    /// The state machine already guarantees one page per transition; this is
    /// the belt over those braces for a health signal flapping faster than
    /// the thresholds (stop, recover, stop inside minutes pages the first
    /// pair and swallows the echo).
    public static let healthPageDedupeWindow: TimeInterval = 300

    /// What the caller should send, if anything.
    public enum Page: Equatable, Sendable {
        /// green -> red: the process tree (or the engine token) is gone.
        case engineStopped(reason: String)
        /// green -> amber sustained past the threshold: alive but not moving.
        case engineHung
        /// Back to green after a page went out.
        case recovered
        /// Startup-only combined page: a previous instance died, its death
        /// page never confirmed delivery (the failed-page marker survived),
        /// and the replacement is now green. One message covers both the
        /// outage the owner never heard about and the recovery. Never
        /// emitted by `step` — only by `startupRecoveryPage`.
        case missedOutageRecovered

        /// Stable wire/log tag, used as the system-message dedupe kind.
        public var kind: String {
            switch self {
            case .engineStopped:         return "engine_stopped"
            case .engineHung:            return "engine_hung"
            case .recovered:             return "engine_recovered"
            case .missedOutageRecovered: return "supervisor_missed_outage"
            }
        }
    }

    /// Which incident has already been paged. Ranked: a hang can escalate
    /// into a stop (one more page), a stop never de-escalates into a hang.
    public enum PagedIncident: Equatable, Sendable {
        case hung
        case stopped
    }

    /// The little ledger the caller holds between ticks.
    public struct State: Equatable, Sendable {
        /// Pages are armed only after the first green: a transition needs a
        /// good side, and the companion boots into red("starting").
        public var hasSeenGreen: Bool
        /// When the current uninterrupted DEGRADED (amber or red) run began.
        /// nil while green. Red counts, so a stall flapping between amber
        /// and red still accumulates toward the 2-minute hung verdict.
        public var degradedSince: Date?
        /// When the current uninterrupted RED run began. nil outside red;
        /// broken by a single amber or green tick, because "sustained red"
        /// means red that never let up.
        public var redSince: Date?
        /// The incident already DELIVERED for, nil when none is live. Only a
        /// confirmed delivery stamps this (see `delivered`): stamping on
        /// intent meant a page that never left the machine was marked sent
        /// forever, and the owner's phone stayed silent about a dead engine.
        public var pagedIncident: PagedIncident?
        /// The page decided but not yet confirmed delivered. Emission,
        /// retries and drops all revolve around this.
        public var pending: Page?
        /// True while an attempt for `pending` is in flight. `step` never
        /// re-emits while set; the executor clears it via `delivered` /
        /// `deliveryFailed`.
        public var awaitingResult: Bool
        /// Failed attempts for `pending` so far. Drives the retry backoff.
        public var failedAttempts: Int
        /// No re-attempt before this time. nil = attempt immediately.
        public var nextAttemptAt: Date?

        public init(
            hasSeenGreen: Bool = false,
            degradedSince: Date? = nil,
            redSince: Date? = nil,
            pagedIncident: PagedIncident? = nil,
            pending: Page? = nil,
            awaitingResult: Bool = false,
            failedAttempts: Int = 0,
            nextAttemptAt: Date? = nil
        ) {
            self.hasSeenGreen = hasSeenGreen
            self.degradedSince = degradedSince
            self.redSince = redSince
            self.pagedIncident = pagedIncident
            self.pending = pending
            self.awaitingResult = awaitingResult
            self.failedAttempts = failedAttempts
            self.nextAttemptAt = nextAttemptAt
        }
    }

    /// Feed one poll tick through the machine. Returns the new state and,
    /// at most, one page the caller should ATTEMPT to deliver now. The
    /// attempt's outcome must come back through `delivered` /
    /// `deliveryFailed` — only a confirmed delivery stamps the incident as
    /// paged; a failed one retries on later ticks with bounded backoff.
    public static func step(
        state: State,
        health: HeartbeatHealth,
        now: Date
    ) -> (state: State, page: Page?) {
        var next = state
        // Phase 1: update the run clocks and decide what OUGHT to be
        // pending. Nothing is emitted here; emission (with its in-flight
        // and backoff gates) is phase 2, shared by every branch.
        switch health {
        case .green:
            next.hasSeenGreen = true
            next.degradedSince = nil
            next.redSince = nil
            // An undelivered incident page overtaken by recovery is dropped:
            // the blip healed before the owner ever heard of it, and a
            // late "stopped" about a running engine is a false alarm.
            if let pending = state.pending, pending != .recovered {
                next = clearingPending(next)
            }
            // A DELIVERED incident needs its recovery page; keep the
            // incident stamped until that page actually lands, so a failed
            // recovery send retries instead of vanishing.
            if next.pagedIncident != nil, next.pending == nil {
                next = settingPending(next, .recovered)
            }

        case .amber:
            guard state.hasSeenGreen else { return (next, nil) }
            next.redSince = nil  // an amber tick breaks a red run
            let since = state.degradedSince ?? now
            next.degradedSince = since
            // A pending recovery overtaken by relapse: the incident is not
            // over, so the "all clear" must not go out. The incident stamp
            // (still set) keeps the dedupe story straight.
            if state.pending == .recovered {
                next = clearingPending(next)
            }
            // Strictly past the threshold, so "exactly 2 minutes" on a 2s
            // poll cadence still needs one more bad tick — sustained means
            // sustained.
            if now.timeIntervalSince(since) > sustainedAmberSeconds,
               state.pagedIncident == nil, next.pending == nil {
                next = settingPending(next, .engineHung)
            }

        case .red(let reason):
            guard state.hasSeenGreen else { return (next, nil) }
            let degraded = state.degradedSince ?? now
            let red = state.redSince ?? now
            next.degradedSince = degraded
            next.redSince = red
            if state.pending == .recovered {
                next = clearingPending(next)
            }
            // Sustained red is a stop: the writers held still for a full
            // minute and are not coming back on their own. Escalates a
            // paged (or pending) hang, never repeats a stop already
            // delivered or already pending.
            let stopAlreadyPending: Bool = {
                if case .engineStopped = next.pending { return true }
                return false
            }()
            if now.timeIntervalSince(red) >= sustainedRedSeconds,
               state.pagedIncident != .stopped, !stopAlreadyPending {
                next = settingPending(next, .engineStopped(reason: reason))
            } else if now.timeIntervalSince(degraded) > sustainedAmberSeconds,
                      state.pagedIncident == nil, next.pending == nil {
                // Sub-sustained red rides the same 2-minute hung path as
                // amber: a transient stall gets the grace the threshold was
                // designed to give, instead of paging the instant staleness
                // crosses 30s.
                next = settingPending(next, .engineHung)
            }
        }

        // Phase 2: emission. One attempt at a time, and a failed one waits
        // out its backoff before the next.
        if let pending = next.pending, !next.awaitingResult,
           next.nextAttemptAt.map({ now >= $0 }) ?? true {
            next.awaitingResult = true
            return (next, pending)
        }
        return (next, nil)
    }

    /// The executor confirmed `page` reached the endpoint (or was gated off
    /// by the owner's own switch, which is the same thing for bookkeeping:
    /// the decision completed). Stamps the incident ledger and clears the
    /// pending slot when it still holds this page — it may have been
    /// upgraded while the POST was in flight, in which case the stronger
    /// page stays pending and goes out next tick.
    public static func delivered(state: State, page: Page) -> State {
        var next = state
        next.awaitingResult = false
        switch page {
        case .engineStopped:
            next.pagedIncident = .stopped
        case .engineHung:
            // Never downgrade a delivered stop to a hang (a late hung
            // delivery after an escalation must not reopen the stop).
            if next.pagedIncident == nil { next.pagedIncident = .hung }
        case .recovered, .missedOutageRecovered:
            next.pagedIncident = nil
        }
        if next.pending == page {
            next = clearingPending(next)
        }
        return next
    }

    /// The executor could not deliver `page`. Schedule the retry: 30s after
    /// the first failure, 60s after the second, then hold at 5 minutes —
    /// bounded pressure, never a per-tick hammer, and the incident stays
    /// unstamped so the page keeps trying for as long as it stays true.
    public static func deliveryFailed(state: State, page: Page, now: Date) -> State {
        var next = state
        next.awaitingResult = false
        guard next.pending == page else { return next }
        next.failedAttempts += 1
        next.nextAttemptAt = now.addingTimeInterval(retryDelay(afterFailures: next.failedAttempts))
        return next
    }

    /// Backoff ladder for failed deliveries. See `deliveryFailed`.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        switch failures {
        case ..<2: return 30
        case 2:    return 60
        default:   return 300
        }
    }

    /// A new page decision replaces whatever was pending and starts a fresh
    /// attempt ladder (a more urgent page deserves an immediate attempt).
    private static func settingPending(_ state: State, _ page: Page) -> State {
        var next = state
        next.pending = page
        next.failedAttempts = 0
        next.nextAttemptAt = nil
        return next
    }

    private static func clearingPending(_ state: State) -> State {
        var next = state
        next.pending = nil
        next.failedAttempts = 0
        next.nextAttemptAt = nil
        return next
    }

    // MARK: - Sleep/wake grace

    /// The companion's poll cadence, shared with the wake heuristic below.
    public static let tickCadenceSeconds: TimeInterval = 2

    /// A gap between consecutive ticks past this means the machine was
    /// almost certainly asleep (a dispatch timer never skips 2.5x its own
    /// cadence while running). All the health ages are wall-clock file
    /// mtimes, so the first ticks after a wake see every file "stale" until
    /// the writers catch up — verdicts made from that window are noise.
    public static let wakeGapThresholdSeconds: TimeInterval = 5

    /// How long to hold verdicts after a detected wake: one full heartbeat
    /// refresh cycle with margin, so both writers (the heartbeat child and
    /// the engine's progress token) get a chance to stamp fresh times.
    public static let wakeGraceSeconds: TimeInterval = 12

    /// If the tick gap says the machine slept, the deadline until which the
    /// caller should suppress pager verdicts. nil on a normal cadence tick.
    public static func wakeSuppressionDeadline(lastTickAt: Date?, now: Date) -> Date? {
        guard let lastTickAt, now.timeIntervalSince(lastTickAt) > wakeGapThresholdSeconds else { return nil }
        return now.addingTimeInterval(wakeGraceSeconds)
    }

    /// Reset the run clocks after a wake: continuity across a sleep is
    /// fiction (a 10s amber run before an 8h sleep is not a 8h-10s hang),
    /// so the degraded and red runs start over. What was already PAGED
    /// stays paged — sleep does not forget an open incident, or a recovery
    /// after wake would go unannounced.
    public static func wakeReset(_ state: State) -> State {
        var next = state
        next.degradedSince = nil
        next.redSince = nil
        return next
    }

    // MARK: - Webhook cache refresh (C3a)

    /// The cache's next value after a periodic Keychain re-read. A FAILED
    /// read keeps the current cache — a transient Keychain error must not
    /// wipe a URL the death page may need seconds later. A read that
    /// SUCCEEDED replaces the cache, nil included: the owner deleted the
    /// URL and the cache must not resurrect it.
    public static func refreshedWebhookCache(
        readSucceeded: Bool,
        readValue: String?,
        current: String?
    ) -> String? {
        readSucceeded ? readValue : current
    }

    // MARK: - Reparent death (the definitive stopped signal)

    /// What the companion should do when it finds itself reparented to
    /// launchd (getppid()==1): its parent — the main app — is gone. This is
    /// the DEFINITIVE death signal, and it arrives within one 2s tick,
    /// long before heartbeat staleness (30s) could: without acting here the
    /// companion exits before the staleness path ever fires, and the C1
    /// headline case ("Supervisor crashed while I was away") pages never.
    ///
    /// The one deliberate kill this must not page on is a deploy: the deploy
    /// step writes the self-rebuild marker, pkills the running app, and
    /// relaunches the fresh build — a page there would cry wolf on every
    /// update. The marker's presence is the tell.
    public enum ReparentAction: Equatable, Sendable {
        /// Deploy in progress: the kill was deliberate and a relaunch is
        /// seconds away. Exit without paging, as before.
        case exitQuietly(reason: String)
        /// Real death: attempt ONE bounded page ("Supervisor stopped"),
        /// record the incident in the marker file if it delivered, then exit.
        case pageStoppedThenExit
    }

    /// Two deliberate kills are exempt, and only two.
    ///
    /// The restart exemption is not a nicety. The hung-engine page tells the
    /// owner "Restart Supervisor from the menu bar icon"; Restart escalates to
    /// `forceTerminate()` for exactly the hung app that ignores a polite quit,
    /// so no SIGTERM handler runs and this companion is orphaned. Within one
    /// tick it saw `getppid() == 1` with no deploy marker and paged
    /// "Supervisor stopped", then "recovered". Following the instructions
    /// produced a false outage report.
    public static func reparentAction(
        deployMarkerPresent: Bool,
        restartMarkerPresent: Bool = false
    ) -> ReparentAction {
        if deployMarkerPresent {
            return .exitQuietly(reason: "self-rebuild marker present (deploy relaunch)")
        }
        if restartMarkerPresent {
            return .exitQuietly(reason: "intentional-restart marker present (menu bar Restart)")
        }
        return .pageStoppedThenExit
    }

    /// Stable wire/log tag for the reparent death page. Distinct from
    /// `engine_stopped` (a staleness verdict about the engine) because this
    /// one is about the whole app process being gone.
    public static let deathPageKind = "supervisor_stopped"

    /// The reparent death page. Same copy rules as `message(for:hostname:)`:
    /// hostname only, no paths, no em dashes. The body does not point at the
    /// menu bar icon — the companion exits with the app, so there is none.
    public static func deathMessage(hostname: String) -> (title: String, body: String) {
        (
            "Supervisor stopped on \(hostname)",
            "The Supervisor app exited. Sessions are not being watched. Open Supervisor again when you are back."
        )
    }

    /// How the one bounded exit-path attempt at the death page ended, as the
    /// executor observed it. The pure functions below turn this into the
    /// marker to leave behind and the re-entry rule for coalesced ticks.
    public enum DeathPageAttempt: Equatable, Sendable {
        /// The endpoint confirmed delivery (2xx).
        case delivered
        /// The attempt concluded and did NOT deliver: transport/HTTP failure,
        /// or no usable webhook in the boot cache. Nothing left the machine.
        case failed
        /// The bounded wait expired with the attempt still in flight. The
        /// page may or may not have landed; nobody can say.
        case unconfirmed
        /// The owner's remote_notify switch is off. Silence is the ask.
        case suppressed
    }

    /// Which marker the dying companion leaves for the next instance.
    public enum DeathMarker: Equatable, Sendable {
        /// The stopped page went out: leave the incident marker so the next
        /// instance sends the recovery page on its first green.
        case incident
        /// The owner never (confirmably) heard about the outage: leave the
        /// failed-page marker so the next instance sends the combined
        /// "stopped earlier and has recovered" page on its first green.
        case failedPage
        /// No marker. The owner's switch said no; a marker would turn that
        /// silence into a page later.
        case none
    }

    public static func deathMarker(after attempt: DeathPageAttempt) -> DeathMarker {
        switch attempt {
        case .delivered:            return .incident
        case .failed, .unconfirmed: return .failedPage
        case .suppressed:           return .none
        }
    }

    /// Whether the death handling is CONCLUDED, i.e. a coalesced later tick
    /// (the exit races the poll timer) must not run another attempt. A clean
    /// failure is the one open case: nothing left the machine, so one free
    /// retry per remaining tick is safe. An UNCONFIRMED (hung) attempt is
    /// concluded — the page may have landed, and a re-entry could double-page
    /// the owner about one death.
    public static func deathAttemptConcluded(_ attempt: DeathPageAttempt) -> Bool {
        switch attempt {
        case .delivered, .unconfirmed, .suppressed: return true
        case .failed:                               return false
        }
    }

    /// The dying companion cannot send the recovery page (it exits now, and
    /// recovery is in the future), so the NEXT instance closes the loop on
    /// its first green tick:
    ///   - a leftover incident marker means "a stopped page went out and
    ///     nobody said it recovered" — send the recovery page;
    ///   - a leftover FAILED-page marker means the owner never heard about
    ///     the outage at all — send the one combined stopped-earlier-and-
    ///     recovered page instead. It wins over the incident marker when
    ///     both survived (its copy already covers the recovery).
    /// The caller deletes both markers either way. Before the first green
    /// there is nothing to announce (the replacement may itself still be
    /// starting, or dead).
    public static func startupRecoveryPage(
        incidentMarkerPresent: Bool,
        failedPageMarkerPresent: Bool
    ) -> Page? {
        if failedPageMarkerPresent { return .missedOutageRecovered }
        return incidentMarkerPresent ? .recovered : nil
    }

    /// Marker-file contents: what was paged and when, for the trace log.
    /// Only the file's PRESENCE drives behavior, so this never needs parsing.
    public static func incidentMarkerContents(kind: String, at date: Date) -> String {
        "\(kind) \(ISO8601DateFormatter().string(from: date))\n"
    }

    // MARK: - When startup recovery may consume its markers

    /// Whether the first green tick may run startup recovery yet.
    ///
    /// The bug this exists for: the companion enqueues the webhook cache warm
    /// on the serial poll queue and then arms the tick timer at `.now()`. The
    /// warm blocks on a semaphore while the Keychain read runs on a global
    /// queue and only afterwards hops its RESULT back to the poll queue, so
    /// FIFO puts tick #1 ahead of the assignment. Startup recovery therefore
    /// ran with an empty cache, found no endpoint, and DELETED the markers
    /// with no retry. The one page that says "Supervisor was down while you
    /// were away" was lost on precisely the launch that existed to send it.
    ///
    /// So: hold the markers until the cache has resolved. Bounded, because a
    /// Keychain prompt nobody is present to answer never resolves, and a
    /// marker held forever would fire days late on some future launch. The
    /// codebase already prefers a missing page over a stale one.
    public enum StartupRecoveryReadiness: Equatable, Sendable {
        /// The webhook cache has not resolved yet. Leave the markers alone.
        case waitForWebhookCache
        /// Run recovery now. `cacheResolved` is false only when the wait
        /// timed out, which the caller traces: the page is about to be
        /// attempted against a cache that never arrived.
        case proceed(cacheResolved: Bool)
    }

    /// Green ticks the recovery check may spend waiting for the cache. At the
    /// 2s poll cadence this is 30s, three times the companion's own 10s bound
    /// on the boot warm, so every read that is going to return has.
    public static let startupRecoveryMaxWaitTicks = 15

    public static func startupRecoveryReadiness(
        webhookCacheResolved: Bool,
        greenTicksWaited: Int
    ) -> StartupRecoveryReadiness {
        if webhookCacheResolved { return .proceed(cacheResolved: true) }
        if greenTicksWaited >= startupRecoveryMaxWaitTicks { return .proceed(cacheResolved: false) }
        return .waitForWebhookCache
    }

    // MARK: - Message copy (one place, shared with tests)

    /// The minimal page bodies. Hostname (never a path, never session data)
    /// so an owner with two Macs knows which one went quiet. Watched-session
    /// count is deliberately absent: it lives in SQLite, and the status bar
    /// stays database-blind — opening the DB from a second process to
    /// decorate a death notice is not worth the coupling.
    public static func message(for page: Page, hostname: String) -> (title: String, body: String) {
        switch page {
        case .engineStopped(let reason):
            return (
                "Supervisor engine stopped on \(hostname)",
                "Supervision is down (\(reason)). Sessions are not being watched. Restart Supervisor from the menu bar icon when you are back."
            )
        case .engineHung:
            return (
                "Supervisor engine hung on \(hostname)",
                "The Supervisor process is alive but its engine has not made progress for over 2 minutes. Sessions are not being watched. Restart Supervisor from the menu bar icon."
            )
        case .recovered:
            return (
                "Supervisor engine recovered on \(hostname)",
                "Supervision is running again. No action needed."
            )
        case .missedOutageRecovered:
            return (
                "Supervisor recovered on \(hostname)",
                "Supervisor stopped earlier and the page could not be sent at the time. It has recovered and is running again. No action needed."
            )
        }
    }
}
