// BrandSectionHeader.swift
//
// The small all-caps section label that opens a group in a brand surface
// (the "PLAN" / "FLAGS" overlines in the control panel). One consistent
// treatment so every section in every surface reads the same: caption type,
// uppercased, tracked, muted ink.
//
// Pattern mirrors BrandPrimaryButton: a plain View primitive in Branding/
// that wraps the tokens. NOT yet adopted by any screen; M3 will swap the
// ad-hoc headers in ExpandedPanelView for this.

import SwiftUI

public struct BrandSectionHeader: View {

    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(BrandFont.caption)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(BrandColor.mute.color)
    }
}
