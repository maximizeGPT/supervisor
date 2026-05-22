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
            pulseDot
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
        case .idle:                  return .green
        case .triaging:              return .blue
        case .flagged(let severity):
            switch severity {
            case .low:     return .yellow
            case .medium:  return .orange
            case .high:    return .red
            }
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
