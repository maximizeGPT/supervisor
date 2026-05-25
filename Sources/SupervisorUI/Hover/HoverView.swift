// HoverView.swift
//
// 240x40 always-on-top hover band. Pulse dot, session label, current-tool
// line, flag-count badge. Wispr-Flow / Clicky visual reference: restrained
// chrome, one row of information.
//
// Click action in v0.1.0 just brings Supervisor to front; the expanded
// panel (with reasoning and actions) lands in v0.1.7.

import SwiftUI
import SupervisorCore

public struct HoverView: View {

    @ObservedObject var vm: HoverViewModel
    @State private var pulse: Bool = false

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 8) {
            // v0.1.4 Gap 5: dot + overlay-icon sit in a ZStack so the
            // overlay is anchored to the dot regardless of the row's
            // other content layout.
            ZStack {
                pulseDot
                if let icon = actionOverlayIcon {
                    Image(systemName: icon)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 6, y: -6)
                }
            }
            Text(vm.sessionLabel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            if !vm.currentToolDescription.isEmpty {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(vm.currentToolDescription)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if vm.flagCount > 0 {
                flagBadge
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 240, height: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { pulse = true }
    }

    private var pulseDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
    }

    private var dotColor: Color {
        switch vm.activity {
        case .idle:                          return .green
        case .triaging:                      return .blue
        case .flagged(let severity, _):
            switch severity {
            case .low:     return .yellow
            case .medium:  return .orange
            case .high:    return .red
            }
        }
    }

    /// v0.1.4 Gap 5: SF Symbol name to overlay on the dot for pause /
    /// kill, distinguishing them from a plain notify at-a-glance. The
    /// overlay sits in the dot's upper-right corner (offset (6, -6))
    /// at 7pt — tight against the 8pt dot to read as part of the same
    /// indicator. `nil` (no overlay) for idle / triaging / notify.
    private var actionOverlayIcon: String? {
        guard case let .flagged(_, action) = vm.activity else { return nil }
        switch action {
        case .pause:                      return "pause.fill"
        case .kill:                       return "xmark"
        case .inject, .notify, .continue: return nil
        }
    }

    private var flagBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("\(vm.flagCount)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.red.opacity(0.12), in: Capsule())
    }
}
