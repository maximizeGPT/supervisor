// HoverViewModel.swift
//
// Drives the always-on-top hover window. Subscribes to EventBus +
// a "flag arrived" callback wired by the main app, exposes published
// properties the SwiftUI view binds to.
//
// One viewmodel per process. v0.1.0 follows a "show the most recently
// active session" rule — no session picker yet. Multi-session UI is
// v0.1.2.
//
// v0.1.7: expanded panel support. The viewmodel now tracks session
// metrics (turn count, tool call count) and holds references to
// CostStore + FlagStore for the expanded panel's data needs.

import Combine
import Foundation

@MainActor
public final class HoverViewModel: ObservableObject {

    public enum Activity: Sendable, Equatable {
        case idle
        case triaging
        /// Carries severity (dot color), action (overlay icon), the triage's
        /// plain-voice reasoning (hover headline), and — crucially for the
        /// pause/resume pin — the identity (id + cwd) of the session the engine
        /// actually flagged. On a multi-session machine the flagged session is
        /// frequently NOT the most-recently-started one, so the engine threads
        /// its identity here rather than letting the hover guess from
        /// `currentSessionId` (Finding 5). Both default nil for the single-
        /// session path and older callers, which fall back to `currentSessionId`.
        case flagged(severity: FlagSeverity, action: FlagAction, reasoningPlain: String? = nil, sessionId: String? = nil, sessionCwd: String? = nil)
    }

    // MARK: - Published surface

    /// Plain-language headline a non-engineer can read at a glance.
    /// Examples: "Watching. All clear", "Paused Claude Code — needs
    /// your attention", "Checking something..."
    @Published public private(set) var plainLabel: String = "Watching. All clear"

    /// Secondary detail (de-emphasized). The actual command or tool
    /// name, shown only when there's something specific to surface.
    /// Empty string hides the secondary line.
    @Published public private(set) var detailLabel: String = ""

    /// Cumulative count of flags raised this lifetime. Resets across launches.
    @Published public private(set) var flagCount: Int = 0

    /// How many sessions Supervisor is actively watching right now. The
    /// controller pushes this from SessionDiscovery (the single authority on
    /// "live" sessions) on every visibility pass. The hover stays ONE band: at
    /// 0 or 1 it reads "Watching. All clear" exactly as before; at 2+ it
    /// aggregates ("Watching 3 sessions. All clear") instead of flipping the
    /// label between project names as each session fires an event. Seeing
    /// several busy sessions used to read as several identical generic bands;
    /// the single band now says how many there are.
    @Published public private(set) var watchedSessionCount: Int = 0

    /// Drives the dot color + pulse intensity.
    @Published public private(set) var activity: Activity = .idle

    /// Whether the expanded panel is visible.
    @Published public var isExpanded: Bool = false

    // MARK: - Owner runtime toggles (panel controls)

    /// Global pause — when true, Supervisor is dormant (no triage/dispatch/
    /// inject). Mirrors the RuntimeToggles marker; the panel's Pause button
    /// flips it and the engine reads the marker live, so it takes effect at once.
    @Published public private(set) var supervisorPaused: Bool = RuntimeToggles.supervisorPaused

    /// 4-hour loop-cap disabled — when true, the loop runs without the 4-hour
    /// wall-clock hard stop (for long sessions / the screen-record demo). The
    /// other hard stops still apply.
    @Published public private(set) var loopCapDisabled: Bool = RuntimeToggles.loopCapDisabled

    /// v0.2.0 (Reddit feedback E): the owner's decision-sensitivity setting, ie
    /// how aggressively Supervisor acts on its own vs. escalates to the human.
    /// The panel's segmented control reads + writes this; the setter persists to
    /// UserDefaults so the engine (answer gate) and the planner-loop build
    /// (evaluator threshold) pick it up. Seeded from the persisted value at init;
    /// `.balanced` (the default) is exactly today's behavior.
    @Published public private(set) var decisionSensitivity: DecisionSensitivity = .balanced

    // MARK: - Session metrics (v0.1.7 expanded panel)

    /// Number of assistant turns (user prompt → assistant response cycles).
    @Published public private(set) var turnCount: Int = 0

    /// Number of tool calls observed this session.
    @Published public private(set) var toolCallCount: Int = 0

    /// The triage model name (e.g. "claude-haiku-4-5-20251001").
    @Published public private(set) var modelName: String = ""

    /// The project name (cwd basename) for use in plain labels.
    public private(set) var projectName: String = ""

    /// The full cwd path for the expanded panel header.
    @Published public private(set) var sessionCwd: String = ""

    /// Which agent the current session belongs to, derived from the session's
    /// projectHash on `sessionStart` (Codex sessions are namespaced "codex").
    @Published public private(set) var currentAgent: AgentKind = .claudeCode

    /// True once Supervisor has seen sessions from more than one agent kind.
    /// Gates the agent chip in the UI: a single-agent user sees no new chrome
    /// (progressive disclosure). Monotonic — once you've worked with both, the
    /// chip stays so any session's agent is always legible at a glance.
    @Published public private(set) var isMultiAgent: Bool = false

    /// Agent kinds observed across sessions this run, backing `isMultiAgent`.
    private var seenAgents: Set<AgentKind> = []

    /// The watched session's id (JSONL uuid). Tracked from `sessionStart` so
    /// the panel's live Plan view can read that session's current plan from
    /// PlanStore. Empty until the first session is seen.
    @Published public private(set) var currentSessionId: String = ""

    /// Whether a resume from pause is in progress.
    @Published public private(set) var isResuming: Bool = false

    // MARK: - Context Health (ambient audit surface)

    /// The ambient Context Health monitor, set by the app at construction. `nil`
    /// hides the panel's Context Health section entirely (the feature stays inert
    /// when unwired), so nothing changes for callers that don't opt in. The panel
    /// observes this monitor directly for the live verdict.
    public var contextHealth: ContextHealthMonitor?

    /// Opens the full Context Health window. Set by the app (it owns the window
    /// presenter). The panel's Context Health line calls this on tap.
    public var onOpenContextHealth: (() -> Void)?

    // MARK: - Live pause / kill tracking (RC hardening fix #3, #5)

    /// Whether a pause is currently live. Tracked explicitly and independently
    /// of the transient `activity` (and of whether a session id was known when
    /// the pause was raised), so a later `.sessionStart` for a DIFFERENT session
    /// cannot silently clear or mask it. The panel renders the Resume affordance
    /// and the plan's "Paused" chip from this.
    @Published public private(set) var isPaused: Bool = false

    /// Whether a kill is currently live (a `.kill` flag was raised and not yet
    /// resolved). Folds into the plan StatusChip as "Stopped" so a killed
    /// session never reads as "Running".
    @Published public private(set) var isKilled: Bool = false

