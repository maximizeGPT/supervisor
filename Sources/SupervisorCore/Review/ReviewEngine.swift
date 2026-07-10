// ReviewEngine.swift — v0.3.x REVIEW dimension.
//
// A SECOND observer alongside the safety TriageEngine. Where TriageEngine
// watches for danger (destructive/unauthorized/injection), ReviewEngine watches
// for code QUALITY: as a supervised worker writes code (Edit/Write/MultiEdit),
// it reviews those changes on the fly and surfaces SUBSTANTIVE issues — a wrong
// assumption baked in, an overlooked edge case, a line that misses something,
// logic that contradicts an earlier decision this session.
//
// It is deliberately separate from TriageEngine and NEVER touches the safety
// path: it consumes only the additive `.fileEdit` event (which TriageEngine
// ignores), and it never pauses/kills/injects — reviews are informational. It
// is OPT-IN and INERT by default (the `review-enabled.marker`); with the marker
// off it subscribes to nothing consequential and spends nothing.
//
// Trigger — debounced per-turn. A worker's edits arrive in bursts (a turn);
// the engine reviews a burst once the edits go quiet (`debounceInterval`), with
// a `minReviewInterval` floor so rapid turns can't fire a review each, and a
// `maxBufferAge` ceiling so a long continuous edit streak still gets reviewed.
// This batches a coherent change (with the worker's reasoning attached) into one
// review, which is both cheaper and less noisy than reviewing each edit.
//
// Noise control (an ignorable nitpick is worse than silence, matching
// Supervisor's conservatism):
//   1. The prompt sets a high bar and treats an empty result as correct.
//   2. The owner's Decision Sensitivity dial is the confidence gate: Cautious
//      surfaces only high-confidence findings; Balanced/Decisive surface medium+.
//   3. Per-finding DEDUP via ReviewFindingStore's UNIQUE fingerprint — the same
//      issue on the same file surfaces once, not every turn.
//   4. A per-review surfacing cap so one review can't flood.
//   5. The shared daily cost cap (inherited through LLMClient) bounds spend.

import Combine
import Foundation

/// A finding that cleared the gate and is being shown to the owner. Handed to
/// the hover surface so the panel can refresh (and, later, present it).
public struct SurfacedReview: Sendable, Equatable {
    public let sessionId: String
    public let filePath: String
    public let severity: FlagSeverity
    public let title: String
}

@MainActor
public final class ReviewEngine {

    // MARK: - Tunables

    /// Edit-quiet window before a burst is reviewed. A turn's edits arrive close
    /// together; once they stop for this long, the turn is reviewed.
    private let debounceInterval: TimeInterval
    /// Floor between review CALLS per session — coalesces rapid successive turns
    /// into one review so a fast worker can't fire a review each turn.
    private let minReviewInterval: TimeInterval
    /// Ceiling on how long edits may buffer before a forced review, so a long
    /// continuous edit streak (debounce never fires) still gets reviewed.
    private let maxBufferAge: TimeInterval
    /// Most findings one review may surface — one high-value note beats five.
    private let maxSurfacedPerReview: Int

    // MARK: - Dependencies

    private let client: LLMClient
    private let bus: EventBus
    private let model: String
    private let reviewStore: ReviewFindingStore?
    private let auditStore: AuditStore?
    private let redactor: any Redactor
    private let trace: TraceLog
    /// nil = read the `review-enabled.marker` live (production). Tests pass an
    /// explicit value so they never depend on a real marker.
    private let enabledOverride: Bool?
    /// The confidence bar to SURFACE a finding — reuses the owner's Decision
    /// Sensitivity dial. Injectable for tests.
    private let sensitivity: @Sendable () -> DecisionSensitivity
    /// Called on the main actor for each surfaced finding, so the hover panel can
    /// refresh. nil in headless/test contexts.
    private let onFinding: (@MainActor (SurfacedReview) -> Void)?

    private var busSubscription: AnyCancellable?

    // MARK: - Per-session state (main-actor isolated; no locks)

    /// Edits accumulated since the last review, per session.
    private var buffer: [String: [FileEditInfo]] = [:]
    /// When the current buffer started filling (for the maxBufferAge ceiling).
    private var bufferStartedAt: [String: Date] = [:]
    /// Last time a review actually ran, per session (for the minReviewInterval floor).
    private var lastReviewAt: [String: Date] = [:]
    /// Pending debounce timer, per session.
    private var timers: [String: Task<Void, Never>] = [:]
    /// Cached session facts from `.sessionStart`.
    private var sessionCwd: [String: String] = [:]
    private var sessionBranch: [String: String] = [:]
    /// Latest owner prompt text, the "what is the worker trying to do" objective.
    private var objective: [String: String] = [:]
    /// Recent assistant reasoning by turn, so the review can attach the worker's
    /// stated intent to the edits it made in that turn. Capped per session.
    private var recentReasoning: [String: [(uuid: String, text: String)]] = [:]
    /// Rolling compact context lines this session, for catching contradictions
    /// with earlier decisions. Capped per session.
    private var priorContext: [String: [String]] = [:]

