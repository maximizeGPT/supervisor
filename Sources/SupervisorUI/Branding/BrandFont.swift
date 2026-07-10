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

    // MARK: - v0.2.0 additions (M1a)
    //
    // Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
    //
    // The section-header / overline caption: small, all-caps, tracked at the
    // call site (`.tracking(0.6)` + `.textCase(.uppercase)`), the way the
    // existing `indicator` token is used. Paired with BrandColor.mute for the
    // quiet "PLAN" / "FLAGS" section labels in the panel.
    public static let caption   = Font.system(size: 11, weight: .medium)

    /// Monospace for code, status values, timestamps, and evidence IDs.
    /// The spec calls for JetBrains Mono; until it is bundled (see the font
    /// switch note below) this is SF Mono via `.system(.monospaced)`, which
    /// already gives tabular, fixed-width digits for status readouts.
    public static let mono      = Font.system(size: 12, weight: .regular)
        .monospaced()

    /// Small monospace for dense inline values (elapsed time in the status
    /// row, short metric chips).
    public static let monoSmall = Font.system(size: 11, weight: .regular)
        .monospaced()

    // MARK: - Font switch point (deferred to post-Stitch)
    //
    // The brand spec is Inter (UI + body, 400/500/600) and JetBrains Mono
    // (code + timestamps). Neither ships as a runtime resource in this
    // version; the wordmark SVG outlines Inter to paths so the app has no
    // font dependency today, and the tokens above fall back to SF Pro /
    // SF Mono via `.system(...)`.
    //
    // TODO(M1b/M3, post-Stitch): if a future PR bundles Inter + JetBrains
    // Mono under `branding/` as runtime resources, register them and flip
    // every token in THIS FILE to the bundled families. Do NOT download or
    // bundle font binaries in M1a (storage-lean; values not yet reconciled
    // with Stitch). Call sites stay on `BrandFont.title` / `.mono` / etc.,
    // so the swap is local to this file.
}
