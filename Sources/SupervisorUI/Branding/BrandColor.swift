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
    case mute        // #A6A6A2 — secondary text, deemphasis

    public var color: Color {
        switch self {
        case .ink:       return Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)
        case .paper:     return Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF2 / 255)
        case .inkDeep:   return Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x1E / 255)
        case .paperWarm: return Color(red: 0xED / 255, green: 0xED / 255, blue: 0xEB / 255)
        case .signal:    return Color(red: 0x2D / 255, green: 0x7A / 255, blue: 0x4E / 255)
        case .mute:      return Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xA2 / 255)
        }
    }
}