    public init(
        client: LLMClient,
        bus: EventBus,
        model: String,
        reviewStore: ReviewFindingStore?,
        auditStore: AuditStore?,
        redactor: any Redactor = DefaultRedactor(),
        debounceInterval: TimeInterval = 6,
        minReviewInterval: TimeInterval = 20,
        maxBufferAge: TimeInterval = 45,
        maxSurfacedPerReview: Int = 3,
        enabledOverride: Bool? = nil,
        sensitivity: @escaping @Sendable () -> DecisionSensitivity = { DecisionSensitivityStore.current() },
        onFinding: (@MainActor (SurfacedReview) -> Void)? = nil,
        trace: TraceLog = .shared
    ) {
        self.client = client
        self.bus = bus
        self.model = model
        self.reviewStore = reviewStore
        self.auditStore = auditStore
        self.redactor = redactor
        self.debounceInterval = debounceInterval
        self.minReviewInterval = minReviewInterval
        self.maxBufferAge = maxBufferAge
        self.maxSurfacedPerReview = maxSurfacedPerReview
        self.enabledOverride = enabledOverride
        self.sensitivity = sensitivity
        self.onFinding = onFinding
        self.trace = trace
    }

    // MARK: - Lifecycle

    public func start() {
        busSubscription = bus.subscribe { [weak self] event in
            // Unwrap the weak self to a strong LET before the nested Task, then
            // capture that immutable local — NOT the weak var directly. Capturing
            // the weak `self` var inside a concurrently-executing Task is the
            // Swift-5.10 "reference to captured var in concurrently-executing
            // code" error CI flags (6.2.x compiles it clean locally). Mirrors the
            // shipped TriageEngine.start() subscribe exactly.
            guard let self else { return }
            Task { @MainActor in self.consume(event: event) }
        }
        trace.emit("review", "engine started model=\(model) enabled=\(isEnabled)")
    }

    public func stop() {
        busSubscription?.cancel()
        busSubscription = nil
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
        trace.emit("review", "engine stopped")
    }

    // MARK: - Gates

    /// The review feature is OFF unless the owner opts in via the marker. When
    /// paused globally, Supervisor spends nothing — reviews included.
    ///
    /// `enabledOverride`, when set, FULLY determines active state — it is the test
    /// seam, so a hermetic test is never at the mercy of a real
    /// `review-enabled.marker` / `supervisor-paused.marker` on the dev machine. In
    /// production (`enabledOverride == nil`) the opt-in marker AND the global pause
    /// are both honored.
    private var isEnabled: Bool { enabledOverride ?? RuntimeToggles.reviewEnabled }
    private var isActive: Bool {
        if let forced = enabledOverride { return forced }
        return RuntimeToggles.reviewEnabled && !RuntimeToggles.supervisorPaused
    }

    // MARK: - Event consumption

    func consume(event: SupervisorEvent) {
        // Always keep cheap context caches warm (no spend) so a review, when it
        // does fire, has cwd/branch/objective/reasoning. These are tiny and don't
        // depend on the feature being enabled.
        switch event {
        case .sessionStart(let i):
            sessionCwd[i.sessionId] = i.cwd
            if let b = i.gitBranch { sessionBranch[i.sessionId] = b }
        case .userPrompt(let i):
            // The owner's latest instruction is the objective. (Origin is always
            // .owner on the raw bus; injected turns are background context only.)
            if i.origin == .owner, !i.text.isEmpty {
                objective[i.sessionId] = i.text
            }
        case .assistantText(let i):
            cacheReasoning(sessionId: i.sessionId, uuid: i.turnUUID, text: i.text)
        case .fileEdit(let i):
            handleEdit(i)
        default:
            break
        }
    }

    private func cacheReasoning(sessionId: String, uuid: String, text: String) {
        var list = recentReasoning[sessionId] ?? []
        list.append((uuid: uuid, text: text))
        if list.count > 24 { list.removeFirst(list.count - 24) }
        recentReasoning[sessionId] = list
    }

    private func handleEdit(_ edit: FileEditInfo) {
        guard isActive else { return }
        let sid = edit.sessionId
        var buf = buffer[sid] ?? []
        if buf.isEmpty { bufferStartedAt[sid] = edit.ts }
        buf.append(edit)
        buffer[sid] = buf
        armTimer(sid)
    }

