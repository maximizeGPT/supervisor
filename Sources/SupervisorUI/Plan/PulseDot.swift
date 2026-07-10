// PulseDot.swift — v0.2.0 M3.
//
// The live "pulse" indicator from the Stitch brief: a solid core dot inside
// a pale, low-opacity concentric halo ring that breathes on the calm
// `BrandMotion.pulse` curve. One primitive so every live indicator (the
// status row's "Running" dot on Screen 1, the active plan step's core in
// StepStateIcon) reads identically and uses the same tokens.
//
// Geometry and motion come entirely from tokens: the core is `statusDot`
// (8pt), the halo is `pulseHalo` (18pt), the halo opacity eases between
// `BrandMotion.haloOpacityMin` and `.haloOpacityMax`. The tint defaults to
// signal green (live/active); the amber attention tone can be passed for a
// "needs a look" pulse (a retrying step) without inventing a second curve.
//
// Restraint per DESIGN.md: a steady breath, not a flash. No spring, no scale
// pop — just the halo's opacity easing back and forth.

import SwiftUI

public struct PulseDot: View {

    private let tint: Color
    private let core: CGFloat
    private let halo: CGFloat

    @State private var breathing = false

    /// - Parameters:
    ///   - tint: the dot color; defaults to `signal` (live/active). Pass
    ///     `BrandColor.attention.color` for an attention pulse.
    ///   - core: core diameter; defaults to `BrandMetrics.statusDot` (8pt).
    ///   - halo: halo diameter; defaults to `BrandMetrics.pulseHalo` (18pt).
    public init(
        tint: Color = BrandColor.signal.color,
        core: CGFloat = BrandMetrics.statusDot,
        halo: CGFloat = BrandMetrics.pulseHalo
    ) {
        self.tint = tint
        self.core = core
        self.halo = halo
    }

    public var body: some View {
        ZStack {
            // The breathing concentric halo.
            Circle()
                .fill(tint)
                .frame(width: halo, height: halo)
                .opacity(breathing ? BrandMotion.haloOpacityMax : BrandMotion.haloOpacityMin)
                .scaleEffect(breathing ? 1.0 : 0.82)
            // The steady solid core.
            Circle()
                .fill(tint)
                .frame(width: core, height: core)
        }
        // Fixed footprint so the halo never nudges siblings as it breathes.
        .frame(width: halo, height: halo)
        .onAppear {
            withAnimation(BrandMotion.pulse) { breathing = true }
        }
        .onDisappear {
            // Stop the `.repeatForever` breath when the indicator leaves the
            // view hierarchy (e.g. the expanded panel is hidden, or a step is no
            // longer active) so a hidden surface isn't animating forever (RC
            // fix #7). Cleared without an animation so no work is scheduled.
            breathing = false
        }
    }
}
