// PlanDetailView.swift - v0.2.0 M3, Stitch screen 2 (the dark "plan detail").
//
// The focused, single-objective deep view from the Stitch brief: the same plan
// design language as the compact light PlanView (screen 1), inverted into the
// near-black register. It is NOT a new top-level window - ExpandedPanelView
// hosts it INSIDE the existing 480x360 panel, swapping it in for the compact
// PlanView when the user asks for detail (and back). That keeps the surface one
// panel, not two windows.
//
// Layout per STITCH_SPEC screen 2:
//   - a small "Plan Detail" overline, a large bold objective heading, and an
//     "Awaiting approval" / "Running" / "Paused" StatusChip (dark register)
//     pinned to its right;
//   - the full ordered step timeline in a dark inset card (one step lighter
//     than the page: inkDeep on an ink page), each row a PlanStepRow in the
//     dark register;
//   - the active step EXPANDED to its done-criteria checklist + the boxed,
//     monospace evaluator-feedback - PlanStepRow already draws all three when
//     given `expanded: true, dark: true`, so this view is pure composition.
//
// Everything resolves to an existing token or primitive (StatusChip,
// PlanStepRow, StepStateIcon, BrandSectionHeader, the BrandColor/Spacing/Radius
// tokens). The only register-specific values are the dark surface fills, which
// the spec names (ink page, inkDeep inset, low-opacity paper dividers) - no new
// visual constants. A quiet "Back" affordance returns to the compact view.

import SwiftUI
import SupervisorCore

public struct PlanDetailView: View {

    private let plan: Plan
    /// Mirrors PlanView: a global pause flips the StatusChip to "Paused"
    /// without a plan-state change.
    private let isPaused: Bool
    /// Return to the compact (light) Plan view. Hosted by ExpandedPanelView.
    private let onBack: () -> Void

    /// Whether the full-objective disclosure is open. The compact PlanView shows
    /// only the distilled title; the full original objective (e.g. a routine's
    /// raw opening prompt) lives here, collapsed by default so the timeline
    /// leads, expandable when the operator wants the verbatim text.
    @State private var fullObjectiveExpanded = false

    public init(
        plan: Plan,
        isPaused: Bool,
        onBack: @escaping () -> Void
    ) {
        self.plan = plan
        self.isPaused = isPaused
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.lg) {
            backRow
            objectiveHeader
            timelineCard
            fullObjectiveSection
        }
        .padding(BrandSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandColor.ink.color)
    }

    // MARK: - Back affordance (exit the dark detail register)

    /// The quiet way out: a chevron + "Back" in the paper-on-dark muted tone,
    /// the dark-register sibling of a light secondary action. Tapping it returns
    /// the panel to the compact light Plan view.
    private var backRow: some View {
        Button(action: onBack) {
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back")
                    .font(BrandFont.note)
            }
            .foregroundStyle(BrandColor.paper.color.opacity(0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Objective header (overline + heading + status chip, dark)

    private var objectiveHeader: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            // The overline is the same BrandSectionHeader treatment; on the dark
            // page its muted ink reads as a quiet paper grey via the token.
            BrandSectionHeader("Plan Detail")
            HStack(alignment: .top, spacing: BrandSpacing.sm) {
                // The same calm, distilled heading as the compact PlanView, so
                // a routine's raw opening prompt is not dumped here either. The
                // verbatim objective lives in the "Routine prompt" disclosure
                // below; this stays an at-most-3-line title.
                Text(PlanView.displayTitle(for: plan.objective))
                    .font(BrandFont.title)
                    .foregroundStyle(BrandColor.paper.color)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BrandSpacing.sm)
                if isPaused {
                    StatusChip(.paused, dark: true)
                } else {
                    StatusChip(planStatus: plan.status, dark: true)
                }
            }
        }
    }

    // MARK: - Step timeline (the full ordered list; active step expanded)

    /// The dark inset card: one step lighter than the page (inkDeep on ink),
    /// hairline-ruled with a low-opacity paper border, holding the step rows.
    /// Each divider is a low-opacity paper rule (the dark-register divider the
    /// spec names). The active/retrying step expands to its done-criteria +
    /// boxed evaluator-feedback; PlanStepRow renders that when `expanded`.
    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { offset, step in
                if offset > 0 {
                    Divider()
                        .overlay(BrandColor.paper.color.opacity(0.12))
                        .padding(.vertical, BrandSpacing.xxs)
                }
                PlanStepRow(step, expanded: isExpandedStep(step), dark: true)
            }
        }
        .padding(BrandSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.inkDeep.color)
        .clipShape(RoundedRectangle(cornerRadius: BrandRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.card)
                .strokeBorder(
                    BrandColor.paper.color.opacity(0.12),
                    lineWidth: BrandMetrics.hairline
                )
        )
    }

    // MARK: - Full objective (the verbatim original, quiet disclosure)

    /// The full, original objective text in a quiet collapsible section. For a
    /// routine / scheduled-task run this is the raw opening prompt the compact
    /// title distilled away; the detail view is where that verbatim text lives.
    /// Collapsed by default so the timeline leads; when opened it renders the
    /// text in mono inside a dark inset card, scrollable when long. We only show
    /// the section when the full text adds something beyond the shown title.
    @ViewBuilder
    private var fullObjectiveSection: some View {
        let full = plan.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if showFullObjective {
            VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                Button {
                    withAnimation(BrandMotion.standard) { fullObjectiveExpanded.toggle() }
                } label: {
                    HStack(spacing: BrandSpacing.xs) {
                        // "Routine prompt" when the objective is a scheduled-task
                        // wrapper, else the generic "Full objective".
                        BrandSectionHeader(fullObjectiveLabel)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BrandColor.paper.color.opacity(0.5))
                            .rotationEffect(.degrees(fullObjectiveExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if fullObjectiveExpanded {
                    // The same dark inset card as the timeline (inkDeep on ink,
                    // low-opacity paper hairline), holding the verbatim text in
                    // mono. Capped height with an internal ScrollView so a long
                    // routine prompt scrolls HERE rather than growing the panel.
                    ScrollView {
                        Text(full)
                            .font(BrandFont.monoSmall)
                            .foregroundStyle(BrandColor.paper.color.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(BrandSpacing.md)
                    }
                    .frame(maxHeight: 140)
                    .background(BrandColor.inkDeep.color)
                    .clipShape(RoundedRectangle(cornerRadius: BrandRadius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandRadius.card)
                            .strokeBorder(
                                BrandColor.paper.color.opacity(0.12),
                                lineWidth: BrandMetrics.hairline
                            )
                    )
                }
            }
        }
    }

    /// Whether the full-objective disclosure is worth showing: only when the
    /// verbatim objective carries more than the distilled title already conveys
    /// (a routine wrapper, or a long objective). A short plain objective that
    /// equals its own title adds nothing, so we hide the section then.
    private var showFullObjective: Bool {
        let full = plan.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return false }
        return full != PlanView.displayTitle(for: full)
    }

    /// "Routine prompt" when the objective is a scheduled-task / routine
    /// wrapper, else "Full objective".
    private var fullObjectiveLabel: String {
        plan.objective.contains("<scheduled-task") ? "Routine prompt" : "Full objective"
    }

    /// In the DETAIL view, EVERY step is expanded: non-pending steps show their
    /// metadata (attempts, score, timestamps), verdict, and criteria checklist;
    /// pending steps show their objective and done-criteria so the user can see
    /// the full rubric ahead of time. This is what makes the detail view
    /// genuinely richer than the compact plan view (which only expands the
    /// active step).
    private func isExpandedStep(_ step: PlanStep) -> Bool {
        true
    }
}
