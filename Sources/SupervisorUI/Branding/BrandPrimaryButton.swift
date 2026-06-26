// BrandPrimaryButton.swift
//
// The single primary-button shape in onboarding (and any future brand
// surface). Signal-green background, Paper text, Inter 500. Dims to 40%
// when the button is disabled — `Button.buttonStyle(.plain)` defeats
// macOS's automatic disabled rendering, so we read `\.isEnabled` and
// fade the background ourselves.
//
// `.keyboardShortcut(...)` and `.disabled(...)` applied at the call site
// propagate through to the inner Button via standard SwiftUI environment
// propagation.

import SwiftUI

public struct BrandPrimaryButton: View {

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
                .foregroundStyle(BrandColor.paper.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(BrandColor.signal.color.opacity(isEnabled ? 1.0 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
