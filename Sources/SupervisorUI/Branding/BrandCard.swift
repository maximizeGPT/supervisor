// BrandCard.swift
//
// A consistent container surface: the standard way to group content into a
// bounded region (a flag row, a plan-step block, the panel's sections). One
// card treatment everywhere means nested groups read as a deliberate system,
// not a pile of differently-styled boxes.
//
// Geometry comes entirely from the tokens: BrandSpacing for the inner pad,
// BrandRadius.card for the corner, BrandMetrics.hairline for the border. The
// surface is a quiet warm-paper fill with a hairline rule (no shadow, no
// gradient: a flat instrument panel). Wraps arbitrary content via a closure,
// the standard SwiftUI container pattern.
//
// Baseline values; reconcile with Mohammed's Stitch direction in M1b/M3.
// NOT yet used by any screen; M3 adopts it.

import SwiftUI

public struct BrandCard<Content: View>: View {

    private let padding: CGFloat
    private let content: Content

    /// - Parameter padding: inner inset; defaults to `BrandSpacing.md`
    ///   (12pt). Pass another step from the scale for denser / roomier cards.
    public init(
        padding: CGFloat = BrandSpacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(BrandColor.paperWarm.color)
            .clipShape(RoundedRectangle(cornerRadius: BrandRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: BrandRadius.card)
                    .strokeBorder(
                        BrandColor.mute.color.opacity(0.2),
                        lineWidth: BrandMetrics.hairline
                    )
            )
    }
}
