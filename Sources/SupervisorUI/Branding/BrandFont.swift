// BrandFont.swift
//
// Brand type tokens. The spec calls for Inter 400/500/600 (UI + body) and
// JetBrains Mono (code + timestamps). Neither font ships in `/branding`
// as a runtime resource in this version — the wordmark SVG has Inter
// outlined to paths so it doesn't need a runtime font dependency, and
// everything else falls back to SF Pro via `.system(...)`.
//
// If a future PR bundles Inter / JetBrains Mono as resources, the switch
// happens entirely in this file — call sites stay on `BrandFont.title`,
// `BrandFont.body`, etc.

import SwiftUI

public enum BrandFont {
    /// "STEP X OF 3" indicator — Inter 500 12pt all-caps (`.tracking(1)`
    /// + `.textCase(.uppercase)` applied at the call site).
    public static let indicator = Font.system(size: 12, weight: .medium)

    /// Step title — Inter 600 18pt.
    public static let title     = Font.system(size: 18, weight: .semibold)

    /// Body copy — Inter 400 13pt; pair with `.lineSpacing(6)` to
    /// approximate 1.5× line-height (13 × 1.5 = 19.5 ≈ 13 + 6.5).
    public static let body      = Font.system(size: 13, weight: .regular)

    /// Primary button label — Inter 500 13pt.
    public static let button    = Font.system(size: 13, weight: .medium)

    /// Small notes / secondary captions — Inter 400 11pt.
    public static let note      = Font.system(size: 11, weight: .regular)
}
