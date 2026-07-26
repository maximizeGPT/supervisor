// TrustScorecard.swift — issue #60 metric 1 (the measured-experience gate).
//
// Aggregates flag outcomes per category from the ledgers Supervisor ALREADY
// persists, so "are users learning to ignore Supervisor" is a mechanical read
// instead of a feeling:
//
//   - `flags` (migration v1): every raised flag with category / severity / ts,
//     plus `user_response` — the explicit reaction the hover panel records via
//     FlagStore.markUserResponse (approved | dismissed | false_positive |
//     rejected), or an explicitly dismissed notification banner recorded via
//     markUserResponseIfUnset (issue #60 follow-up; a panel click always wins).
//     NULL means the user never gave an explicit reaction on either surface.
//   - `audit_entries` (migration v5): the actions Supervisor actually took
//     (autoAnswer / block / nudge / planStep / verdict / review), counted by
//     kind as the intervention-volume side of the scorecard.
//
//   - `flags.intervention_outcome` (migration v10, the issue #60 follow-up):
//     what the intervention ACTUALLY did (injectSucceeded vs injectDegraded,
//     pauseSucceeded, continueFired, queued, ...), written per flag from the
//     Notifier's result hook via FlagStore.markInterventionOutcome. Counted
//     only where non-NULL — rows predating the column (or whose decision
//     never reached the router's result hook) have none, and the render says
//     so instead of approximating.
//
// Pure math over fetched rows (`compute`) so it is unit-testable without the
// CLI; `load` is the thin DB read the DevTools `trust-scorecard` case calls.
// Same Sendable-struct-over-the-serial-DatabaseQueue shape as the stores.

import Foundation
import GRDB

public struct TrustScorecard: Sendable, Equatable {

    // MARK: - Response counts

    /// The explicit-response buckets for a set of flags. `noResponse` is kept
    /// OUT of the rate: the panel only records a response when the user
    /// actually clicks one, so an unresponded flag is unknown, not dismissed.
    public struct ResponseCounts: Sendable, Equatable {
        public var approved: Int
        public var dismissed: Int
        public var falsePositive: Int
        public var rejected: Int
        public var noResponse: Int

        public init(
            approved: Int = 0,
            dismissed: Int = 0,
            falsePositive: Int = 0,
            rejected: Int = 0,
            noResponse: Int = 0
        ) {
            self.approved = approved
            self.dismissed = dismissed
            self.falsePositive = falsePositive
            self.rejected = rejected
            self.noResponse = noResponse
        }

        /// Flags the user explicitly responded to (any of the four buckets).
        public var responded: Int { approved + dismissed + falsePositive + rejected }

        /// All flags counted, responded or not.
        public var total: Int { responded + noResponse }

        /// The headline metric: the share of EXPLICIT responses that pushed
        /// back — dismissed + false-positive + rejected (the panel labels it Override) — over
        /// `responded`. Approval is the only positive outcome. `nil` when
        /// nothing was responded to (a rate over zero would be noise).
        public var dismissalRate: Double? {
            guard responded > 0 else { return nil }
            return Double(dismissed + falsePositive + rejected) / Double(responded)
        }
    }

    // MARK: - Per-category line

    /// One flag category's window totals: volume by severity + the response
    /// buckets. `category` is the free-form string the triage rubric emits
    /// (e.g. "destructive_action_pending"), kept verbatim.
    public struct CategoryLine: Sendable, Equatable {
        public var category: String
        public var low: Int
        public var medium: Int
        public var high: Int
        public var responses: ResponseCounts

        public init(
            category: String,
            low: Int = 0,
            medium: Int = 0,
            high: Int = 0,
            responses: ResponseCounts = ResponseCounts()
        ) {
            self.category = category
            self.low = low
            self.medium = medium
            self.high = high
            self.responses = responses
        }

        public var total: Int { responses.total }
    }

    // MARK: - Scorecard

    public var sinceDays: Int
    public var cutoff: Date
    /// Sorted highest-volume first, ties by category name, so the render is
    /// deterministic and the loudest category leads.
    public var categories: [CategoryLine]
    public var overall: ResponseCounts
    /// Actions Supervisor actually took in the window, counted by
    /// audit_entries.kind rawValue (autoAnswer / block / nudge / ...).
    public var actionsTaken: [String: Int]
    /// issue #60 follow-up: real intervention outcomes in the window, counted
    /// by flags.intervention_outcome rawValue (inject_succeeded /
    /// inject_degraded / pause_succeeded / ...) over rows where the column is
    /// non-NULL only. Rows predating migration v10 have none and are excluded
    /// — never guessed at.
    public var interventionOutcomes: [String: Int]

    // MARK: - Compute (pure)

