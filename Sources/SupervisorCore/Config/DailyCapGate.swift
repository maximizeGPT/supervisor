// DailyCapGate.swift — the (cap, spent) pair every model call is gated on.
//
// One function, extracted from two copies of the same four lines in
// SupervisorApp (the triage client's capCheck and the multi-model panel's), so
// the fail-closed rule below lives in one place and has a test.
//
// Audit B4: both copies read today's spend as `(try? store.todayTotalUSD()) ?? 0`.
// A THROWN read — a locked SQLite file, a corrupt row, a disk that filled —
// therefore reported "$0 spent today," which is the one answer that guarantees
// the cap never trips. The gate that exists to bound spend failed OPEN, and it
// failed open exactly when the machine was already unhealthy.
//
// A read we could not perform now reports spend AT the cap, so calls are
// refused until the store answers again. The wrong direction to be wrong in is
// the direction that spends the owner's money.

import Foundation

public enum DailyCapGate {

    /// What the gate concluded. Was a bare `(cap, spent)` tuple until the
    /// blast-radius change below needed a third fact: whether `spent` is a real
    /// total or the synthetic stand-in a store we could not read produces.
    ///
    /// A caller that only wants "may I spend" still reads `cap` and `spent` and
    /// is unaffected. A caller that is the product's core safety function needs
    /// to tell "the owner's budget is used up" from "the ledger is broken,"
    /// because those deserve different answers.
    public struct Verdict: Sendable, Equatable {
        public let cap: Double
        public let spent: Double
        /// True when `spent` was synthesized from the cap because the cost
        /// store threw, rather than read from it. Never true on a real cap hit.
        public let storeReadFailed: Bool

        public init(cap: Double, spent: Double, storeReadFailed: Bool = false) {
            self.cap = cap
            self.spent = spent
            self.storeReadFailed = storeReadFailed
        }
    }

    /// Build the verdict `LLMClient.capCheck` expects.
    ///
    /// - Parameters:
    ///   - cap: the effective cap, or nil when the owner opted out of capping.
    ///   - spentUSD: today's recorded spend. May throw; a throw is treated as
    ///     "at the cap," never as zero.
    /// - Returns: nil when there is no cap to enforce (the client then skips
    ///   the gate entirely), otherwise the verdict to compare.
    public static func evaluate(
        cap: Double?,
        spentUSD: () throws -> Double,
        trace: TraceLog = .shared
    ) -> Verdict? {
        guard let cap else { return nil }
        do {
            return Verdict(cap: cap, spent: try spentUSD())
        } catch {
            // The error itself is not logged: a store error can quote row
            // contents, and this line goes to a file the owner may paste.
            trace.emit(
                "cost",
                "cap.fail_closed reason=spend_read_failed cap=\(String(format: "%.2f", cap)) — treating today as AT the cap until the cost store reads again"
            )
            return Verdict(cap: cap, spent: cap, storeReadFailed: true)
        }
    }
}