    /// The session id that raised the still-live pause, pinned separately from
    /// `currentSessionId` (which tracks the most recently active session). Empty
    /// when nothing is paused. The resume affordance targets THIS session.
    @Published public private(set) var pausedSessionId: String = ""

    /// The cwd of the paused session, captured when the pause was raised so the
    /// resume handler drives the CORRECT session even after another session
    /// becomes the most recently active one.
    @Published public private(set) var pausedSessionCwd: String = ""

    /// Bumped after every store-write action (approvePlan / respondToFlag /
    /// rejectFlag). The expanded panel reads the store through plain methods
    /// (currentPlan / recentFlags / recentActivity); those are not @Published,
    /// so a store write alone would not re-invoke the SwiftUI body. Bumping this
    /// @Published counter fires objectWillChange, SwiftUI re-invokes body, and
    /// the panel re-reads fresh store data. Panel actions therefore reflect
    /// immediately instead of showing stale state (RC fix #1).
    @Published public private(set) var storeRevision: Int = 0

    /// Plan ids the operator approved from the panel this run. The approve
    /// handler is async (it round-trips through TriageEngine + PlanStore to flip
    /// plan.status), so the Approve button disables optimistically off this set
    /// the moment the button is pressed, rather than waiting for the store.
    @Published public private(set) var approvedPlanIds: Set<String> = []

    // MARK: - Action log (v0.8.1 — "what Supervisor DID")

    /// A record of a substantial action Supervisor took.
    public struct ActionRecord: Identifiable, Equatable {
        public let id: String
        public let ts: Date
        public let action: FlagAction
        public let plainDescription: String

        public init(action: FlagAction, plainDescription: String, ts: Date = Date()) {
            self.id = UUID().uuidString
            self.ts = ts
            self.action = action
            self.plainDescription = plainDescription
        }
    }

    /// Recent actions (newest first). Capped at 20.
    @Published public private(set) var recentActions: [ActionRecord] = []

    /// Transient "action flash" — true for a brief moment when Supervisor
    /// takes a substantial action (pause/kill/inject/continue/selfExtend).
    /// Drives a distinct flash animation on the hover dot.
    @Published public private(set) var actionFlash: Bool = false

    /// v0.3.x REVIEW dimension: running count of code-review observations surfaced
    /// this run, and the most recent one's title. Reviews are INFORMATIONAL — they
    /// live in the Review tab (pull), never a banner (push) — so these drive a calm
    /// count/label, NOT the `.flagged` activity or the action flash, which stay
    /// reserved for safety interventions.
    @Published public private(set) var reviewFindingCount: Int = 0
    @Published public private(set) var latestReviewTitle: String = ""

    /// UNSEEN review observations — the quiet "there's something in Review" badge
    /// on the hover band. Increments when a finding surfaces; clears the moment the
    /// owner opens the Review tab (`markReviewsSeen`). A calm, self-clearing dot in
    /// the mute tone — never the amber safety badge, never a push.
    @Published public private(set) var unseenReviewCount: Int = 0

    // MARK: - Dependencies

    private let bus: EventBus
    private let trace: TraceLog
    public let costStore: CostStore?
    public let flagStore: FlagStore?
    /// v0.2.0 M3: the plan store, read by the panel's live Plan view to show
    /// the watched session's current plan. Optional and additive — nil in the
    /// pre-planner path and in tests that don't exercise the Plan view, where
    /// `currentPlan()` simply returns nil and the panel shows its prior content.
    public let planStore: PlanStore?
    /// v0.2.0 observability (Reddit feedback D): the unified audit log, read by
    /// the panel's Activity view to show recent per-action audit entries WITH
    /// their justification (the live "why did it do that"). Optional + additive:
    /// nil in tests / pre-observability installs, where `recentAuditEntries()`
    /// returns [] and the Activity view shows its empty state. Never written
    /// here; the engine records entries (mirrors planStore being read-only here).
    public let auditStore: AuditStore?
    /// v0.3.x REVIEW dimension: the code-review finding ledger, read by the
    /// panel's Review tab to show the watched session's findings with their full
    /// structure (severity / confidence / category / file / why). Optional +
    /// read-only here (the ReviewEngine writes it); nil in tests / when the
    /// feature is off, where `recentReviews()` returns [] and the tab shows its
    /// calm empty state.
    public let reviewStore: ReviewFindingStore?
    private var busCancellable: AnyCancellable?
    private var acknowledgeDebouncerTask: Task<Void, Never>?
    /// Cancels the in-flight "turn the flash off" timer when a newer action
    /// arrives, so back-to-back actions don't clip each other's flash.
    private var flashOffTask: Task<Void, Never>?
    /// How long to hold the flagged state before auto-acknowledging.
    /// Resets on each new flag.
    public let acknowledgeDebounceDuration: TimeInterval

    /// Callback to resume a paused session. Takes cwd, returns true on
    /// success. Wired in main.swift with ProcessLocator + SignalSender.
    public var resumeHandler: ((String) async -> Bool)?

    /// v0.2.0 M3: callback to approve a plan. Takes the plan id; the app wires
    /// it to `TriageEngine.approvePlan(planId:)` (the SAME marked + ledgered
    /// path the approve-plan marker uses), so the panel's "Approve plan" button
    /// goes through the one approval path. nil in tests / pre-planner, where
    /// the action is a logged no-op.
    public var approvePlanHandler: ((String) async -> Void)?

    /// v0.2.0 observability (Reddit feedback D): callback to export the current
    /// session's replay bundle. The app wires it to SessionReportExporter.export
    /// for `currentSessionId` (writing JSON + Markdown to a stable directory) and
    /// returns the written file URLs, which the VM surfaces (path + reveal-in-
    /// Finder). Takes the session id; returns the Output paths, or nil on failure
    /// / when no exporter is wired (tests / pre-observability), in which case the
    /// panel shows nothing rather than a fake success.
    public var exportReportHandler: ((String) async -> SessionReportExporter.Output?)?

    /// The result of the most recent "Export session report" action, surfaced in
    /// the panel: the written Markdown path on success (so the user can see WHERE
    /// the receipt landed), or an error sentinel. nil until the user exports.
    @Published public private(set) var lastExport: ExportResult?

    /// Whether an export is in flight (disables the button + shows progress).
    @Published public private(set) var isExporting: Bool = false

    /// The outcome of an export, for the panel to render.
    public enum ExportResult: Equatable, Sendable {
        /// Success: carries the two written file URLs (Markdown is what we reveal).
        case success(jsonPath: URL, markdownPath: URL)
        /// Failure: the export could not be produced (no session, no handler, or
        /// a write error). Carries a short reason for the panel.
        case failure(reason: String)
    }

