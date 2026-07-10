// StepStateIcon.swift — v0.2.0 M3.
//
// The leading glyph that encodes a plan step's state — the single most
// important visual from the Stitch pass, the thing that makes a plan legible
// at a glance. One primitive owns the state -> glyph mapping so every plan
// surface (the compact Screen 1 list, the dark Screen 2 timeline) reads the
// same.
//
// State -> treatment (per STITCH_SPEC section 3a), built only from tokens:
//   passed   -> solid signal-green filled circle with a white check
//   active   -> signal-green hollow ring with a small solid signal core,
//               pulsing on BrandMotion.pulse (a PulseDot)
//   pending  -> solid mute-grey filled circle, no glyph
//   skipped  -> hollow mute-grey ring (bypassed, not done, not pending)
//   failed   -> amber (attention) filled circle with a white "!"
//   retrying -> amber hollow ring with a pulsing amber core (active, amber:
//               "being re-attempted, needs a look")
//
// The icon footprint is fixed (`iconMedium`, 16pt) so the step number and
// title always align down the column regardless of which glyph shows.

import SwiftUI
import SupervisorCore

public struct StepStateIcon: View {

    private let status: PlanStep.Status
    private let dark: Bool

    /// - Parameters:
    ///   - status: the step's lifecycle state.
    ///   - dark: the Screen 2 dark register. Affects only the check/"!"
    ///     glyph contrast (always drawn light), not the state colors.
    public init(_ status: PlanStep.Status, dark: Bool = false) {
        self.status = status
        self.dark = dark
    }

    private var size: CGFloat { BrandMetrics.iconMedium }

    public var body: some View {
        ZStack {
            content
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .passed:
            filledCircle(BrandColor.signal.color, glyph: "checkmark")
        case .active:
            // A pulsing live core. The PulseDot's halo gives the "ring"
            // read; sized to sit inside the icon column.
            PulseDot(core: BrandMetrics.statusDot, halo: size)
        case .pending:
            Circle()
                .fill(BrandColor.mute.color.opacity(dark ? 0.55 : 0.45))
                .frame(width: BrandMetrics.iconSmall, height: BrandMetrics.iconSmall)
        case .skipped:
            ring(BrandColor.mute.color)
        case .failed:
            filledCircle(BrandColor.attention.color, glyph: "exclamationmark")
        case .retrying:
            // Active, but amber: a pulsing attention core.
            PulseDot(tint: BrandColor.attention.color,
                     core: BrandMetrics.statusDot, halo: size)
        }
    }

    /// A solid filled circle with a centered light glyph (check / "!").
    private func filledCircle(_ fill: Color, glyph: String) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(BrandColor.paper.color)
        }
    }

    /// A hollow hairline ring (skipped / bypassed).
    private func ring(_ stroke: Color) -> some View {
        Circle()
            .strokeBorder(stroke.opacity(0.5), lineWidth: BrandMetrics.hairline)
            .frame(width: BrandMetrics.iconSmall, height: BrandMetrics.iconSmall)
    }
}
