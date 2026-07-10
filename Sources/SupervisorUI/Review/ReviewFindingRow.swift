// ReviewFindingRow.swift — v0.3.x REVIEW dimension.
//
// One code-review observation, as a calm expandable card. The FINDING (a plain
// sentence) is the star — it reads first, in ink; the file and a small
// severity·confidence assessment are quiet metadata; expanding reveals the WHY
// and, when present, the exact changed line as a mono code sliver.
//
// Register: reviews are INFORMATIONAL, not alarms. So this stays in the calm
// instrument-panel vocabulary — warm-paper card, hairline rule, one small
// desaturated severity dot (never the amber safety SeverityBadge, never green).
// A review is a knowledgeable colleague's sticky note, not a siren.

import SwiftUI
import SupervisorCore

public struct ReviewFindingRow: View {

    private let finding: StoredReviewFinding
    @State private var expanded = false

    public init(_ finding: StoredReviewFinding) {
        self.finding = finding
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            // Header: the review mark, the finding sentence, time + a disclosure.
            HStack(alignment: .top, spacing: BrandSpacing.sm) {
                reviewMark
                VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
                    Text(finding.title)
                        .font(BrandFont.note)
                        .foregroundStyle(BrandColor.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(expanded ? nil : 2)
                    assessmentLine
                }
                Spacer(minLength: BrandSpacing.xs)
                VStack(alignment: .trailing, spacing: BrandSpacing.xxs) {
                    Text(Self.relativeTime(finding.createdAt))
                        .font(BrandFont.monoSmall)
                        .foregroundStyle(BrandColor.mute.color)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(BrandColor.mute.color)
                }
            }

            if expanded {
                detail.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(BrandSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColor.paperWarm.color,
            in: RoundedRectangle(cornerRadius: BrandRadius.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.control)
                .strokeBorder(BrandColor.mute.color.opacity(0.15), lineWidth: BrandMetrics.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(BrandMotion.standard) { expanded.toggle() } }
    }

    // MARK: - The review mark (calm identity, not an alarm badge)

    private var reviewMark: some View {
        Image(systemName: "eye")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BrandColor.mute.color)
            .frame(width: BrandMetrics.iconMedium, height: BrandMetrics.iconMedium)
            .background(BrandColor.mute.color.opacity(0.10), in: Circle())
            .padding(.top, 1)
    }

    // MARK: - Assessment line (file · severity · confidence · category)

    private var assessmentLine: some View {
        HStack(spacing: BrandSpacing.xs) {
            severityDot
            Text(fileName)
                .font(BrandFont.monoSmall)
                .foregroundStyle(BrandColor.mute.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
                .font(BrandFont.monoSmall)
                .foregroundStyle(BrandColor.mute.color.opacity(0.6))
            Text(Self.categoryPhrase(finding.category))
                .font(BrandFont.monoSmall)
                .foregroundStyle(BrandColor.mute.color)
                .lineLimit(1)
        }
    }

    /// A small severity dot. Defers to the canon (SeverityBadge.color) so it can
    /// NEVER drift from the severity vocabulary the flag rows use — low → mute,
    /// medium/high → the calm attention ochre. One source of truth, no invented tones.
    private var severityDot: some View {
        Circle()
            .fill(SeverityBadge.color(for: finding.severity))
            .frame(width: 6, height: 6)
    }

    // MARK: - Expanded detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            if !finding.detail.isEmpty {
                Text(finding.detail)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let hint = finding.lineHint, !hint.isEmpty {
                Text(hint)
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.inkDeep.color)
                    .padding(BrandSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BrandColor.paper.color, in: RoundedRectangle(cornerRadius: BrandRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandRadius.small)
                            .strokeBorder(BrandColor.mute.color.opacity(0.12), lineWidth: BrandMetrics.hairline)
                    )
                    .textSelection(.enabled)
            }
            HStack(spacing: BrandSpacing.xs) {
                Text("\(finding.severity.rawValue) severity")
                Text("·")
                Text("\(finding.confidence) confidence")
                Spacer()
                Text(finding.filePath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            .font(BrandFont.caption)
            .tracking(0.2)
            .foregroundStyle(BrandColor.mute.color)
        }
        .padding(.leading, BrandMetrics.iconMedium + BrandSpacing.sm)
    }

    // MARK: - Helpers

    private var fileName: String {
        (finding.filePath as NSString).lastPathComponent
    }

    static func categoryPhrase(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
