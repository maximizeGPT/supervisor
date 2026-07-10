// BrandSecondaryButton.swift
//
// The quiet secondary action, paired with BrandPrimaryButton. Same shape and
// metrics as the primary, but no fill: ink label on a hairline-bordered
// surface, so it reads as available-but-deemphasized next to the one green
// primary. This is the one-accent discipline in component form: only the
// primary carries the brand green; the secondary stays neutral.
//
// Mirrors BrandPrimaryButton exactly (same padding, same disabled fade via
// `\.isEnabled`, same `.buttonStyle(.plain)`), so a primary + secondary pair
// aligns on one baseline. NOT yet used by any screen; M3 adopts it (the
// "Approve plan" / "Pause" footer pair in the Stitch brief).

import SwiftUI

public struct BrandSecondaryButton: View {

    @Environment(\.isEnabled) private var isEnabled

    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.button)
                .foregroundStyle(BrandColor.ink.color.opacity(isEnabled ? 1.0 : 0.4))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(BrandColor.paperWarm.color.opacity(isEnabled ? 1.0 : 0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: BrandRadius.small)
                        .strokeBorder(
                            BrandColor.mute.color.opacity(isEnabled ? 0.35 : 0.15),
                            lineWidth: BrandMetrics.hairline
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: BrandRadius.small))
        }
        .buttonStyle(.plain)
    }
}
