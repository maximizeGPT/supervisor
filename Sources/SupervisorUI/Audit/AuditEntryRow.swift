// AuditEntryRow.swift - v0.2.0 observability (Reddit feedback D).
//
// One skimmable "receipt" row for a single audit entry: a small badge naming
// what kind of decision it was (auto-answer / block / nudge / plan step /
// verdict), the one-line summary, and the JUSTIFICATION for that kind in a
// compact, label-led form - the question + authorizing rule for an auto-answer,
// the command + path + risk reason for a block, the stall classification for a
// nudge, the score + feedback for a verdict. This is the "clean per-action log,
// not a raw trace" the Reddit thread asked for.
//
// Composition only, over the brand tokens + primitives: the row reads as a
// small BrandCard (warm-paper fill, hairline rule, control radius), same flat
// instrument-panel surface as the flag row and the plan-step card. Commands and
// paths render in BrandFont.mono so a `git reset --hard` reads as code, never as
// prose. No green (green stays the one primary action); the kind badge uses the
// calm mute/attention tones from the severity vocabulary.

import SwiftUI
import SupervisorCore

public struct AuditEntryRow: View {

    private let entry: StoredAuditEntry

    public init(_ entry: StoredAuditEntry) {
        self.entry = entry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            // Header: kind badge + summary + relative time.
            HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
                AuditKindBadge(entry.kind)
                Text(entry.summary)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BrandSpacing.xs)
                Text(Self.relativeTime(entry.createdAt))
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            }

            // Justification: the kind-specific "why", label-led so the row is
            // skimmable. Only the fields a given kind populated are shown.
            justification
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
    }

    // MARK: - Justification (the per-kind receipt body)

    @ViewBuilder
    private var justification: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
            switch entry.kind {
            case .autoAnswer:
                // The question it answered + the authorizing rule (the receipt
                // for "why was Supervisor allowed to answer this").
                if let q = entry.question, !q.isEmpty {
                    field("Question", q)
                }
                if let rule = entry.authorizingRule, !rule.isEmpty {
                    field("Authorized by", rule, mono: true)
                }
            case .block:
                // The destructive command + its target + the risk reason - the
                // canonical "receipt" the thread asked for.
                if let cmd = entry.command, !cmd.isEmpty {
                    field("Command", cmd, mono: true)
                }
                if let path = entry.targetPath, !path.isEmpty {
                    field("Target", path, mono: true)
                }
                if let risk = entry.riskReason, !risk.isEmpty {
                    field("Risk", risk)
                }
            case .nudge:
                // The stall failure-mode classification (PART B): why the
                // session looked stalled when Supervisor nudged it.
                if let cl = entry.classification, !cl.isEmpty {
                    field("Stall", Self.classificationLabel(cl))
                }
            case .verdict, .planStep:
                // The verdict's score + feedback live in `detail`/`summary`;
                // the summary already carries the headline, so surface any extra
                // free-form detail when present.
                if let d = entry.detail, !d.isEmpty {
                    field("Detail", d)
                }
            case .review:
                // A code-review observation: the file it touched, the assessment
                // (severity · confidence), and WHY it matters. `summary` carries
                // the one-line finding; these are the receipt.
                if let path = entry.targetPath, !path.isEmpty {
                    field("File", path, mono: true)
                }
                if let cl = entry.classification, !cl.isEmpty {
                    field("Assessment", cl)
                }
                if let why = entry.riskReason, !why.isEmpty {
                    field("Why", why)
                }
            }
        }
    }

    /// One label-led justification line: a small uppercased label and the value.
    /// `mono` renders the value in the mono font (commands, paths, rule refs).
    private func field(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
            Text(label.uppercased())
                .font(BrandFont.caption)
                .tracking(0.4)
                .foregroundStyle(BrandColor.mute.color)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(mono ? BrandFont.monoSmall : BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    /// Map the stored stall-classification raw value to its human phrase. The
    /// audit row stores the `StallClassification.rawValue`; reconstruct the enum
    /// to reuse its `humanReason`, falling back to the raw string if unknown.
    static func classificationLabel(_ raw: String) -> String {
        StallClassification(rawValue: raw)?.humanReason ?? raw
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

// MARK: - AuditKindBadge

/// The small chip naming an audit entry's kind, in the same tinted-chip
/// vocabulary as SeverityBadge / StatusChip: a leading glyph + a tracked
/// caption label on a low-opacity fill. A block is the one calm-amber "needs a
/// look" kind (it stopped something); the rest are quiet mute, matching the
/// "calm instrument panel, not an alarm console" register.
public struct AuditKindBadge: View {

    private let kind: AuditEntryKind

    public init(_ kind: AuditEntryKind) {
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: BrandSpacing.xxs) {
            Image(systemName: Self.glyph(for: kind))
                .font(.system(size: 9, weight: .semibold))
            Text(Self.label(for: kind))
                .font(BrandFont.caption)
                .tracking(0.4)
        }
        .foregroundStyle(Self.tone(for: kind))
        .padding(.horizontal, BrandSpacing.xs)
        .padding(.vertical, BrandSpacing.xxs)
        .background(
            Self.tone(for: kind).opacity(0.14),
            in: RoundedRectangle(cornerRadius: BrandRadius.small)
        )
        .fixedSize()
    }

    /// The short label for each kind (sentence-cased reading, but uppercased by
    /// the badge type treatment).
    static func label(for kind: AuditEntryKind) -> String {
        switch kind {
        case .autoAnswer: return "Auto-answer"
        case .block:      return "Block"
        case .nudge:      return "Nudge"
        case .planStep:   return "Plan step"
        case .verdict:    return "Verdict"
        case .review:     return "Review"
        }
    }

    /// The leading glyph. A block warns (it stopped a destructive action); the
    /// rest carry quiet, descriptive glyphs.
    static func glyph(for kind: AuditEntryKind) -> String {
        switch kind {
        case .autoAnswer: return "text.bubble"
        case .block:      return "hand.raised"
        case .nudge:      return "arrow.right.circle"
        case .planStep:   return "list.bullet"
        case .verdict:    return "checkmark.seal"
        case .review:     return "eye"
        }
    }

    /// The on-tone color. Block is the one amber attention kind; the rest are
    /// the quiet mute tone (no green - that stays the one primary action).
    static func tone(for kind: AuditEntryKind) -> Color {
        switch kind {
        case .block: return BrandColor.attention.color
        default:     return BrandColor.mute.color
        }
    }
}
