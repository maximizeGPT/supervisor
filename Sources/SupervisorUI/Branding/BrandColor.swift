// BrandColor.swift
//
// Brand palette tokens. Every brand color usage in SupervisorUI goes through
// this enum — call sites never spell out hex. The hex values mirror
// `branding/README.md`'s palette table and are the single source of truth
// for SwiftUI views.
//
// Adding a new token: extend the enum case, add the hex in `color`. Future
// surfaces (expanded panel v0.1.7+) reuse the same enum.

import SwiftUI

public enum BrandColor: String, Sendable, CaseIterable {
    case ink         // #0E0F11 — primary text, wordmark fill
    case paper       // #F7F6F2 — primary background (light mode)
    case inkDeep     // #1A1B1E — body copy emphasis
    case paperWarm   // #EDEDEB — secondary surface, dividers
    case signal      // #2D7A4E — brand green; the only accent in onboarding
    case mute        // #6E6E68 — secondary text, deemphasis (darkened
                     // from #A6A6A2 in v0.1.6.4: original tone was ~2.5:1
                     // contrast on paper background, WCAG-AA fail; the
                     // "Skip is fine…" body note and the "Skip" button
                     // label both used this token and were nearly
                     // invisible. New tone is ~5.3:1, AA-compliant for
                     // body copy. Still reads as deemphasized because
                     // ink is far darker (#0E0F11) and the tracking+
                     // uppercase on "STEP N OF 3" still carries its
                     // weight without needing extra-light gray.
    case attention   // #B8772A — the ONE calm amber attention tone, added
                     // in v0.2.0 M3 to reconcile the Stitch brief's
                     // failed/attention states. NOT a second accent: signal
                     // green still owns live/active/success and the one
                     // primary action. Amber marks only "needs a look": a
                     // medium-severity flag, a failed plan step, a failed
                     // evaluator verdict. It is intentionally desaturated
                     // (a warm ochre, not a system `.orange`) so the panel
                     // never reads as an alarm console. Used as a solid
                     // label/glyph tone and, at a low opacity, as a tint
                     // fill (see SeverityBadge / StepStateIcon). The exact
                     // hex is the brief's calm-amber target tuned to sit
                     // beside ink/mute/paper without shouting.

    public var color: Color {
        switch self {
        case .ink:       return Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)
        case .paper:     return Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF2 / 255)
        case .inkDeep:   return Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x1E / 255)
        case .paperWarm: return Color(red: 0xED / 255, green: 0xED / 255, blue: 0xEB / 255)
        case .signal:    return Color(red: 0x2D / 255, green: 0x7A / 255, blue: 0x4E / 255)
        case .mute:      return Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x68 / 255)
        case .attention: return Color(red: 0xB8 / 255, green: 0x77 / 255, blue: 0x2A / 255)
        }
    }
}
