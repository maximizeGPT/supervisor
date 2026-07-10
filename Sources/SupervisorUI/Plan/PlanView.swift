// PlanView.swift — v0.2.0 M3, the live Plan centerpiece.
//
// The PLAN surface from the Stitch brief, bound to the watched session's live
// plan: the objective heading with its StatusChip, the ordered plan-step list
// in a BrandCard (the active step expanded to its done-criteria + boxed
// evaluator feedback), and the footer pairing a quiet Pause (BrandSecondary-
// Button) with the green Approve plan (BrandPrimaryButton). It is the headline
// visual payoff — a calm instrument panel, one accent, type-driven hierarchy.
//
// Composition only: every piece is an existing primitive (StatusChip,
// PlanStepRow, StepStateIcon, BrandCard, the buttons, BrandSectionHeader) over
// the tokens. PlanView holds no state; it takes a Plan plus the two actions and
// renders. ExpandedPanelView decides when to show it (a plan exists) vs the
// prior flags/activity content.
//
// "Approve plan" is enabled only while the plan is awaiting approval — the
// visible approval gate. Once running it disables (the plan is already moving),
// matching the StatusChip beside the objective. Pause is always available.

import SwiftUI
import SupervisorCore

public struct PlanView: View {

    private let plan: Plan
    /// Whether Supervisor is globally paused — flips the StatusChip to "Paused"
    /// and the Pause button to a Resume affordance, since pause/resume is the
    /// global toggle, not a plan-state change.
    private let isPaused: Bool
    /// Whether a live session kill is in effect. Folds into the StatusChip as
    /// "Stopped" so a `running` plan under a live kill never reads "Running"
    /// (RC fix #5). Defaults false, so existing call sites are unchanged.
    private let isStopped: Bool
    /// Whether the plan has been approved optimistically from the panel (the
    /// approve handler is async). Disables the Approve button immediately so it
    /// does not read as still-actionable while the store round-trips (RC fix #1).
    private let approvedOptimistically: Bool
    private let onApprove: () -> Void
    private let onPauseToggle: () -> Void
    /// Optional "open the dark plan-detail view" action. When non-nil the
    /// objective header shows a quiet "Details" affordance that swaps the panel
    /// to PlanDetailView (Stitch screen 2). nil (the default) hides it, so the
    /// existing call sites and tests keep the compact view with no extra chrome.
    private let onShowDetail: (() -> Void)?
    /// Optional "cross over to the normal Status control panel" action. When
    /// non-nil the objective header shows a quiet "Panel" affordance (muted
    /// navigation chrome, no green) that swaps the panel to the status surface;
    /// a matching "Back to plan" control returns. nil (the default) hides it, so
    /// existing call sites and tests keep the plan-only header with no extra
    /// chrome.
    private let onShowPanel: (() -> Void)?

    public init(
        plan: Plan,
        isPaused: Bool,
        isStopped: Bool = false,
        approvedOptimistically: Bool = false,
        onApprove: @escaping () -> Void,
        onPauseToggle: @escaping () -> Void,
        onShowDetail: (() -> Void)? = nil,
        onShowPanel: (() -> Void)? = nil
    ) {
        self.plan = plan
        self.isPaused = isPaused
        self.isStopped = isStopped
        self.approvedOptimistically = approvedOptimistically
        self.onApprove = onApprove
        self.onPauseToggle = onPauseToggle
        self.onShowDetail = onShowDetail
        self.onShowPanel = onShowPanel
    }

