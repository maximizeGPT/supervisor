// SessionReportExporter.swift - v0.2.0 observability (Reddit feedback C).
//
// The exportable replay bundle. Given a sessionId, it gathers EVERYTHING
// Supervisor recorded for that session - the unified audit entries (PART A),
// the flags, the plan, and the per-step verdicts - and writes BOTH a
// machine-readable JSON and a human-readable Markdown report to a directory,
// returning the file paths. The point (from the Reddit thread) is that a user
// can inspect what Supervisor did INDEPENDENTLY of the app's own live summary:
// the bundle is a self-contained, portable receipt.
//
// This is a PURE function over the stores - it only READS (audit entries,
// flags, plan, session metadata) and WRITES two files. It holds no state, makes
// no model call, and changes nothing in the DB. The UI trigger ("Export session
// report" button) is a later milestone; this just exposes `export(...)`.

import Foundation

public struct SessionReportExporter: Sendable {

    private let auditStore: AuditStore
    private let flagStore: FlagStore
    private let planStore: PlanStore
    private let sessionStore: SessionStore?
    /// The exported bundle leaves the machine and lands in ~/Downloads, so it
    /// must honor the SAME redaction guarantee the DB does. The audit spine is
    /// already redacted at store time, but the session `cwd` and the flag
    /// `reasoning_*` columns are stored raw — a secret pasted into a path or
    /// echoed in Haiku's reasoning would otherwise ride out unredacted. Run
    /// those fields through the same DefaultRedactor the LLMClient uses on the
    /// wire, so the receipt matches the on-disk redaction posture.
    private let redactor: any Redactor

    /// - `sessionStore`: optional; only used to enrich the report header with
    ///   cwd / timestamps. The export works without it (the header just omits
    ///   the session metadata).
    /// - `redactor`: applied to the cwd + flag reasoning at gather time so the
    ///   exported bundle carries no secret the redaction spine would have
    ///   caught. Defaults to `DefaultRedactor` (the production patterns).
    public init(
        auditStore: AuditStore,
        flagStore: FlagStore,
        planStore: PlanStore,
        sessionStore: SessionStore? = nil,
        redactor: any Redactor = DefaultRedactor()
    ) {
        self.auditStore = auditStore
        self.flagStore = flagStore
        self.planStore = planStore
        self.sessionStore = sessionStore
        self.redactor = redactor
    }

    /// The paths written by `export`.
    public struct Output: Sendable, Equatable {
        public let jsonPath: URL
        public let markdownPath: URL
        public init(jsonPath: URL, markdownPath: URL) {
            self.jsonPath = jsonPath
            self.markdownPath = markdownPath
        }
    }

