// BrandRadius.swift
//
// Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
//
// The corner-radius scale for SupervisorUI. A small, restrained set: a quiet
// instrument panel keeps corners tight and consistent, never mixing many
// arbitrary radii. Three steps cover badges, controls, and cards. Pick the
// step by the element's size, not by feel, so nested shapes stay concentric.
//
// (The existing BrandPrimaryButton uses a 5pt corner inline; that is its own
// deliberate control radius and is left untouched in M1a. M3 may align it to
// `control` when the buttons are revisited against Stitch.)

import CoreGraphics

public enum BrandRadius {
    /// 4pt. Small chips and severity badges.
    public static let small: CGFloat = 4
    /// 8pt. Standard controls and inset rows.
    public static let control: CGFloat = 8
    /// 12pt. Cards and larger container surfaces.
    public static let card: CGFloat = 12
}
