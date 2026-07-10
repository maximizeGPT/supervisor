// SeverityBadge.swift
//
// The small severity chip shown next to a flag (LOW / MEDIUM / HIGH). This
// primitive owns the one canonical severity -> color mapping for the app so
// the rule lives in exactly one place. Today ExpandedPanelView spells the
// same mapping out inline; M3 deletes that local copy and adopts this.
//
// v0.2.0 M3 (Stitch reconciliation, STITCH_SPEC section 3c): the badge moves
// from a saturated platform fill with a paper label to a calm tinted fill
// with a darker on-tone label and a leading glyph. The canonical attention
// tone is now `BrandColor.attention` (the one desaturated amber), shared with
// the failed plan-step icon and a failed evaluator verdict — severity hues
// stay encapsulated here, but the amber is a real brand token so those three
// surfaces match. Low severity stays a quiet grey (an "optimization
// suggestion", not a warning). No system `.orange` / `.yellow` / `.red`.

import SwiftUI
import SupervisorCore

public struct SeverityBadge: View {

    private let severity: FlagSeverity

    public init(_ severity: FlagSeverity) {
        self.severity = severity
    }

    public var body: some View {
        HStack(spacing: BrandSpacing.xxs) {
            Image(systemName: Self.glyph(for: severity))
                .font(.system(size: 9, weight: .semibold))
            Text(severity.rawValue.uppercased())
                .font(BrandFont.caption)
                .tracking(0.4)
        }
        .foregroundStyle(Self.color(for: severity))
        .padding(.horizontal, BrandSpacing.xs)
        .padding(.vertical, BrandSpacing.xxs)
        .background(
            Self.color(for: severity).opacity(0.14),
            in: RoundedRectangle(cornerRadius: BrandRadius.small)
        )
    }

    /// The single source of truth for severity -> on-tone label/glyph color.
    /// Exposed as a static so non-badge surfaces (a row tint, a left rule)
    /// reuse the exact same mapping. The fill is this color at a low opacity
    /// (see `body`); the label and leading glyph are the solid tone.
    ///
    /// Medium and high both resolve to the one amber attention tone (a flag
    /// that needs a look); low is a quiet grey (a suggestion). This is the
    /// calm, desaturated reconciliation the Stitch brief specifies — not the
    /// old yellow / orange / red alarm ladder.
    public static func color(for severity: FlagSeverity) -> Color {
        switch severity {
        case .low:            return BrandColor.mute.color
        case .medium, .high:  return BrandColor.attention.color
        }
    }

    /// The leading SF Symbol for a severity. Medium/high warn with a triangle;
    /// low informs with an info circle, matching the brief's glyphs.
    public static func glyph(for severity: FlagSeverity) -> String {
        switch severity {
        case .low:            return "info.circle"
        case .medium, .high:  return "exclamationmark.triangle"
        }
    }
}