    /// Aggregate the scorecard from already-fetched rows. Rows older than
    /// `now - sinceDays` are excluded here (not at the fetch), so tests can
    /// assert the window math directly on seeded arrays.
    public static func compute(
        flags: [StoredFlag],
        auditEntries: [StoredAuditEntry],
        sinceDays: Int,
        now: Date = Date()
    ) -> TrustScorecard {
        let cutoff = now.addingTimeInterval(-Double(sinceDays) * 86_400)

        var byCategory: [String: CategoryLine] = [:]
        var overall = ResponseCounts()
        var outcomes: [String: Int] = [:]
        for flag in flags where flag.ts >= cutoff {
            // issue #60 follow-up: count the REAL outcome only where one was
            // recorded (non-NULL). NULL is "unknown", never a bucket.
            if let outcome = flag.interventionOutcome {
                outcomes[outcome.rawValue, default: 0] += 1
            }
            var line = byCategory[flag.category] ?? CategoryLine(category: flag.category)
            switch flag.severity {
            case .low:    line.low += 1
            case .medium: line.medium += 1
            case .high:   line.high += 1
            }
            switch flag.userResponse {
            case .approved?:      line.responses.approved += 1;      overall.approved += 1
            case .dismissed?:     line.responses.dismissed += 1;     overall.dismissed += 1
            case .falsePositive?: line.responses.falsePositive += 1; overall.falsePositive += 1
            case .rejected?:      line.responses.rejected += 1;      overall.rejected += 1
            case nil:             line.responses.noResponse += 1;    overall.noResponse += 1
            }
            byCategory[flag.category] = line
        }

        var actions: [String: Int] = [:]
        for entry in auditEntries where entry.createdAt >= cutoff {
            actions[entry.kind.rawValue, default: 0] += 1
        }

        let sorted = byCategory.values.sorted {
            $0.total != $1.total ? $0.total > $1.total : $0.category < $1.category
        }
        return TrustScorecard(
            sinceDays: sinceDays,
            cutoff: cutoff,
            categories: sorted,
            overall: overall,
            actionsTaken: actions,
            interventionOutcomes: outcomes
        )
    }

    // MARK: - Load (thin DB read)

    /// Fetch the window's rows from the Supervisor DB and compute. Read-only;
    /// raw SQL bounded by the cutoff so a long-lived DB never loads its full
    /// history just to score the last month.
    public static func load(
        database: SupervisorDatabase,
        sinceDays: Int,
        now: Date = Date()
    ) throws -> TrustScorecard {
        let cutoff = now.addingTimeInterval(-Double(sinceDays) * 86_400)
        let (flags, entries) = try database.queue.read { conn -> ([StoredFlag], [StoredAuditEntry]) in
            let flags = try StoredFlag.fetchAll(
                conn,
                sql: "SELECT * FROM flags WHERE ts >= ? ORDER BY ts DESC",
                arguments: [cutoff]
            )
            let entries = try StoredAuditEntry.fetchAll(
                conn,
                sql: "SELECT * FROM audit_entries WHERE created_at >= ? ORDER BY created_at DESC",
                arguments: [cutoff]
            )
            return (flags, entries)
        }
        return compute(flags: flags, auditEntries: entries, sinceDays: sinceDays, now: now)
    }

    // MARK: - Render

    /// Console table for the DevTools case. Deterministic (sorted categories,
    /// fixed UTC date formatting) so output is assertable in tests and
    /// diffable across runs.
    public func render() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        lines.append("Trust scorecard — last \(sinceDays) days (since \(df.string(from: cutoff)) UTC)")
        lines.append("")

        if categories.isEmpty {
            lines.append("no flags recorded in this window.")
        } else {
            lines.append("flags: \(overall.total) total, \(overall.responded) with an explicit response")
            lines.append("")
            lines.append(Self.row("category",
                                  ["total", "low", "med", "high",
                                   "appr", "dism", "fp", "rej", "none", "dismissal"]))
            for line in categories {
                lines.append(Self.row(line.category, [
                    String(line.total), String(line.low), String(line.medium), String(line.high),
                    String(line.responses.approved), String(line.responses.dismissed),
                    String(line.responses.falsePositive), String(line.responses.rejected),
                    String(line.responses.noResponse),
                    Self.rateString(line.responses.dismissalRate),
                ]))
            }
            lines.append(Self.row("overall", [
                String(overall.total), "", "", "",
                String(overall.approved), String(overall.dismissed),
                String(overall.falsePositive), String(overall.rejected),
                String(overall.noResponse),
                Self.rateString(overall.dismissalRate),
            ]))
        }

        lines.append("")
        if actionsTaken.isEmpty {
            lines.append("actions taken (audit_entries): none in window")
        } else {
            let parts = actionsTaken
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
            lines.append("actions taken (audit_entries): " + parts.joined(separator: "  "))
        }

        lines.append("")
        if interventionOutcomes.isEmpty {
            lines.append("intervention outcomes (flags.intervention_outcome): none recorded in window")
        } else {
            let parts = interventionOutcomes
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
            lines.append("intervention outcomes (flags.intervention_outcome): " + parts.joined(separator: "  "))
        }

        lines.append("")
        lines.append("notes:")
        lines.append("  dismissal rate = dismissed + false-positive + rejected (the panel's Override button), over flags with an explicit response.")
        lines.append("  a flag with no recorded response is NOT counted as dismissed — the panel only records a response when the user clicks one.")
        lines.append("  intervention outcomes are the executor's REAL result (issue #60 follow-up, migration v10), counted only where recorded — flags predating the column have none.")
        lines.append("  an explicitly dismissed flag BANNER records dismissed (only if no panel response exists); a plain banner tap opens the app and is NOT recorded as a response.")
        return lines.joined(separator: "\n")
    }

    /// One table row: a left-aligned (truncated) category column + right-aligned
    /// numeric columns.
    private static func row(_ category: String, _ cols: [String]) -> String {
        let nameWidth = 30
        let trimmed = category.count > nameWidth
            ? String(category.prefix(nameWidth - 1)) + "…"
            : category
        var out = trimmed + String(repeating: " ", count: max(0, nameWidth - trimmed.count))
        let widths = [6, 5, 5, 5, 6, 6, 5, 6, 6, 11]
        for (i, col) in cols.enumerated() {
            let w = i < widths.count ? widths[i] : 6
            out += String(repeating: " ", count: max(1, w - col.count)) + col
        }
        return out
    }

    private static func rateString(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }
}
