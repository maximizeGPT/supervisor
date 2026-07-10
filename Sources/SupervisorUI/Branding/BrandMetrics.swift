// BrandMetrics.swift
//
// Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
//
// Shared fixed sizes for SupervisorUI: the dimensions that recur across
// surfaces and should match exactly wherever they appear (a hairline is one
// width everywhere; an inline status icon is one size everywhere). Keeping
// them here stops each view from picking its own slightly-different number.
//
// Spacing and corner radii live in BrandSpacing / BrandRadius; this file is
// for the remaining "how big / how thick" constants only.

import CoreGraphics

public enum BrandMetrics {
    /// 1pt. Hairline border / divider width. The quiet 1px rule that
    /// separates surfaces without a heavy stroke.
    public static let hairline: CGFloat = 1

    /// 12pt. Inline status / severity icon (sits with caption + body text).
    public static let iconSmall: CGFloat = 12

    /// 16pt. Standard affordance icon (section actions, list rows).
    public static let iconMedium: CGFloat = 16

    /// 24pt. Emphasis icon (status header, empty states).
    public static let iconLarge: CGFloat = 24

    /// 8pt. The live "pulse" status dot (Driving / active step indicator).
    public static let statusDot: CGFloat = 8

    /// 18pt. The pale concentric halo ring drawn around the `statusDot`
    /// core for the live "pulse" look the Stitch brief specifies (a green
    /// core inside a low-opacity green halo, ~2x the core). Added in
    /// v0.2.0 M3. Pair with `BrandMotion.pulse` so the halo breathes.
    public static let pulseHalo: CGFloat = 18
}
