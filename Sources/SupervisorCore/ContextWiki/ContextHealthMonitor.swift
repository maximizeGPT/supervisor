// ContextHealthMonitor.swift — the ambient "Context Health" verdict for the panel.
//
// The Context Health window is on-demand; this monitor is what lets the feature
// SELF-SURFACE quietly. It runs the deterministic auditor in the background
// (cheap, no API cost), derives a one-glance verdict, and — crucially — knows
// when its verdict is STALE (a CLAUDE.md / skill file changed since the last
// audit), so the panel never asserts "lean" over context the owner just edited.
// A confident-wrong "lean" burns trust in a single glance; honesty over
// reassurance is the rule.
//
// @MainActor ObservableObject so the panel binds to it directly. Pure product
// logic (audit + freshness), no window/UI. The app owns one instance and hands
// it to the HoverViewModel; the panel renders `state`.

import Combine
import Foundation

/// The one-glance verdict the panel line renders.
public enum ContextHealthState: Equatable, Sendable {
    /// Never audited yet.
    case unknown
    /// An audit is in flight.
    case checking
    /// Audited, nothing to clean up.
    case lean
    /// Audited, cleanups exist. `notable` is true at/above the notable severity
    /// band (the threshold that earns the single amber cue and the one nudge).
    case cleanups(count: Int, lines: Int, notable: Bool)
}
// Honesty over reassurance without a dead "stale" state: the monitor auto-
// re-audits on panel appear whenever a context file changed since the last audit
// (see `refreshIfNeeded`), so the line never SHOWS a stale "lean" — it shows
// `.checking` for the moment it re-verifies, then the fresh verdict.

@MainActor
public final class ContextHealthMonitor: ObservableObject {

    @Published public private(set) var state: ContextHealthState = .unknown
    @Published public private(set) var lastAuditAt: Date?

    public let root: URL
    private let auditor: ContextAuditor
    private let store: ContextAuditStore?
    private let trace: TraceLog

    /// Max context-file mtime observed at the moment of the last audit. Staleness
    /// is "a context file is now newer than this".
    private var mtimeAtLastAudit: Date?
    private var inFlight = false

    /// Fired once when a background audit first crosses `notable` for this root —
    /// the single "earned nudge". The app wires this to one notification and
    /// returns whether the post ACTUALLY succeeded. The monitor guarantees the
    /// nudge lands at most once EVER per root: the fired flag is persisted
    /// (UserDefaults) so it survives relaunches — but ONLY after a successful
    /// post. Persisting on the attempt would burn the one nudge on a failed
    /// `center.add` (or a not-yet-wired notifier) and the owner would never see
    /// it. A recurring drift stream would train the owner to dismiss
    /// Supervisor's notifications, which would poison the safety flags that are
    /// the product's core value.
    public var onFirstNotable: ((_ count: Int, _ lines: Int) async -> Bool)?
    private let defaults: UserDefaults
    private let nudgeKey: String
    private var firstNotableFired: Bool
    /// True while a nudge post is in flight, so overlapping audits can't
    /// double-post before the first result lands.
    private var nudgeInFlight = false

    public init(
        root: URL,
        auditor: ContextAuditor = ContextAuditor(),
        store: ContextAuditStore? = nil,
        trace: TraceLog = .shared,
        defaults: UserDefaults = SupervisorDefaults.shared
    ) {
        self.root = root
        self.auditor = auditor
        self.store = store
        self.trace = trace
        self.defaults = defaults
        self.nudgeKey = "contextHealth.nudged." + root.path
        self.firstNotableFired = defaults.bool(forKey: nudgeKey)
    }

    /// True when there is no trustworthy fresh verdict: never audited, or a
    /// context file changed since the last audit.
    public var isStale: Bool {
        guard lastAuditAt != nil, let baseline = mtimeAtLastAudit else { return true }
        guard let latest = Self.latestMTime(under: root) else { return false }
        return latest > baseline
    }

    /// Refresh only when needed: on first use, or when the context changed since
    /// the last audit. A fresh verdict is shown from cache instantly. Called from
    /// the panel's `.onAppear`, so opening the panel over unchanged context costs
    /// nothing, and over edited context re-checks rather than lying.
    public func refreshIfNeeded() {
        if case .unknown = state { refresh(); return }
        if isStale { refresh() }
    }

    /// Force a re-audit now (the panel's "Re-check", or an app-level tick).
    public func refresh() {
        guard !inFlight else { return }
        inFlight = true
        state = .checking
        let root = self.root
        let auditor = self.auditor
        let store = self.store
        let mtimeNow = Self.latestMTime(under: root)
        Task { [weak self] in
            let report = await auditor.audit(root: root)
            try? store?.record(report)
            await MainActor.run {
                guard let self else { return }
                self.applyReport(report, mtimeAtAudit: mtimeNow)
                self.inFlight = false
            }
        }
    }

    private func applyReport(_ report: AuditReport, mtimeAtAudit: Date?) {
        lastAuditAt = report.generatedAt
        mtimeAtLastAudit = mtimeAtAudit
        let actionable = report.recommendations.filter { $0.kind != .schemaRule }
        if actionable.isEmpty {
            state = .lean
        } else {
            let notable = report.topSeverity >= .notable
            state = .cleanups(count: actionable.count, lines: report.totalReclaimableLines, notable: notable)
            // The one earned nudge: fire once, EVER, on the first notable crossing.
            // The once-ever flag is persisted only AFTER the callback reports a
            // successful post — a failed post keeps the flag unset so the next
            // notable crossing can retry instead of silently burning the nudge.
            // `nudgeInFlight` stops overlapping audits from double-posting while
            // the first result is still pending.
            if notable, !firstNotableFired, !nudgeInFlight, let fire = onFirstNotable {
                nudgeInFlight = true
                let count = actionable.count
                let lines = report.totalReclaimableLines
                trace.emit("context-health", "first notable crossing for \(root.path): \(count) cleanups — firing single nudge")
                Task { [weak self] in
                    let posted = await fire(count, lines)
                    guard let self else { return }
                    self.nudgeInFlight = false
                    if posted {
                        self.firstNotableFired = true
                        self.defaults.set(true, forKey: self.nudgeKey)
                        self.trace.emit("context-health", "nudge posted for \(self.root.path) — once-ever flag persisted")
                    } else {
                        self.trace.emit("context-health", "nudge post FAILED for \(self.root.path) — once-ever flag NOT persisted; a later notable crossing may retry")
                    }
                }
            }
        }
    }

    // MARK: - Cheap staleness probe (mtime only, no content reads)

    /// The most recent modification time across the context tree under `root`,
    /// STAT ONLY (never reads file contents), so the staleness check is cheap
    /// enough to run on panel appear. Bounded depth; skips heavy/irrelevant dirs.
    static func latestMTime(under root: URL, maxDepth: Int = 8) -> Date? {
        let fm = FileManager.default
        var latest: Date?
        func consider(_ url: URL) {
            if let m = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
                if latest == nil || m > latest! { latest = m }
            }
        }
        func walk(_ dir: URL, _ depth: Int) {
            guard depth <= maxDepth else { return }
            let listPath = dir.resolvingSymlinksInPath().path
            guard let names = try? fm.contentsOfDirectory(atPath: listPath) else { return }
            for name in names {
                let entry = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.resolvingSymlinksInPath().path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if ContextSourceScanner.skippedDirNames.contains(name) { continue }
                    walk(entry, depth + 1)
                } else {
                    consider(entry)
                }
            }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        walk(root, 0)
        return latest
    }
}
