// BrandSpacing.swift
//
// Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
//
// The intentional spatial scale for SupervisorUI. impeccable's first rule is
// a real spatial system: spacing is chosen from a named scale, never typed as
// a raw literal at the call site. Every gap, pad, and inset in a brand surface
// resolves to one of these steps so rhythm stays consistent and deliberate.
//
// The scale is a 4pt grid (with a 2pt half-step for hairline-tight cases).
// Steps grow non-linearly toward the top so large gaps read as intentional
// structure, not accumulated padding. Use the smallest step that reads.
//
// Adding a value: only if a real surface needs a gap the scale can't express.
// Prefer composing existing steps over inventing one-off numbers.

import CoreGraphics

public enum BrandSpacing {
    /// 2pt. Hairline-tight: icon-to-label kerning, badge inner padding.
    public static let xxs: CGFloat = 2
    /// 4pt. Tight: related inline items, dense list-row gaps.
    public static let xs: CGFloat = 4
    /// 8pt. Default small gap: label stacks, control-to-control.
    public static let sm: CGFloat = 8
    /// 12pt. Comfortable: rows within a section, card inner padding.
    public static let md: CGFloat = 12
    /// 16pt. Section inset: a card's outer padding, content margins.
    public static let lg: CGFloat = 16
    /// 24pt. Between sections: separates distinct groups in a panel.
    public static let xl: CGFloat = 24
    /// 32pt. Major break: top-level scene margins, hero spacing.
    public static let xxl: CGFloat = 32
}
