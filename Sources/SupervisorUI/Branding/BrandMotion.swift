// BrandMotion.swift
//
// Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
//
// Standard animations for SupervisorUI. impeccable's motion rule is restraint:
// a small set of consistent, quiet transitions, no springy or attention-
// grabbing effects on a calm instrument panel. Three named animations cover
// nearly everything; reach past them only for a deliberate, documented case.
//
// Use `standard` for content appearing / reflowing, and `expressive` only for
// the one moment that should draw the eye (the live pulse, a fresh flag
// landing). Durations are short on purpose: motion confirms a change, it does
// not perform.

import SwiftUI

public enum BrandMotion {
    /// 0.22s ease-in-out. Content appearing, reflowing, or crossfading
    /// (a row inserting, a panel's contents updating).
    public static let standard: Animation = .easeInOut(duration: 0.22)

    /// 0.35s ease-in-out. The one expressive beat: a status change worth
    /// noticing (a flag landing, a step turning active). Still calm; just
    /// slower so the eye catches it.
    public static let expressive: Animation = .easeInOut(duration: 0.35)

    /// Continuous pulse for live / active indicators (the Driving dot, the
    /// active plan step). A slow, even breath that repeats and autoreverses
    /// so "live" reads as steady, not flashing.
    public static let pulse: Animation =
        .easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    // MARK: - Concentric pulse halo (v0.2.0 M3)
    //
    // The Stitch brief's live dot is a solid signal core inside a pale,
    // low-opacity halo ring (`BrandMetrics.pulseHalo` wide) that breathes
    // on the `pulse` curve. These two constants pin the halo's opacity
    // breath so the `PulseDot` primitive (and any future live indicator)
    // animates the same way: the halo eases between `haloOpacityMin` and
    // `haloOpacityMax` while the core holds steady. Kept here, beside the
    // `pulse` curve, so the whole live-indicator treatment lives in one
    // place rather than scattered as call-site literals.

    /// The halo ring's resting (dimmest) opacity in the pulse breath.
    public static let haloOpacityMin: Double = 0.12

    /// The halo ring's peak (brightest) opacity in the pulse breath.
    public static let haloOpacityMax: Double = 0.32
}