    /// (Re)arm the per-session debounce timer. Fire delay respects both the
    /// edit-quiet window and the min-interval floor, unless the buffer has aged
    /// past the ceiling (then fire promptly).
    private func armTimer(_ sid: String) {
        timers[sid]?.cancel()

        let now = Date()
        let sinceLast = lastReviewAt[sid].map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let bufAge = bufferStartedAt[sid].map { now.timeIntervalSince($0) } ?? 0

        let delay: TimeInterval
        if bufAge >= maxBufferAge {
            delay = 0
        } else {
            delay = max(debounceInterval, minReviewInterval - sinceLast)
        }

        let ns = UInt64(max(0, delay) * 1_000_000_000)
        timers[sid] = Task { @MainActor [weak self] in
            if ns > 0 { try? await Task.sleep(nanoseconds: ns) }
            guard let self, !Task.isCancelled else { return }
            self.timers[sid] = nil
            await self.runReview(sessionId: sid)
        }
    }

    // MARK: - Review

    func runReview(sessionId sid: String) async {
        guard isActive else { buffer[sid] = nil; return }
        let edits = buffer[sid] ?? []
        buffer[sid] = nil
        bufferStartedAt[sid] = nil
        guard !edits.isEmpty else { return }

        lastReviewAt[sid] = Date()

        // Assemble the reasoning attached to this batch's turns.
        let turnUUIDs = Set(edits.map { $0.turnUUID })
        let reasoning = (recentReasoning[sid] ?? [])
            .filter { turnUUIDs.contains($0.uuid) }
            .map { $0.text }
            .joined(separator: "\n")

        let objectiveText = objective[sid]
        let input = ReviewInput(
            cwd: sessionCwd[sid],
            gitBranch: sessionBranch[sid],
            objective: objectiveText,
            objectiveFromOwner: objectiveText != nil,
            assistantReasoning: reasoning.isEmpty ? nil : reasoning,
            edits: edits,
            priorContext: priorContext[sid] ?? []
        )

        let fileList = Set(edits.map { $0.filePath }).joined(separator: ", ")
        trace.emit("review", "reviewing session=\(sid) edits=\(edits.count) files=[\(fileList)]")

        let response: AnthropicMessageResponse
        do {
            response = try await client.createMessage(ReviewPrompt.buildRequest(model: model, input: input))
        } catch let e as DailyCapExceededError {
            trace.emit("review", "skipped session=\(sid): daily cap reached (\(e.localizedDescription))")
            return
        } catch {
            trace.emit("review", "review call FAILED session=\(sid): \(error)")
            return
        }

        let findings = parseFindings(from: response)
        recordPriorContext(sid: sid, edits: edits, reasoning: reasoning, findings: findings)

        guard !findings.isEmpty else {
            trace.emit("review", "all clear session=\(sid) (no substantive findings) input=\(response.usage.input_tokens) output=\(response.usage.output_tokens)")
            return
        }

        surface(findings: findings, sessionId: sid)
    }

    /// Apply the confidence gate, dedup, and the per-review cap, then persist +
    /// surface the survivors.
    private func surface(findings: [ReviewFinding], sessionId sid: String) {
        let bar = sensitivity().minAnswerConfidenceToInject
        // Rank by severity then confidence so the cap keeps the highest-value few.
        let ranked = findings.sorted { priority($0) > priority($1) }

        var surfacedCount = 0
        var dropped = 0
        var dupes = 0

        for f in ranked {
            let passesBar = f.confidence.meets(bar)
            let underCap = surfacedCount < maxSurfacedPerReview
            let surfaced = passesBar && underCap

            // Redact finding text before it is persisted or shown — defense in
            // depth, since the model could echo a secret out of the reviewed diff.
            // (The request itself was already redacted inside LLMClient.)
            let title = redactor.redact(f.title)
            let detail = redactor.redact(f.detail)
            let lineHint = f.lineHint.map { redactor.redact($0) }

            let fp = ReviewFindingStore.fingerprint(sessionId: sid, filePath: f.filePath, title: title)
            let row = StoredReviewFinding(
                sessionId: sid,
                fingerprint: fp,
                filePath: f.filePath,
                toolName: "",   // finding-level; the specific tool isn't needed on the row
                turnUUID: "",
                category: f.category.rawValue,
                severity: f.severity,
                confidence: f.confidence.rawValue,
                title: title,
                detail: detail,
                lineHint: lineHint,
                surfaced: surfaced
            )

            // Dedup: skip anything already seen for this session+file+title.
            let isNew: Bool
            if let store = reviewStore {
                isNew = (try? store.insertIfNew(row)) ?? true
            } else {
                isNew = true
            }
            guard isNew else { dupes += 1; continue }

            if !surfaced {
                if passesBar { dropped += 1 }   // passed the bar but over the cap
                continue
            }

            surfacedCount += 1
            recordAudit(sessionId: sid, filePath: f.filePath, severity: f.severity, confidence: f.confidence, category: f.category, title: title, detail: detail, lineHint: lineHint)
            onFinding?(SurfacedReview(sessionId: sid, filePath: f.filePath, severity: f.severity, title: title))
        }

        trace.emit("review", "surfaced=\(surfacedCount) dupes=\(dupes) over_cap=\(dropped) below_bar=\(findings.count - surfacedCount - dupes - dropped) session=\(sid) bar=\(bar.rawValue)")
    }