    public init(
        bus: EventBus,
        trace: TraceLog = .shared,
        acknowledgeDebounceDuration: TimeInterval = 5.0,
        initialFlagCount: Int = 0,
        costStore: CostStore? = nil,
        flagStore: FlagStore? = nil,
        planStore: PlanStore? = nil,
        auditStore: AuditStore? = nil,
        reviewStore: ReviewFindingStore? = nil,
        modelName: String = ""
    ) {
        self.bus = bus
        self.trace = trace
        self.acknowledgeDebounceDuration = acknowledgeDebounceDuration
        self.flagCount = initialFlagCount
        self.costStore = costStore
        self.flagStore = flagStore
        self.planStore = planStore
        self.auditStore = auditStore
        self.reviewStore = reviewStore
        self.decisionSensitivity = DecisionSensitivityStore.current()
        self.modelName = modelName
        self.busCancellable = bus.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event: event) }
        }
        if initialFlagCount > 0 {
            trace.emit("hover", "seeded flagCount=\(initialFlagCount) from history")
        }
    }

    // MARK: - Expanded panel data

    /// Today's estimated cost from CostStore. Returns 0 if store unavailable.
    public func todayCostUSD() -> Double {
        guard let store = costStore else { return 0 }
        return (try? store.today().estimatedCostUsd) ?? 0
    }

    /// Recent flags from FlagStore, most recent first. Scoped to the watched
    /// session so concurrent sessions don't bleed into one list (RC fix #4);
    /// `recentActivity` already scopes the same way, and mixing them made the
    /// Status tab's Flags list show another session's flags.
    public func recentFlags(limit: Int = 20) -> [StoredFlag] {
        guard let store = flagStore else { return [] }
        let sid = currentSessionId.isEmpty ? nil : currentSessionId
        return (try? store.recent(sessionId: sid, limit: limit)) ?? []
    }

    /// v0.2.0 M3: the watched session's current (latest) plan, or nil when no
    /// plan exists for it (or no PlanStore / no session yet). The panel reads
    /// this each render: when it returns a plan the live Plan view shows;
    /// otherwise the panel falls back to its existing flags/activity content.
    /// A read failure degrades to nil rather than throwing — the panel must
    /// never crash on a transient DB error.
    public func currentPlan() -> Plan? {
        guard let store = planStore, !currentSessionId.isEmpty else { return nil }
        return (try? store.currentPlan(sessionId: currentSessionId)) ?? nil
    }

    /// v0.2.0 observability (Reddit feedback D): the watched session's recent
    /// audit entries (newest first), each carrying its kind + justification (the
    /// auto-answer's question + rule, the block's command + risk, the nudge's
    /// stall classification, the verdict's score + feedback). The Activity view
    /// reads this each render. Returns [] when no AuditStore, no session yet, or
    /// a read fails — the panel must never crash on a transient DB error (mirrors
    /// `currentPlan()`'s nil-safe degrade). Default limit 25 keeps the live
    /// surface skimmable; the export bundle reads the full set separately.
    public func recentAuditEntries(limit: Int = 25) -> [StoredAuditEntry] {
        guard let store = auditStore, !currentSessionId.isEmpty else { return [] }
        return (try? store.entries(sessionId: currentSessionId, limit: limit)) ?? []
    }

    /// Count of audit entries for the watched session (for the section header).
    /// Nil-safe: 0 when no store / no session / a read fails.
    public func auditEntryCount() -> Int {
        guard let store = auditStore, !currentSessionId.isEmpty else { return 0 }
        return (try? store.count(sessionId: currentSessionId)) ?? 0
    }

    // MARK: - Merged activity timeline

    /// A unified timeline item merging audit entries with significant flags, so
    /// the Activity tab reflects what Supervisor actually DID for the session
    /// rather than showing an empty log after a busy watch-only session.
    public enum ActivityItem: Identifiable {
        case audit(StoredAuditEntry)
        case flag(StoredFlag)

        public var id: String {
            switch self {
            case .audit(let e): return "a-\(e.id)"
            case .flag(let f):  return "f-\(f.id)"
            }
        }

        public var date: Date {
            switch self {
            case .audit(let e): return e.createdAt
            case .flag(let f):  return f.ts
            }
        }
    }

    /// Merged activity timeline: audit entries + significant flags (medium/high
    /// severity only, to filter raw triage noise), sorted newest-first. This is
    /// what the Activity tab should show so a watch-only session is not empty.
    public func recentActivity(limit: Int = 30) -> [ActivityItem] {
        let sid = currentSessionId
        guard !sid.isEmpty else { return [] }

        var items: [ActivityItem] = []

        // Audit entries (interventions: auto-answer, block, nudge, verdict, planStep).
        if let store = auditStore {
            let entries = (try? store.entries(sessionId: sid, limit: limit)) ?? []
            items.append(contentsOf: entries.map { .audit($0) })
        }

        // Significant flags (medium/high severity) — the watch-and-flag activity.
        if let store = flagStore {
            let flags = (try? store.recent(sessionId: sid, limit: limit * 2)) ?? []
            let significant = flags.filter { $0.severity == .medium || $0.severity == .high }
            items.append(contentsOf: significant.prefix(limit).map { .flag($0) })
        }

        // Sort newest-first, cap at limit.
        items.sort { $0.date > $1.date }
        if items.count > limit { items = Array(items.prefix(limit)) }
        return items
    }

    /// Cache for `activityCount`, keyed on "<storeRevision>|<sessionId>" so the
    /// expensive flag scan runs once per store revision rather than on every
    /// SwiftUI render (RC fix #7). A store-write action bumps `storeRevision`,
    /// which invalidates the cache.
    private var cachedActivityCount: Int?
    private var cachedActivityCountKey: String = ""

    /// Count of activity items (audit entries + significant flags) for the badge.
    public func activityCount() -> Int {
        let sid = currentSessionId
        guard !sid.isEmpty else { return 0 }
        let key = "\(storeRevision)|\(sid)"
        if key == cachedActivityCountKey, let cached = cachedActivityCount {
            return cached
        }
        var total = 0
        if let store = auditStore {
            total += (try? store.count(sessionId: sid)) ?? 0
        }
        if let store = flagStore {
            let flags = (try? store.recent(sessionId: sid, limit: 500)) ?? []
            total += flags.filter { $0.severity == .medium || $0.severity == .high }.count
        }
        cachedActivityCount = total
        cachedActivityCountKey = key
        return total
    }

    /// v0.2.0 (Reddit feedback E): set the owner's decision-sensitivity. Persists
    /// to UserDefaults (survives relaunch) so the engine's answer gate and the
    /// next planner-loop build's evaluator threshold both pick it up. A no-op when
    /// the value is unchanged. Updates the published property so the segmented
    /// control reflects the selection immediately.
    public func setDecisionSensitivity(_ value: DecisionSensitivity) {
        guard value != decisionSensitivity else { return }
        DecisionSensitivityStore.set(value)
        decisionSensitivity = value
        trace.emit("hover", "owner set decision_sensitivity=\(value.rawValue)")
    }

    /// v0.2.0 observability (Reddit feedback D): export the watched session's
    /// replay bundle (audit log + flags + plan + verdicts -> JSON + Markdown).
    /// Routes through `exportReportHandler`, which the app wires to
    /// SessionReportExporter. On success the result is stored in `lastExport`
    /// (the panel reveals the file in Finder + shows the path); on any failure it
    /// records an honest failure result rather than claiming a write that did not
    /// happen. A no-op-with-failure when no handler is wired or no session exists.
    public func exportSessionReport() {
        guard !currentSessionId.isEmpty else {
            lastExport = .failure(reason: "No active session to export.")
            trace.emit("hover", "exportSessionReport: no session")
            return
        }
        guard let handler = exportReportHandler else {
            lastExport = .failure(reason: "Export is unavailable.")
            trace.emit("hover", "exportSessionReport: no handler wired")
            return
        }
        guard !isExporting else { return }
        isExporting = true
        let sid = currentSessionId
        trace.emit("hover", "exportSessionReport requested session=\(sid)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let output = await handler(sid)
            self.isExporting = false
            if let output {
                self.lastExport = .success(jsonPath: output.jsonPath, markdownPath: output.markdownPath)
                self.trace.emit("hover", "exportSessionReport wrote \(output.markdownPath.path)")
            } else {
                self.lastExport = .failure(reason: "Could not write the report.")
                self.trace.emit("hover", "exportSessionReport failed session=\(sid)")
            }
        }
    }

    // MARK: - Multi-model deliberation panel (opt-in "Second opinion")

    /// The lifecycle of a per-flag panel "second opinion". Keyed by flag id so
    /// the result renders inline on the exact row the user asked about, and a
    /// request on one flag never bleeds onto another.
    public enum SecondOpinionState {
        case idle
        case running(flagId: String)
        case result(flagId: String, PanelResult)
        case failed(flagId: String, reason: String)

        /// The flag id this state pertains to, if any (nil only when idle).
        public var flagId: String? {
            switch self {
            case .idle:                       return nil
            case let .running(id):            return id
            case let .result(id, _):          return id
            case let .failed(id, _):          return id
            }
        }
    }

    /// The current inline second-opinion state (one at a time across the panel).
    @Published public private(set) var secondOpinion: SecondOpinionState = .idle

    /// True while a panel request is in flight. The UI suppresses the "Second
    /// opinion" affordance on other flags while one is running, so there's never
    /// a button that clicks as a no-op (the one-deliberation-at-a-time guard).
    public var secondOpinionInFlight: Bool {
        if case .running = secondOpinion { return true }
        return false
    }

    /// Whether the owner has enabled the (opt-in, ~4-5x cost) panel. Seeded from
    /// the persisted setting; default OFF. The "Second opinion" affordance shows
    /// only when this is on AND a panel is actually runnable (`panelReady`).
    @Published public private(set) var multiModelPanelEnabled: Bool = MultiModelPanelStore.isEnabled()

    /// DIY cross-provider panel vs OpenRouter Fusion. Persisted; default `.diy`.
    @Published public private(set) var panelMode: PanelMode = MultiModelPanelStore.mode()

    /// Providers that currently have a key stored, for the panel. Seeded by the
    /// app at launch (`setConfiguredProviders`) and updated the instant the user
    /// adds a key in the panel settings, so the affordance appears without a
    /// relaunch.
    @Published public private(set) var configuredProviders: [LLMProvider] = []

    /// True when the configured providers yield a runnable panel: 2+ non-
    /// OpenRouter providers (a cross-provider DIY panel), or an OpenRouter key
    /// (Fusion). Derived from `configuredProviders`, so adding a key flips it on.
    public var panelReady: Bool { Self.computePanelReady(from: configuredProviders) }

    /// The shared "is this set of providers panel-runnable?" rule, so the app,
    /// the VM, and tests agree. Pure, so `nonisolated`.
    public nonisolated static func computePanelReady(from providers: [LLMProvider]) -> Bool {
        providers.filter { $0 != .openrouter }.count >= 2 || providers.contains(.openrouter)
    }

    /// Seed the configured-providers list (the app calls this at launch; tests
    /// use it to stage a state). The add-key flow updates it thereafter.
    public func setConfiguredProviders(_ providers: [LLMProvider]) {
        configuredProviders = providers
    }

    /// True while a newly-entered provider key is being saved.
    @Published public private(set) var isSavingProviderKey = false

    /// Set when the last add-key attempt FAILED (e.g. the Keychain write threw),
    /// nil after a successful save or when a new attempt starts. The panel shows
    /// this under the add-key form — the old flow swallowed the throw and
    /// claimed "saved" while the key was never stored.
    @Published public private(set) var providerKeySaveError: String?

    /// Wired in main.swift: writes a key for a provider (to the same per-provider
    /// Keychain store triage uses) and returns the updated set of configured
    /// providers. THROWS when the Keychain write fails, so the VM can surface
    /// the failure instead of claiming the key was saved. nil in tests.
    public var addProviderKeyHandler: ((_ provider: LLMProvider, _ key: String) async throws -> [LLMProvider])?

    /// Store a provider key entered in the panel settings, then refresh the
    /// configured set so `panelReady` and the "Second opinion" affordance update
    /// at once. A no-op on an empty key, a missing handler, or while already
    /// saving. A thrown Keychain failure lands in `providerKeySaveError` — never
    /// a silent drop, never a false "saved".
    public func addProviderKey(_ provider: LLMProvider, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handler = addProviderKeyHandler, !trimmed.isEmpty, !isSavingProviderKey else { return }
        isSavingProviderKey = true
        providerKeySaveError = nil
        trace.emit("hover", "adding provider key for \(provider.rawValue)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try await handler(provider, trimmed)
                self.configuredProviders = updated
                self.providerKeySaveError = nil
                self.trace.emit("hover", "provider key saved; configured=\(updated.map { $0.rawValue }.joined(separator: ","))")
            } catch {
                self.providerKeySaveError = "Couldn't save the \(provider.displayName) key to the Keychain. The key was NOT stored — try again."
                self.trace.emit("hover", "provider key save FAILED for \(provider.rawValue): \(error)")
            }
            self.isSavingProviderKey = false
        }
    }

    /// Runs the panel on a flagged decision. Wired in main.swift to a
    /// PanelCoordinator built from the configured keys; nil in tests / when no
    /// panel is configured, in which case a request records an honest failure.
    public var secondOpinionHandler: ((_ decision: String) async -> PanelResult?)?

    /// Ask the panel for an independent read on a flagged decision. Mirrors
    /// `exportSessionReport`: set a running state, await the handler, record the
    /// real result or an honest failure. The result renders inline on the flag
    /// row (state is keyed by flag id). A stale completion (the user moved to
    /// another flag) is dropped rather than painting the wrong row.
    public func requestSecondOpinion(for flag: StoredFlag) {
        guard let handler = secondOpinionHandler else {
            secondOpinion = .failed(flagId: flag.id, reason: "The panel isn't configured.")
            trace.emit("hover", "secondOpinion: no handler wired")
            return
        }
        if case .running = secondOpinion { return }   // one deliberation at a time
        let decision = Self.decisionPrompt(for: flag)
        secondOpinion = .running(flagId: flag.id)
        trace.emit("hover", "secondOpinion requested flagId=\(flag.id) mode=\(panelMode.rawValue)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await handler(decision)
            guard case let .running(id) = self.secondOpinion, id == flag.id else { return }
            if let result {
                self.secondOpinion = .result(flagId: flag.id, result)
                self.trace.emit("hover", "secondOpinion done flagId=\(flag.id) degraded=\(result.degraded) members=\(result.perMember.count)")
            } else {
                self.secondOpinion = .failed(flagId: flag.id,
                    reason: "Couldn't reach the panel. Check that at least two provider keys are set.")
                self.trace.emit("hover", "secondOpinion failed flagId=\(flag.id)")
            }
        }
    }

    /// Clear the inline panel result (the row's dismiss affordance).
    public func dismissSecondOpinion() {
        secondOpinion = .idle
    }

    /// Toggle the panel on/off. Persists (survives relaunch) and publishes so the
    /// disclosure control reflects it immediately.
    public func setMultiModelPanelEnabled(_ enabled: Bool) {
        guard enabled != multiModelPanelEnabled else { return }
        MultiModelPanelStore.setEnabled(enabled)
        multiModelPanelEnabled = enabled
        trace.emit("hover", "owner set multi_model_panel_enabled=\(enabled)")
    }

    /// Select the panel mode (DIY vs Fusion). Persists + publishes.
    public func setPanelMode(_ mode: PanelMode) {
        guard mode != panelMode else { return }
        MultiModelPanelStore.setMode(mode)
        panelMode = mode
        trace.emit("hover", "owner set panel_mode=\(mode.rawValue)")
    }

    /// Build the decision text the panel deliberates on from a flagged action.
    /// Plain and self-contained (panel members get no other context), asking for
    /// an independent judgment rather than agreement.
    static func decisionPrompt(for flag: StoredFlag) -> String {
        var s = "Supervisor (a safety layer that watches a coding agent) flagged an action. "
        s += "Give your own independent assessment: is this genuinely risky, is the flag warranted, and what should the user watch for?\n\n"
        s += "Category: \(flag.category.replacingOccurrences(of: "_", with: " "))\n"
        s += "Severity Supervisor assigned: \(flag.severity.rawValue)\n"
        s += "What Supervisor said (plain): \(flag.reasoningPlain)\n"
        if !flag.reasoningTechnical.isEmpty {
            s += "Technical detail: \(flag.reasoningTechnical)\n"
        }
        if let note = flag.asymmetryNote, !note.isEmpty {
            s += "Asymmetry note: \(note)\n"
        }
        return s
    }

    /// v0.2.0 M3: approve a plan from the panel's "Approve plan" button. Routes
    /// through `approvePlanHandler`, which the app wires to
    /// `TriageEngine.approvePlan(planId:)` — the same approval path the
    /// approve-plan marker drives, so the human gate has one implementation.
    /// A no-op (logged) when no handler is wired.
    public func approvePlan(planId: String) {
        guard let handler = approvePlanHandler else {
            trace.emit("hover", "approvePlan: no handler wired (planId=\(planId)) - ignoring")
            return
        }
        // Optimistically disable the Approve button now (RC fix #1): the handler
        // is async and flips plan.status only after a store round-trip, so
        // without this the button stays enabled and the panel shows stale state.
        approvedPlanIds.insert(planId)
        bumpStoreRevision()
        trace.emit("hover", "approvePlan requested from panel planId=\(planId)")
        Task { await handler(planId) }
    }

    /// Force the panel's SwiftUI body to re-invoke and re-read the store after a
    /// store-write action. See `storeRevision` (RC fix #1). Also invalidates the
    /// `activityCount` cache implicitly (it keys on `storeRevision`).
    private func bumpStoreRevision() {
        storeRevision &+= 1
    }

    /// v0.3.x REVIEW dimension: a code-review observation was surfaced for the
    /// watched session (ReviewEngine already recorded it to the audit log). This
    /// only refreshes the panel and updates a calm count — deliberately no
    /// `.flagged` activity and no action flash, since a review is informational,
    /// not a safety intervention. The finding itself renders in the Activity tab
    /// via its `.review` audit entry.
    public func noteReviewFinding(title: String) {
        reviewFindingCount &+= 1
        unseenReviewCount &+= 1
        latestReviewTitle = title
        bumpStoreRevision()
        trace.emit("hover", "review observation surfaced: \(title.prefix(80))")
    }

    /// The owner opened the Review tab — clear the quiet unseen badge. Called from
    /// the Review view's onAppear so the dot behaves like a read-receipt.
    public func markReviewsSeen() {
        guard unseenReviewCount != 0 else { return }
        unseenReviewCount = 0
    }

    /// The watched session's code-review findings (surfaced only), newest first,
    /// with full structure for the Review tab. Nil-safe: [] when no store / no
    /// session / a read fails (the tab shows its calm empty state).
    public func recentReviews(limit: Int = 40) -> [StoredReviewFinding] {
        guard let store = reviewStore, !currentSessionId.isEmpty else { return [] }
        return (try? store.recent(sessionId: currentSessionId, limit: limit, surfacedOnly: true)) ?? []
    }

    /// Count of surfaced review findings for the watched session (the Review tab
    /// badge). Nil-safe: 0 when no store / no session / a read fails.
    public func reviewCount() -> Int {
        guard let store = reviewStore, !currentSessionId.isEmpty else { return 0 }
        return (try? store.count(sessionId: currentSessionId, surfacedOnly: true)) ?? 0
    }

    /// Flags in the CURRENT work window — the honest "this run" number the
    /// expanded panel footer shows. Unlike `flagCount` (a process-lifetime
    /// counter seeded at launch and bumped on every session's flag, so it
    /// drifts from the current-work-window reality), this reads the work-window
    /// scope live from FlagStore. Nil-safe: 0 when no store / a read fails
    /// (mirrors recentFlags / reviewCount).
    public func flagsThisRunCount() -> Int {
        (try? flagStore?.countCurrentWorkWindow(now: Date())) ?? 0
    }

    /// Whether the code-review dimension is opted in (re-reads the marker live, so
    /// the Review tab's empty state adapts the moment the owner flips it). Read at
    /// render; not @Published — the panel re-derives it each pass.
    public func isReviewEnabled() -> Bool {
        RuntimeToggles.reviewEnabled
    }

    /// Toggle expanded panel state.
    public func toggleExpanded() {
        isExpanded.toggle()
        trace.emit("hover", "expanded panel \(isExpanded ? "opened" : "closed")")
    }

    /// Push the live count of watched sessions (from SessionDiscovery). The
    /// controller calls this on each visibility pass. When the count crosses
    /// into / out of the multi-session range, refresh the idle label so the one
    /// band reads "Watching N sessions. All clear" rather than a single
    /// project. A no-op when unchanged, and the active-flash / flagged /
    /// triaging labels are left untouched (the count only colors the calm idle
    /// "all clear" state).
    public func setWatchedSessionCount(_ count: Int) {
        let clamped = max(0, count)
        guard clamped != watchedSessionCount else { return }
        watchedSessionCount = clamped
        // Only re-derive the resting label when we're idle and not mid-flash;
        // a flag headline or a triage "checking" must not be stomped.
        if activity == .idle, !actionFlash {
            plainLabel = idleLabel()
        }
    }

    /// The calm "all clear" headline for the one hover band. With multiple live
    /// sessions it aggregates the count ("Watching 3 sessions. All clear") so a
    /// busy Supervisor reads as one informative band instead of the label
    /// flipping between project names. With 0 or 1 session it keeps the exact
    /// prior wording (project name when known, else the bare "Watching").
    private func idleLabel() -> String {
        if watchedSessionCount > 1 {
            return "Watching \(watchedSessionCount) sessions. All clear"
        }
        return projectName.isEmpty
            ? "Watching. All clear"
            : "Watching \(projectName). All clear"
    }

    /// Owner control: pause / resume Supervisor globally. The engine reads the
    /// marker live, so the effect is immediate — no rebuild, no restart.
    public func toggleSupervisorPaused() {
        let next = !supervisorPaused
        RuntimeToggles.setSupervisorPaused(next)
        supervisorPaused = next
        trace.emit("hover", "owner toggled supervisor_paused=\(next)")
    }

    /// Owner control: turn the 4-hour loop cap off / on for this machine.
    public func toggleLoopCapDisabled() {
        let next = !loopCapDisabled
        RuntimeToggles.setLoopCapDisabled(next)
        loopCapDisabled = next
        trace.emit("hover", "owner toggled loop_cap_disabled=\(next)")
    }

    /// Record user response (dismiss / false positive) for a flag.
    public func respondToFlag(flagId: String, response: FlagUserResponse) {
        guard let store = flagStore else {
            trace.emit("hover", "respondToFlag: no flagStore")
            return
        }
        do {
            try store.markUserResponse(flagId: flagId, response: response)
            trace.emit("hover", "respondToFlag id=\(flagId) response=\(response.rawValue)")
            // Force the panel to re-read the store so the flag row reflects the
            // response immediately ("Dismissed"/"Overridden") rather than
            // showing stale unresponded state (RC fix #1).
            bumpStoreRevision()
        } catch {
            trace.emit("hover", "respondToFlag ERROR: \(error)")
        }
    }

    /// Reject — the human override. Effect depends on current state:
    ///   - If Supervisor PAUSED Claude Code: reject = let it continue (SIGCONT).
    ///   - Otherwise: reject = record the override. Future dispatches/actions
    ///     for this flag are suppressed.
    /// Per PRINCIPLES: reject never overrides kill-level safety (a kill
    /// already happened, the session ended — reject just records dissent).
    public func rejectFlag(flagId: String, action: FlagAction) {
        // Record the rejection first.
        respondToFlag(flagId: flagId, response: .rejected)

        // If the live state is paused and this is the flag that caused it,
        // rejecting means "let Claude Code continue" — send SIGCONT.
        if action == .pause && isPaused {
            trace.emit("hover", "reject: releasing pause (SIGCONT) for flagId=\(flagId)")
            resumePausedSession()
        } else if action == .kill {
            trace.emit("hover", "reject: kill already fired, recording dissent for flagId=\(flagId)")
        } else {
            trace.emit("hover", "reject: recorded override for flagId=\(flagId) action=\(action.rawValue)")
        }
    }

    // MARK: - Action recording

    /// Record a substantial action Supervisor just took. Triggers the
    /// action flash and adds to the action log. Called from main.swift
    /// after the InterventionRouter dispatches.
    public func recordAction(action: FlagAction, description: String) {
        // Only record substantial actions, not plain notify.
        guard action != .notify else { return }

        let record = ActionRecord(action: action, plainDescription: description)
        recentActions.insert(record, at: 0)
        if recentActions.count > 20 {
            recentActions.removeLast()
        }
        trace.emit("hover", "action recorded: \(action.rawValue) — \(description)")

        // Flash AND surface the plain-language label, so the user sees — in
        // the moment — WHAT Supervisor did ("Paused Claude Code", "Sent
        // Claude its next task"), not just a border glow. The label settles
        // back to the activity label after the hold. HoverWindowController
        // observes actionFlash and forces the hover visible for the
        // duration, so this is seen even when no terminal is frontmost.
        beginActionFlash(label: description, holdSeconds: 2.5)
    }

    /// Announce that Supervisor rebuilt and relaunched itself. Shows a
    /// short hover message and flashes, so the user can see the app
    /// updated on its own. Called at launch when a self-rebuild marker
    /// is present (written by the deploy step). Clears back to the idle
    /// watching label after a few seconds.
    public func announceSelfRebuild(version: String? = nil) {
        let label = version.map { "Supervisor updated itself to \($0)" }
            ?? "Supervisor updated itself"

        let record = ActionRecord(action: .selfExtend, plainDescription: label)
        recentActions.insert(record, at: 0)
        if recentActions.count > 20 {
            recentActions.removeLast()
        }
        trace.emit("hover", "self-rebuild announced: \(label)")

        // Longer hold than a normal action: the hover window is recreated on
        // relaunch and the frontmost app right after a self-deploy is almost
        // never a terminal, so the normal visibility gate would hide this.
        // The controller force-shows while actionFlash is true; a 5s hold
        // gives the user (and on-screen verification) time to actually see
        // "Supervisor updated itself" before it settles back.
        beginActionFlash(label: label, holdSeconds: 5.0)
    }

    /// Drive the action flash: surface `label`, glow/scale the hover (via
    /// `actionFlash`), then settle the label back to the live activity after
    /// `holdSeconds`. Centralized so recordAction and announceSelfRebuild
    /// behave identically. HoverWindowController observes `actionFlash` and
    /// forces the hover visible for the hold, so the flash is seen even when
    /// no terminal is frontmost.
    private func beginActionFlash(label: String, holdSeconds: Double) {
        plainLabel = label
        detailLabel = ""   // clear any stale command detail for a clean flash
        actionFlash = true

        flashOffTask?.cancel()
        acknowledgeDebouncerTask?.cancel()
        let holdNanos = UInt64(max(0, holdSeconds) * 1_000_000_000)
        flashOffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: holdNanos)
            guard !Task.isCancelled, let self else { return }
            self.actionFlash = false
            self.plainLabel = self.labelForCurrentActivity()
        }
    }

    /// The plain label that matches the current `activity` — used to settle
    /// the hover after a transient action flash without reverting an active
    /// pause/flag to "all clear".
    private func labelForCurrentActivity() -> String {
        switch activity {
        case .idle:
            return idleLabel()
        case .triaging:
            return "Checking something..."
        case let .flagged(_, action, reasoningPlain, _, _):
            return Self.plainLabelForFlag(action: action, reasoningPlain: reasoningPlain)
        }
    }

    /// Resume a paused session by sending SIGCONT to the process.
    /// Called from the expanded panel's Resume button.
    public func resumePausedSession() {
        // Drive the PAUSED session's cwd, not whatever session became most
        // recently active (RC fix #3). Falls back to sessionCwd only when no
        // paused cwd was captured (the single-session path).
        let cwd = pausedSessionCwd.isEmpty ? sessionCwd : pausedSessionCwd
        guard isPaused, !cwd.isEmpty, let handler = resumeHandler else {
            trace.emit("hover", "resume: precondition failed (isPaused=\(isPaused) cwd=\(cwd.isEmpty ? "empty" : "set") handler=\(resumeHandler == nil ? "nil" : "set"))")
            return
        }
        // TODO(resume-resolver): resumeHandler resolves the target session by
        // cwd only. With concurrent sessions sharing a cwd this is ambiguous; the
        // resolver (main.swift + InterventionRouter, not owned here) should accept
        // the paused sessionId (`pausedSessionId`) to SIGCONT the exact process.
        // The hover now reports the correct paused session + its cwd; wiring the
        // id through the handler signature is the remaining cross-file change.
        isResuming = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await handler(cwd)
            self.isResuming = false
            if ok {
                self.trace.emit("hover", "resume: SIGCONT sent successfully cwd=\(cwd)")
                self.acknowledgeFlag()
            } else {
                self.trace.emit("hover", "resume: SIGCONT failed cwd=\(cwd)")
            }
        }
    }

    // MARK: - Triage state hooks

    /// Called by TriageEngine when it starts a Haiku call.
    public func triageStarted() {
        // Don't stomp an active action flash. On a busy session the triage
        // engine fires constantly; without this guard it overwrites the
        // "Paused Claude Code" / "Supervisor updated itself" label (and the
        // dot) milliseconds after the flash sets it, so the user never sees
        // the action. The flash owns the hover for its brief duration.
        guard !actionFlash else {
            trace.emit("hover", "triage started — label held (action flash active)")
            return
        }
        activity = .triaging
        plainLabel = "Checking something..."
        trace.emit("hover", "activity -> triaging")
    }

    /// Called by TriageEngine when a Haiku batch finishes without flags.
    public func triageFinishedNoFlag() {
        guard !actionFlash else {
            trace.emit("hover", "triage idle — label held (action flash active)")
            return
        }
        activity = .idle
        plainLabel = idleLabel()
        trace.emit("hover", "activity -> idle (no flag)")
    }

    /// Called by the FlagRouter when a flag is raised. The plain label
    /// says what happened in language a non-engineer understands.
    /// `reasoningPlain` is the triage's plain-voice summary — if
    /// available, the label uses it; otherwise falls back to a
    /// generic action-based sentence.
    ///
    /// `flaggedSessionId` / `flaggedSessionCwd` identify the session the engine
    /// actually acted on. They MUST be supplied for a pause/kill on a machine
    /// that may run more than one session: the pause/resume pin uses them so a
    /// later Resume drives the paused process rather than whichever session
    /// happened to start last (Finding 5). When absent (single-session path or
    /// an older caller) the pin falls back to `currentSessionId` / `sessionCwd`,
    /// preserving the pre-fix behavior exactly.
    public func flagRaised(
        severity: FlagSeverity,
        action: FlagAction,
        reasoningPlain: String? = nil,
        flaggedSessionId: String? = nil,
        flaggedSessionCwd: String? = nil
    ) {
        flagCount += 1
        activity = .flagged(severity: severity, action: action)
        plainLabel = Self.plainLabelForFlag(action: action, reasoningPlain: reasoningPlain)
        // Track a live pause / kill explicitly so it survives background bus
        // events and a concurrent session's start (RC fix #3/#5). Pinned to the
        // session the ENGINE flagged, independent of the transient `activity`
        // AND of `currentSessionId` (which tracks the most-recently-STARTED
        // session, not the flagged one — Finding 5). Fall back to
        // currentSessionId/sessionCwd only when the engine supplied no identity,
        // so the single-session path is byte-for-byte unchanged.
        if action == .pause {
            isPaused = true
            if let sid = flaggedSessionId, !sid.isEmpty {
                pausedSessionId = sid
            } else {
                pausedSessionId = currentSessionId
            }
            if let scwd = flaggedSessionCwd, !scwd.isEmpty {
                pausedSessionCwd = scwd
            } else {
                pausedSessionCwd = sessionCwd
            }
        } else if action == .kill {
            isKilled = true
        }
        trace.emit("hover", "flag raised severity=\(severity.rawValue) action=\(action.rawValue) total=\(flagCount) pinnedSession=\(pausedSessionId.isEmpty ? "-" : pausedSessionId)")

        // Auto-acknowledge after the debounce duration. Each new flag
        // resets the timer so rapid flags don't flicker.
        acknowledgeDebouncerTask?.cancel()
        let duration = acknowledgeDebounceDuration
        acknowledgeDebouncerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.acknowledgeFlag()
        }
    }

    /// Resets the activity dot to idle. UI calls after a flag has been
    /// acknowledged by the user, or after a debounce timer expires.
    public func acknowledgeFlag() {
        activity = .idle
        plainLabel = idleLabel()
        detailLabel = ""
        // The flag has been resolved (user-acknowledged or the debounce
        // elapsed): clear any live pause/kill tracking (RC fix #3/#5).
        isPaused = false
        isKilled = false
        pausedSessionId = ""
        pausedSessionCwd = ""
        trace.emit("hover", "flag acknowledged; activity -> idle")
    }

    /// Plain-language label for a flag, based on the action taken.
    public static func plainLabelForFlag(action: FlagAction, reasoningPlain: String?) -> String {
        // If we have a plain reasoning, use a short version of it.
        if let plain = reasoningPlain, !plain.isEmpty {
            // Take the first sentence using Foundation's sentence boundary
            // detection. A naive split on "." breaks on any embedded period:
            // version numbers ("v0.8.3"), abbreviations ("e.g."), file paths
            // ("config.yaml"). ICU's sentence tokenizer handles all of those.
            let firstSentence = Self.firstSentence(of: plain)
            let capped = firstSentence.count > 60 ? String(firstSentence.prefix(57)) + "..." : firstSentence
            return capped
        }
        // Generic fallback per action type.
        switch action {
        case .notify:     return "Noticed something. Check the notification."
        // Flag-time label, set BEFORE the inject runs — present tense, never a
        // success claim. The honest result lands later via
        // recordInterventionOutcome once the executor actually finishes.
        case .inject:     return "Answering a question for Claude Code"
        case .continue:   return "Sending Claude Code its next task"
        case .selfExtend: return "Helping the dispatch loop recover"
        case .pause:      return "Paused Claude Code. Needs your attention."
        case .kill:       return "Stopped Claude Code. Something looked dangerous."
        }
    }

    /// v0.9.0 (integrity): record the action-log entry + live label from the
    /// ACTUAL intervention outcome, never from intent. The app wires this to the
    /// Notifier's result hook, so it fires with the same (decision, outcome) the
    /// banner uses, AFTER the router's executor finishes. A degraded inject or
    /// continue reports honestly that it couldn't place the text and points to
    /// the banner; it NEVER claims it answered. This replaces the old eager
    /// record that fired at decision time with the intent label.
    public func recordInterventionOutcome(_ decision: TriageDecision, _ outcome: InterventionOutcome) {
        guard let result = Self.actionForOutcome(outcome) else { return }
        recordAction(action: result.action, description: result.label)
        plainLabel = result.label
        trace.emit("hover", "action recorded from REAL outcome: \(result.label)")
    }

    /// Map a real intervention outcome to an honest (action, label), or nil when
    /// there's nothing Supervisor actually did to record (a plain notify, or a
    /// low-confidence "waiting for direction" — neither is an action taken, and
    /// a degraded pause/kill arrives as `.notifyOnly`, so it never claims it
    /// paused/stopped something it didn't).
    nonisolated static func actionForOutcome(_ outcome: InterventionOutcome) -> (action: FlagAction, label: String)? {
        switch outcome {
        case .injectSucceeded:
            return (.inject, "Answered a question for Claude Code")
        case .injectDegraded(_, _, let copiedToClipboard):
            // Honest about WHERE the answer actually is: the clipboard claim is
            // only made when the router's pasteboard write really succeeded.
            return (.inject, copiedToClipboard
                ? "Couldn't place the answer in the conversation. It's on your clipboard to paste."
                : "Couldn't place the answer in the conversation. It's in the banner to paste.")
        case .screenRecordingDenied:
            return (.inject, "Blocked: needs Screen Recording to drive the Claude desktop app. Grant it in System Settings, then quit and relaunch Supervisor for the grant to take effect.")
        case .continueFired:
            return (.continue, "Sent Claude Code its next task")
        case .continueProposedMedium:
            return (.continue, "Suggested a next task. It's in the banner for you.")
        case .queued:
            // Piece 3: deferred because the human is typing. Honest — it has
            // NOT sent/answered; it's holding the dispatch until the worker is
            // ready, when the loop re-fires and delivers it.
            return (.continue, "Queued — will send when Claude Code is ready")
        case .pauseSucceeded:
            return (.pause, "Paused Claude Code. Needs your attention.")
        case .killSucceeded:
            return (.kill, "Stopped Claude Code. Something looked dangerous.")
        case .notifyOnly, .continueLowConfidence:
            return nil
        }
    }

    /// First sentence of `text`, using Foundation's sentence boundary
    /// detection (ICU). Robust against embedded periods (versions,
    /// abbreviations, file paths) that a naive split on "." would treat
    /// as sentence ends. Returns the whole string if no sentence boundary
    /// is found.
    static func firstSentence(of text: String) -> String {
        var result: String?
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .bySentences
        ) { substring, _, _, stop in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                result = s
                stop.pointee = true
            }
        }
        return result ?? text
    }

    // MARK: - Event subscription

    /// Whether the hover is in a calm state whose label a background bus event
    /// may repaint. A flagged state (pause / kill / degraded) OWNS the headline
    /// and must never be overwritten by a routine command / idle repaint (RC
    /// fix #2). Mirrors the activity guard `triageStarted()` already applies.
    private var isCalmActivity: Bool {
        switch activity {
        case .idle, .triaging: return true
        case .flagged:         return false
        }
    }

    private func handle(event: SupervisorEvent) {
        switch event {
        case .sessionStart(let info):
            let basename = (info.cwd as NSString).lastPathComponent
            projectName = basename.isEmpty ? "" : basename
            sessionCwd = info.cwd
            currentSessionId = info.sessionId
            // Derive the agent from the session namespace and track whether more
            // than one agent kind is in play (gates the agent chip in the UI).
            currentAgent = AgentKind(projectNamespace: info.projectHash)
            if seenAgents.insert(currentAgent).inserted, seenAgents.count > 1, !isMultiAgent {
                isMultiAgent = true
            }
            // Reset per-session metrics on new session.
            turnCount = 0
            toolCallCount = 0
            // Don't stomp an active action flash (see triageStarted), NOR a live
            // flag/pause. A new session starting must not mask a still-paused (or
            // flagged) session's headline (RC fix #3) — the paused session is
            // pinned in pausedSessionId, so metrics can follow the new session
            // while the pause label/state stays put.
            if !actionFlash, isCalmActivity {
                plainLabel = idleLabel()
            }
        case .bashToolCall(let info):
            // Counters increment unconditionally.
            toolCallCount += 1
            // Only paint the command label over a calm idle/triaging state. A
            // flagged state (pause/kill/degraded) or an active action flash owns
            // the hover headline; a background bus event must never repaint over
            // it (RC fix #2).
            guard !actionFlash, isCalmActivity else { break }
            // Plain headline: "Running a command"
            // Detail (secondary, de-emphasized): the actual command
            let head = info.command
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)
                ?? info.command
            plainLabel = "Running a command"
            detailLabel = String(head.prefix(80))
        case .bashToolResult(let info):
            if info.isError, !actionFlash, isCalmActivity {
                detailLabel += " (errored)"
            }
        case .userPrompt:
            turnCount += 1
        case .assistantText, .systemSignal, .fileEdit:
            // Passive for the hover headline: a file edit is handled by the
            // destructive-safety trigger elsewhere and must not repaint the
            // calm/idle label here. Grouped with the other non-repainting events.
            break
        }
    }
}