    /// Gather the session's audit trail + flags + plan + verdicts and write a
    /// JSON and a Markdown report into `directory`. Returns the two file paths.
    /// Creates `directory` if needed. The file stem is
    /// `session-report-<shortId>-<timestamp>` so repeated exports do not clobber.
    ///
    /// - `sessionId`: the session to report on.
    /// - `directory`: where to write the two files.
    /// - `now`: timestamp used in the filenames + header (injectable for tests).
    /// - `limit`: max audit entries / flags to include (newest-first).
    @discardableResult
    public func export(
        sessionId: String,
        to directory: URL,
        now: Date = Date(),
        limit: Int = 500
    ) throws -> Output {
        let report = try gather(sessionId: sessionId, now: now, limit: limit)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = "session-report-\(Self.shortId(sessionId))-\(Self.fileTimestamp(now))"
        let jsonURL = directory.appendingPathComponent("\(stem).json")
        let mdURL = directory.appendingPathComponent("\(stem).md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: jsonURL)

        let markdown = Self.renderMarkdown(report)
        try Data(markdown.utf8).write(to: mdURL)

        return Output(jsonPath: jsonURL, markdownPath: mdURL)
    }

    // MARK: - Gather (the machine-readable model)

    /// The full, serializable replay bundle for one session. This is exactly the
    /// JSON shape; the Markdown is rendered from the same struct.
    public struct SessionReport: Codable, Sendable, Equatable {
        public var sessionId: String
        public var generatedAt: Date
        public var cwd: String?
        public var startedAt: Date?
        public var lastSeenAt: Date?
        public var auditEntries: [AuditEntryDTO]
        public var flags: [FlagDTO]
        public var plan: PlanDTO?
    }

    /// One audit entry, flattened to the fields the report shows (the optional
    /// structured columns are kept; nils are simply omitted by the encoder when
    /// nil so the JSON stays readable).
    public struct AuditEntryDTO: Codable, Sendable, Equatable {
        public var id: String
        public var createdAt: Date
        public var kind: String
        public var summary: String
        public var question: String?
        public var contextUsed: String?
        public var authorizingRule: String?
        public var command: String?
        public var targetPath: String?
        public var riskReason: String?
        public var classification: String?
        public var detail: String?
    }

    public struct FlagDTO: Codable, Sendable, Equatable {
        public var id: String
        public var ts: Date
        public var category: String
        public var severity: String
        public var action: String
        public var reasoningPlain: String
        public var reasoningTechnical: String
        public var userResponse: String?
    }

    public struct PlanDTO: Codable, Sendable, Equatable {
        public var id: String
        public var objective: String
        public var status: String
        public var currentStepIndex: Int
        public var steps: [PlanStepDTO]
    }

    public struct PlanStepDTO: Codable, Sendable, Equatable {
        public var index: Int
        public var title: String
        public var objective: String
        public var doneCriteria: String
        public var status: String
        public var attempts: Int
        public var verdict: VerdictDTO?
    }

    public struct VerdictDTO: Codable, Sendable, Equatable {
        public var passed: Bool
        public var score: Double
        public var feedback: String
    }

    /// Read the stores and assemble the report struct. Public + pure (read-only)
    /// so a caller or test can inspect the model without writing files.
    public func gather(sessionId: String, now: Date = Date(), limit: Int = 500) throws -> SessionReport {
        let entries = (try? auditStore.entries(sessionId: sessionId, limit: limit)) ?? []
        let flags = (try? flagStore.recent(sessionId: sessionId, limit: limit)) ?? []
        let plan = (try? planStore.currentPlan(sessionId: sessionId)) ?? nil
        let session = try? sessionStore?.fetch(id: sessionId) ?? nil

        return SessionReport(
            sessionId: sessionId,
            generatedAt: now,
            // cwd is stored raw; redact it here so a secret pasted into a path
            // does not ride out in the exported header (or its Markdown render).
            // Map over the Optional (session), not the String's characters —
            // `session?.cwd.map { … }` would bind to Collection.map on the
            // non-optional cwd String and produce [String].
            cwd: session.map { redactor.redact($0.cwd) },
            startedAt: session?.startedAt,
            lastSeenAt: session?.lastSeenAt,
            auditEntries: entries.map(Self.auditDTO(from:)),
            // flag reasoning is stored raw; redact via the instance method so
            // reasoning_plain / reasoning_technical match the DB's redaction.
            flags: flags.map { flagDTO(from: $0) },
            plan: plan.map(Self.planDTO(from:))
        )
    }

    // MARK: - Mapping (stored -> DTO)

    private static func auditDTO(from e: StoredAuditEntry) -> AuditEntryDTO {
        AuditEntryDTO(
            id: e.id, createdAt: e.createdAt, kind: e.kind.rawValue, summary: e.summary,
            question: e.question, contextUsed: e.contextUsed, authorizingRule: e.authorizingRule,
            command: e.command, targetPath: e.targetPath, riskReason: e.riskReason,
            classification: e.classification, detail: e.detail
        )
    }

    /// Instance method (not static) so it can run the raw reasoning columns
    /// through the injected redactor. category/severity/action are enum-ish
    /// controlled vocab (no free-text secrets); only the two reasoning strings
    /// carry model/user prose, so those are the ones redacted.
    private func flagDTO(from f: StoredFlag) -> FlagDTO {
        FlagDTO(
            id: f.id, ts: f.ts, category: f.category, severity: f.severity.rawValue,
            action: f.action.rawValue,
            reasoningPlain: redactor.redact(f.reasoningPlain),
            reasoningTechnical: redactor.redact(f.reasoningTechnical),
            userResponse: f.userResponse?.rawValue
        )
    }

    private static func planDTO(from p: Plan) -> PlanDTO {
        PlanDTO(
            id: p.id, objective: p.objective, status: p.status.rawValue,
            currentStepIndex: p.currentStepIndex,
            steps: p.steps.map { s in
                PlanStepDTO(
                    index: s.index, title: s.title, objective: s.objective,
                    doneCriteria: s.doneCriteria, status: s.status.rawValue, attempts: s.attempts,
                    verdict: s.lastVerdict.map { VerdictDTO(passed: $0.passed, score: $0.score, feedback: $0.feedback) }
                )
            }
        )
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(_ r: SessionReport) -> String {
        var out: [String] = []
        out.append("# Supervisor session report")
        out.append("")
        out.append("- Session: `\(r.sessionId)`")
        if let cwd = r.cwd { out.append("- Working directory: `\(cwd)`") }
        if let started = r.startedAt { out.append("- Started: \(iso(started))") }
        if let seen = r.lastSeenAt { out.append("- Last seen: \(iso(seen))") }
        out.append("- Report generated: \(iso(r.generatedAt))")
        out.append("- Audit entries: \(r.auditEntries.count) | Flags: \(r.flags.count) | Plan: \(r.plan == nil ? "none" : "present")")
        out.append("")

        // Audit log - the spine.
        out.append("## Audit log (what Supervisor did, and why)")
        out.append("")
        if r.auditEntries.isEmpty {
            out.append("_No audit entries recorded for this session._")
        } else {
            for e in r.auditEntries {
                out.append("### [\(e.kind)] \(iso(e.createdAt))")
                out.append("")
                out.append(e.summary)
                if let q = e.question { out.append("- Question: \(q)") }
                if let c = e.contextUsed { out.append("- Context used: \(c)") }
                if let a = e.authorizingRule { out.append("- Authorizing rule: \(a)") }
                if let cmd = e.command { out.append("- Command: `\(cmd)`") }
                if let t = e.targetPath { out.append("- Target: `\(t)`") }
                if let rr = e.riskReason { out.append("- Risk reason: \(rr)") }
                if let cl = e.classification { out.append("- Stall classification: \(cl)") }
                out.append("")
            }
        }

        // Flags.
        out.append("## Flags")
        out.append("")
        if r.flags.isEmpty {
            out.append("_No flags recorded for this session._")
        } else {
            for f in r.flags {
                out.append("- **\(f.severity)/\(f.action)** \(f.category) (\(iso(f.ts)))\(f.userResponse.map { " - response: \($0)" } ?? "")")
                out.append("  - \(f.reasoningPlain)")
            }
        }
        out.append("")

        // Plan + verdicts.
        out.append("## Plan")
        out.append("")
        if let plan = r.plan {
            out.append("Objective: \(plan.objective)")
            out.append("")
            out.append("Status: **\(plan.status)** (on step \(plan.currentStepIndex + 1) of \(plan.steps.count))")
            out.append("")
            for s in plan.steps {
                let mark = s.verdict?.passed == true ? "x" : " "
                out.append("- [\(mark)] **Step \(s.index + 1): \(s.title)** - \(s.status)")
                if let v = s.verdict {
                    out.append("  - Verdict: \(v.passed ? "passed" : "not yet") (score \(String(format: "%.2f", v.score)))")
                    if !v.feedback.isEmpty { out.append("  - Feedback: \(v.feedback)") }
                }
            }
        } else {
            out.append("_No plan for this session._")
        }
        out.append("")

        return out.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// A filesystem-safe compact timestamp (no colons) for the filename.
    static func fileTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// First 8 chars of the session id for a readable, collision-resistant stem.
    static func shortId(_ sessionId: String) -> String {
        let cleaned = sessionId.filter { $0.isLetter || $0.isNumber }
        return String(cleaned.prefix(8))
    }
}