    private func recordAudit(sessionId sid: String, filePath: String, severity: FlagSeverity, confidence: EngineeringAnswer.Confidence, category: ReviewFinding.Category, title: String, detail: String, lineHint: String?) {
        guard let auditStore else { return }
        let assessment = "\(severity.rawValue) severity · \(confidence.rawValue) confidence · \(category.rawValue.replacingOccurrences(of: "_", with: " "))"
        let entry = StoredAuditEntry(
            sessionId: sid,
            kind: .review,
            summary: title,
            targetPath: filePath,
            riskReason: detail,
            classification: assessment,
            detail: lineHint
        )
        do {
            try auditStore.record(entry)
        } catch {
            trace.emit("review", "audit record FAILED session=\(sid): \(error)")
        }
    }

    /// Append a compact one-liner about this reviewed turn so later reviews can
    /// catch a contradiction with it. Recorded whether or not it found anything.
    private func recordPriorContext(sid: String, edits: [FileEditInfo], reasoning: String, findings: [ReviewFinding]) {
        let files = Set(edits.map { ($0.filePath as NSString).lastPathComponent }).sorted().joined(separator: ", ")
        let head = reasoning.split(separator: "\n").first.map(String.init)?.prefix(160) ?? ""
        var line = "edited \(files)"
        if !head.isEmpty { line += " — \(head)" }
        if !findings.isEmpty {
            line += " [review noted: \(findings.prefix(2).map { $0.title.prefix(60) }.joined(separator: "; "))]"
        }
        var ctx = priorContext[sid] ?? []
        ctx.append(line)
        if ctx.count > 40 { ctx.removeFirst(ctx.count - 40) }
        priorContext[sid] = ctx
    }

    // MARK: - Parsing

    func parseFindings(from response: AnthropicMessageResponse) -> [ReviewFinding] {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == ReviewPrompt.recordReviewToolName,
                  case let .object(input)? = block.input,
                  case let .array(arr)? = input["findings"]
            else { continue }
            var out: [ReviewFinding] = []
            for raw in arr {
                guard case let .object(f) = raw else { continue }
                if let finding = parseFinding(f) { out.append(finding) }
            }
            return out
        }
        return []
    }

    private func parseFinding(_ f: [String: AnthropicJSON]) -> ReviewFinding? {
        guard case let .string(catRaw)? = f["category"],
              let category = ReviewFinding.Category(rawValue: catRaw),
              case let .string(sevRaw)? = f["severity"],
              let severity = FlagSeverity(rawValue: sevRaw),
              case let .string(confRaw)? = f["confidence"],
              let confidence = EngineeringAnswer.Confidence(rawValue: confRaw),
              case let .string(title)? = f["title"], !title.isEmpty,
              case let .string(detail)? = f["detail"]
        else {
            trace.emit("review", "schema.malformed finding dropped raw=\(f.keys.sorted().joined(separator: ","))")
            return nil
        }
        // file_path is required by the schema; fall back to "(unspecified)" so a
        // valid-but-file-less finding still records rather than vanishing.
        let filePath: String
        if case let .string(fp)? = f["file_path"], !fp.isEmpty { filePath = fp } else { filePath = "(unspecified)" }
        var lineHint: String? = nil
        if case let .string(lh)? = f["line_hint"], !lh.isEmpty { lineHint = lh }

        return ReviewFinding(
            category: category,
            severity: severity,
            confidence: confidence,
            filePath: filePath,
            title: title,
            detail: detail,
            lineHint: lineHint
        )
    }

    // MARK: - Helpers

    /// Rank for the per-review cap: severity dominates, confidence breaks ties.
    private func priority(_ f: ReviewFinding) -> Int {
        severityRank(f.severity) * 3 + f.confidence.rank
    }

    private func severityRank(_ s: FlagSeverity) -> Int {
        switch s {
        case .high:   return 2
        case .medium: return 1
        case .low:    return 0
        }
    }
}
