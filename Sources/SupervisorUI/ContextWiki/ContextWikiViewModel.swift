// ContextWikiViewModel.swift — state for the Context Health window.
//
// Drives the SwiftUI ContextWikiView: runs the auditor, holds the current
// report, tracks which recommendations the owner has signed off on, and derives
// the one-glance verdict. @MainActor + ObservableObject, the same shape as
// HoverViewModel / OnboardingViewModel.
//
// HONEST BEHAVIOR. "Accepting" a recommendation records the owner's sign-off; it
// does NOT edit any file. Applying is a separate, deliberate step (by the owner
// or a supervised session). Nothing in this view model mutates a source tree.

import Combine
import Foundation
import SupervisorCore

@MainActor
public final class ContextWikiViewModel: ObservableObject {

    public enum Tab: Hashable, Sendable { case recommendations, wiki, schema }

    /// The current audit result. `nil` before the first audit completes.
    @Published public private(set) var report: AuditReport?
    /// True while an audit is in flight (drives the re-audit spinner).
    @Published public private(set) var isAuditing = false
    /// Selected content tab.
    @Published public var tab: Tab = .recommendations
    /// Stable signatures of recommendations the owner has accepted (sign-off).
    /// Keyed by content, not the per-run UUID, so an accept survives a re-audit
    /// as long as the recommendation itself is unchanged.
    @Published public private(set) var acceptedKeys: Set<String> = []
    /// Which recommendations have their affected-files list expanded.
    @Published public var expandedKeys: Set<String> = []

    public let root: URL
    private let auditor: ContextAuditor
    private let store: ContextAuditStore?

    public init(
        root: URL,
        auditor: ContextAuditor = ContextAuditor(),
        store: ContextAuditStore? = nil,
        initialReport: AuditReport? = nil
    ) {
        self.root = root
        self.auditor = auditor
        self.store = store
        self.report = initialReport
    }

    // MARK: - Actions

    /// Run a fresh (deterministic) audit of the root. Idempotent while in flight.
    public func runAudit() {
        guard !isAuditing else { return }
        isAuditing = true
        let root = self.root
        let auditor = self.auditor
        let store = self.store
        Task { [weak self] in
            let result = await auditor.audit(root: root)
            try? store?.record(result)
            await MainActor.run {
                guard let self else { return }
                self.report = result
                self.isAuditing = false
            }
        }
    }

    /// Content signature for a recommendation — stable across re-audits.
    public func key(for rec: Recommendation) -> String { "\(rec.kind.rawValue)|\(rec.title)" }

    public func isAccepted(_ rec: Recommendation) -> Bool { acceptedKeys.contains(key(for: rec)) }

    /// Record the owner's sign-off. Non-destructive — no file is touched.
    public func accept(_ rec: Recommendation) { acceptedKeys.insert(key(for: rec)) }

    /// Undo a sign-off (nothing was applied, so this is always safe).
    public func undo(_ rec: Recommendation) { acceptedKeys.remove(key(for: rec)) }

    public func isExpanded(_ rec: Recommendation) -> Bool { expandedKeys.contains(key(for: rec)) }

    public func toggleFiles(_ rec: Recommendation) {
        let k = key(for: rec)
        if expandedKeys.contains(k) { expandedKeys.remove(k) } else { expandedKeys.insert(k) }
    }

    // MARK: - Derived

    /// Actionable cleanups (everything that isn't an advisory schema rule), in the
    /// report's severity rank. Order is STABLE as items are approved — the list
    /// doesn't jump under the cursor; the "one lit path" highlight simply moves to
    /// the next unresolved card.
    public var actionable: [Recommendation] {
        report?.recommendations.filter { $0.kind != .schemaRule } ?? []
    }

    /// The single highest-ranked cleanup not yet signed off — the one card that
    /// gets the primary (filled) action, so only ONE next step is lit at a time.
    public var topUnresolvedKey: String? {
        actionable.first { !isAccepted($0) }.map { key(for: $0) }
    }

    public func isTopUnresolved(_ rec: Recommendation) -> Bool { topUnresolvedKey == key(for: rec) }

    /// The approved cleanups formatted as a copy-pasteable task list — the real
    /// destination for sign-offs, so the flow doesn't dead-end. A user (or a
    /// supervised session) can paste this and do the work; nothing is auto-applied.
    public func approvedTasksText() -> String {
        let approved = actionable.filter(isAccepted)
        guard !approved.isEmpty else { return "" }
        var out = "# Context cleanups to apply (\(approved.count)) — approved in Supervisor\n"
        out += "# Root: \(root.path)\n\n"
        for rec in approved {
            out += "- [ ] \(rec.title)\n"
            out += "      \(rec.rationale)\n"
            if !rec.affectedPaths.isEmpty {
                out += "      files: \(rec.affectedPaths.joined(separator: ", "))\n"
            }
            out += "\n"
        }
        return out
    }

    public var schemaRules: [Recommendation] { report?.recommendations.filter { $0.kind == .schemaRule } ?? [] }

    public var duplicatedTopics: [WikiTopic] { report?.wiki.filter(\.isDuplicated) ?? [] }

    /// No actionable cleanups -> the delightful "all clear" state.
    public var isClean: Bool { (report?.recommendations.contains { $0.kind != .schemaRule }) == false }

    public var acceptedCount: Int { actionable.filter(isAccepted).count }

    /// The one-glance verdict shown in the hero, derived from the top severity.
    public struct Verdict: Equatable {
        public var headline: String
        /// The single accented word inside the headline (rendered in the accent tone).
        public var accentWord: String
        public var subline: String
        public var severity: SeverityBand
    }

    public var verdict: Verdict {
        guard let report else {
            return Verdict(headline: "Audit your context.", accentWord: "audit", subline: "See what's bloating your CLAUDE.md and skills.", severity: .info)
        }
        let n = actionable.count
        if n == 0 {
            return Verdict(headline: "All clear.", accentWord: "clear", subline: "No duplication, no oversized files, nothing to prune.", severity: .info)
        }
        let word = n == 1 ? "suggestion" : "suggestions"
        let reclaim = report.totalReclaimableLines
        let reclaimClause = reclaim > 0 ? " worth ~\(reclaim) reclaimable lines" : ""
        switch report.topSeverity {
        case .major:
            return Verdict(headline: "Worth a cleanup.", accentWord: "cleanup",
                           subline: "\(n) \(word)\(reclaimClause). Nothing has been changed.", severity: .major)
        case .notable:
            return Verdict(headline: "A few cleanups.", accentWord: "cleanups",
                           subline: "\(n) \(word)\(reclaimClause). Nothing has been changed.", severity: .notable)
        default:
            return Verdict(headline: "Minor tidying.", accentWord: "tidying",
                           subline: "\(n) small \(word)\(reclaimClause). Nothing has been changed.", severity: .minor)
        }
    }

    /// Bytes the model actually loads as context vs. everything else (scripts +
    /// assets). Both in bytes, so the split is comparable.
    public var contextBytes: Int { max(0, (report?.metrics.totalBytes ?? 0) - (report?.metrics.nonContextBytes ?? 0)) }
    public var nonContextBytes: Int { report?.metrics.nonContextBytes ?? 0 }
}
