// PlanStepRow.swift — v0.2.0 M3.
//
// One row of the plan-step list: `[state icon] [n. Title]`, and when the step
// is active (or carries a verdict) a second line, indented to the title
// column, holding the Evaluator's verdict in monospace. This is the row the
// Stitch brief draws in both surfaces; one primitive renders both densities.
//
// Two variants per STITCH_SPEC section 3b:
//   - compact (Screen 1): icon + number + title, plus a one-line verdict
//     under the active step in `mono`. A passing verdict reads in signal
//     green (the active/working tone); a fail reads in the amber attention
//     tone, never alarm-red, to stay calm.
//   - expanded (Screen 2, `expanded: true`): the active row also lists its
//     done-criteria as a checklist above the verdict and boxes the verdict in
//     an inset one step lighter than the dark page (the dark plan-detail
//     register). Pending step text drops to `mute`.
//
// Title type is `body` (13pt) per the spec's panel-density note, not `title`
// (which is heavier than needed at this density). Everything resolves to a
// token; the icon column is fixed-width via StepStateIcon so titles align.

import SwiftUI
import SupervisorCore

public struct PlanStepRow: View {

    private let step: PlanStep
    private let expanded: Bool
    private let dark: Bool

    /// - Parameters:
    ///   - step: the plan step to render.
    ///   - expanded: Screen 2's roomy variant (done-criteria checklist +
    ///     boxed verdict). Defaults to the compact Screen 1 row.
    ///   - dark: the dark register (Screen 2). Switches text to paper and
    ///     boxes the verdict on a slightly-lighter inset.
    public init(_ step: PlanStep, expanded: Bool = false, dark: Bool = false) {
        self.step = step
        self.expanded = expanded
        self.dark = dark
    }

    private var isActive: Bool {
        step.status == .active || step.status == .retrying
    }

    public var body: some View {
        HStack(alignment: .top, spacing: BrandSpacing.sm) {
            StepStateIcon(step.status, dark: dark)
                // Nudge the icon onto the title's baseline row.
                .padding(.top, BrandSpacing.xxs)

            VStack(alignment: .leading, spacing: BrandSpacing.xs) {
                titleLine

                // Detail view: show the step objective (the fuller description
                // beyond the title) so the detail view is genuinely richer.
                if expanded && !step.objective.isEmpty && step.objective != step.title {
                    Text(step.objective)
                        .font(BrandFont.note)
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Detail view: show metadata row (attempts, timestamps) for
                // any step that has been touched (not pending/skipped).
                if expanded && hasMetadata {
                    metadataRow
                }

                // Screen 2 (detail): show the criteria checklist for ALL steps
                // so the user can see the full rubric ahead of time. In compact
                // mode, only the active step expands.
                if expanded && !step.doneCriteria.isEmpty {
                    criteriaChecklist
                }

                // The evaluator verdict line, when present. Active steps show
                // it inline; a graded (passed/failed) step keeps its last
                // verdict so the trace stays legible after it moves on.
                if let verdict = step.lastVerdict, shouldShowVerdict {
                    verdictLine(verdict)
                }
            }
        }
        .padding(.vertical, BrandSpacing.xs)
        .opacity(step.status == .skipped ? 0.55 : 1.0)
    }

    // MARK: - Title

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
            Text("\(step.index + 1).")
                .font(BrandFont.body)
                .foregroundStyle(numberColor)
            Text(step.title)
                .font(BrandFont.body)
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Metadata row (Screen 2 only: attempts, timestamps)

    /// Whether this step has metadata worth showing (not pending, not skipped).
    private var hasMetadata: Bool {
        step.status != .pending && step.status != .skipped
    }

    private var metadataRow: some View {
        HStack(spacing: BrandSpacing.sm) {
            if step.attempts > 0 {
                Text(step.attempts == 1 ? "1 attempt" : "\(step.attempts) attempts")
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(secondaryColor)
            }
            if let verdict = step.lastVerdict {
                Text("Score: \(String(format: "%.0f%%", verdict.score * 100))")
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(verdict.passed ? BrandColor.signal.color : BrandColor.attention.color)
            }
            Text(Self.relativeTime(step.updatedAt))
                .font(BrandFont.monoSmall)
                .foregroundStyle(secondaryColor)
        }
        .padding(.top, BrandSpacing.xxs)
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: - Done-criteria checklist (Screen 2)

    private var criteriaChecklist: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
            ForEach(Array(criteriaLines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
                    Image(systemName: "circle")
                        .font(.system(size: 6))
                        .foregroundStyle(secondaryColor.opacity(0.7))
                    Text(line)
                        .font(BrandFont.note)
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, BrandSpacing.xxs)
    }

    /// Split the rubric into lines for the checklist. The doneCriteria is a
    /// short free-text rubric; we render its newline- or sentence-delimited
    /// items. A single-line rubric renders as one checklist item.
    private var criteriaLines: [String] {
        let byNewline = step.doneCriteria
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return byNewline.isEmpty ? [step.doneCriteria] : byNewline
    }

    // MARK: - Verdict

    private var shouldShowVerdict: Bool {
        // Show on the active row always; on a settled row only in the
        // expanded (detail) variant, so the compact list stays a clean
        // one-verdict-at-the-active-step read.
        isActive || expanded
    }

    @ViewBuilder
    private func verdictLine(_ verdict: PlanStep.Verdict) -> some View {
        let tone = verdict.passed ? BrandColor.signal.color : BrandColor.attention.color
        if expanded {
            // Screen 2: a labeled, boxed feedback block on a lighter inset.
            VStack(alignment: .leading, spacing: BrandSpacing.xs) {
                Text("Evaluator feedback:")
                    .font(BrandFont.caption)
                    .tracking(0.3)
                    .foregroundStyle(secondaryColor)
                Text(verdict.feedback)
                    .font(BrandFont.mono)
                    .foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(BrandSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(feedbackBoxFill, in: RoundedRectangle(cornerRadius: BrandRadius.card))
            }
            .padding(.top, BrandSpacing.xs)
        } else {
            // Screen 1: a single green (or amber) monospace line.
            Text(verdict.feedback)
                .font(BrandFont.mono)
                .foregroundStyle(tone)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Register colors

    private var titleColor: Color {
        if step.status == .pending || step.status == .skipped {
            return dark ? BrandColor.paper.color.opacity(0.55) : BrandColor.mute.color
        }
        return dark ? BrandColor.paper.color : BrandColor.ink.color
    }

    private var numberColor: Color {
        dark ? BrandColor.paper.color.opacity(0.6) : BrandColor.mute.color
    }

    private var secondaryColor: Color {
        dark ? BrandColor.paper.color.opacity(0.6) : BrandColor.mute.color
    }

    // One step lighter than the dark page (inkDeep on an ink page); on light,
    // a warm-paper inset.
    private var feedbackBoxFill: Color {
        dark ? BrandColor.inkDeep.color : BrandColor.paperWarm.color
    }
}