    private var canApprove: Bool {
        // Optimistic approval disables the button immediately, before the async
        // handler flips plan.status (RC fix #1).
        guard !approvedOptimistically else { return false }
        return plan.status == .draft || plan.status == .awaitingApproval || plan.status == .approved
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.lg) {
            objectiveHeader
            planCard
        }
        .padding(BrandSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandColor.paper.color)
    }

    // MARK: - Objective header (overline + heading + status chip)

    private var objectiveHeader: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.md) {
                BrandSectionHeader("Plan")
                Spacer()
                if let onShowPanel {
                    // The quiet way OVER to the normal Status control panel
                    // (flags / activity / controls). Muted navigation chrome
                    // with a glyph (no green: green stays the one primary
                    // action), so it reads as a cross-over hint, not a CTA.
                    Button(action: onShowPanel) {
                        HStack(spacing: BrandSpacing.xxs) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Panel")
                                .font(BrandFont.note)
                        }
                        .foregroundStyle(BrandColor.mute.color)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let onShowDetail {
                    // The quiet way INTO the dark detail register. A plain text
                    // affordance (no green: green stays the one primary action),
                    // so it reads as a navigation hint, not a second CTA.
                    Button(action: onShowDetail) {
                        HStack(spacing: BrandSpacing.xxs) {
                            Text("Details")
                                .font(BrandFont.note)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(BrandColor.mute.color)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .top, spacing: BrandSpacing.sm) {
                // A CALM heading, never a raw prompt dump. When the watched
                // session is a scheduled-task / routine run, plan.objective is
                // the full opening prompt (a long <scheduled-task ...> block);
                // displayTitle distills it to a short human title. The full
                // text still lives in PlanDetailView's "Routine prompt" section.
                // Capped at 3 lines so the compact surface stays a fixed heading.
                Text(PlanView.displayTitle(for: plan.objective))
                    .font(BrandFont.title)
                    .foregroundStyle(BrandColor.ink.color)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BrandSpacing.sm)
                statusChip
            }
        }
    }

    /// The plan's live-state chip. A live kill wins ("Stopped"), then a pause
    /// ("Paused"), else the plan's own status. Folding the live session state in
    /// keeps a killed/paused session from reading as "Running" (RC fix #5).
    @ViewBuilder
    private var statusChip: some View {
        if isStopped {
            StatusChip(.stopped)
        } else if isPaused {
            StatusChip(.paused)
        } else {
            StatusChip(planStatus: plan.status)
        }
    }

    // MARK: - Display-title derivation (pure, unit-testable)

    /// Distill a raw plan objective into a concise, human-readable title for
    /// the objective heading. Pure String -> String, no view state, so it can
    /// be unit-tested directly. Rules, applied in order:
    ///
    ///   1. Routine / scheduled-task wrapper: if the objective carries a
    ///      `name="..."` attribute (or a `file=".../<name>/SKILL.md"` path), use
    ///      that routine name, humanized: split on - and _, sentence-case the
    ///      first word. So "supervisor-tweet-engine" becomes "Supervisor tweet
    ///      engine".
    ///   2. A short, real first line (a sentence or heading under ~100 chars):
    ///      use it as-is.
    ///   3. Otherwise: the objective truncated to ~140 chars at a word boundary.
    ///
    /// In every case leading XML / markdown wrapper noise (an opening `<tag ...>`
    /// or a ``` code fence) is stripped from whatever is shown.
    public static func displayTitle(for objective: String) -> String {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rule 1: a routine / scheduled-task wrapper. Prefer an explicit
        // name="..." attribute; fall back to the <name>/SKILL.md path segment.
        if let routine = routineName(in: trimmed) {
            return humanize(routine)
        }

        // Strip leading wrapper noise (an opening tag or a code fence) before
        // we treat the remaining text as a sentence/heading.
        let cleaned = stripLeadingWrapperNoise(trimmed)

        // Rule 2: a short, real first line reads as a heading already.
        if let firstLine = cleaned
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map({ $0.trimmingCharacters(in: .whitespaces) }),
           !firstLine.isEmpty,
           firstLine.count <= 100 {
            return firstLine
        }

        // Rule 3: truncate the whole objective at a word boundary near 140 chars.
        return truncateAtWordBoundary(
            cleaned.replacingOccurrences(of: "\n", with: " "),
            limit: 140
        )
    }

    /// Extract a routine name from a scheduled-task / routine wrapper, or nil if
    /// the objective is not such a wrapper. Looks first for a `name="..."`
    /// attribute, then for a `.../<name>/SKILL.md` path inside a `file="..."`
    /// (or anywhere in the text). Returns the raw token (e.g.
    /// "supervisor-tweet-engine"), not yet humanized.
    private static func routineName(in text: String) -> String? {
        // name="supervisor-tweet-engine"
        if let value = attributeValue(named: "name", in: text), !value.isEmpty {
            return value
        }
        // file=".../supervisor-tweet-engine/SKILL.md" -> the parent dir name.
        if let file = attributeValue(named: "file", in: text),
           let name = skillDirName(in: file) {
            return name
        }
        // Bare path fallback (a SKILL.md path with no surrounding file="...").
        if let name = skillDirName(in: text) {
            return name
        }
        return nil
    }

    /// The unquoted value of an `attr="..."` (or `attr='...'`) attribute, or nil
    /// if absent. A small hand-rolled scan: we avoid pulling in a regex engine
    /// for one attribute and keep the helper pure.
    private static func attributeValue(named attr: String, in text: String) -> String? {
        for quote in ["\"", "'"] {
            let marker = "\(attr)=\(quote)"
            guard let start = text.range(of: marker) else { continue }
            let valueStart = start.upperBound
            guard let end = text.range(
                of: quote, range: valueStart..<text.endIndex
            ) else { continue }
            return String(text[valueStart..<end.lowerBound])
        }
        return nil
    }

    /// Given a path ending in ".../<name>/SKILL.md", return `<name>`; nil if the
    /// path does not name a SKILL.md directory. Case-insensitive on the filename.
    private static func skillDirName(in path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let skillIndex = components.lastIndex(where: {
            $0.lowercased() == "skill.md"
        }), skillIndex > 0 else { return nil }
        let name = components[skillIndex - 1]
        return name.isEmpty ? nil : name
    }

    /// Humanize a routine token: split on `-` and `_`, then sentence-case the
    /// first word and lowercase the rest. "supervisor-tweet-engine" becomes
    /// "Supervisor tweet engine"; "my_routine" becomes "My routine".
    private static func humanize(_ token: String) -> String {
        let words = token
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return token }
        let lowered = words.map { $0.lowercased() }
        let first = lowered[0].prefix(1).uppercased() + lowered[0].dropFirst()
        return ([first] + lowered.dropFirst()).joined(separator: " ")
    }

    /// Strip a leading XML/markdown wrapper so the shown text starts at real
    /// content: a single opening tag (`<tag ...>`) and/or an opening code fence
    /// (```), each at the very start. We only peel the leading noise; the rest
    /// of the text is left intact (later rules truncate it).
    private static func stripLeadingWrapperNoise(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading code fence line (``` or ```lang).
        if result.hasPrefix("```"),
           let newline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A single leading opening tag (<tag ...>), not a closing </tag>.
        if result.hasPrefix("<"), !result.hasPrefix("</"),
           let close = result.firstIndex(of: ">") {
            result = String(result[result.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Truncate `text` to at most `limit` characters at a word boundary, adding
    /// a trailing ellipsis when anything was cut. Never splits a word: if no
    /// space falls inside the window it falls back to a hard cut at the limit.
    private static func truncateAtWordBoundary(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let window = collapsed.prefix(limit)
        if let lastSpace = window.lastIndex(of: " ") {
            let head = window[..<lastSpace]
                .trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head + "\u{2026}" }
        }
        return String(window) + "\u{2026}"
    }

    // MARK: - Plan-step list (the ordered steps; active one expanded)

    private var planCard: some View {
        BrandCard(padding: BrandSpacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { offset, step in
                    if offset > 0 {
                        Divider()
                            .overlay(BrandColor.mute.color.opacity(0.15))
                            .padding(.vertical, BrandSpacing.xxs)
                    }
                    PlanStepRow(step, expanded: isExpandedStep(step))
                }
            }
        }
    }

    /// The active step (the one the loop is on) expands to show its rubric +
    /// boxed verdict, per the brief. A retrying step counts as active.
    private func isExpandedStep(_ step: PlanStep) -> Bool {
        step.status == .active || step.status == .retrying
    }

    // MARK: - Footer (Pause + Approve plan)

    /// The footer pair. ExpandedPanelView renders this beneath the plan body so
    /// it pins to the panel's bottom edge; exposed here so the pairing + enabled
    /// rule live with the plan.
    public var footer: some View {
        HStack(spacing: BrandSpacing.sm) {
            BrandSecondaryButton(isPaused ? "Resume" : "Pause", action: onPauseToggle)
            Spacer()
            BrandPrimaryButton("Approve plan", action: onApprove)
                .disabled(!canApprove)
        }
    }
}
