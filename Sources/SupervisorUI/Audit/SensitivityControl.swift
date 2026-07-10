// SensitivityControl.swift - v0.2.0 (Reddit feedback E).
//
// The owner control for decision sensitivity: a small token-styled segmented
// control (Cautious / Balanced / Decisive) with a one-line description of the
// selected stop. It answers the thread's question - "how does it decide to
// interrupt me vs. handle it confidently" - by making that a dial the owner
// sets, not a hidden constant.
//
// Built as a custom three-segment pill rather than the stock SwiftUI Picker so
// it sits in the same tinted-chip vocabulary as the panel's other controls
// (Capsule segments, BrandFont.caption labels, the signal-green tint on the
// selected segment - the one accent). Composition only; the VM owns the value
// (decisionSensitivity) and the setter (setDecisionSensitivity), so this view
// binds and renders.

import SwiftUI
import SupervisorCore

public struct SensitivityControl: View {

    @ObservedObject var vm: HoverViewModel

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            // NOTE: no title header here — the enclosing collapsibleSection
            // ("Decision Sensitivity") already renders the section heading via
            // BrandSectionHeader. A second BrandSectionHeader here rendered the
            // title TWICE in the panel; removed so it appears exactly once. The
            // control + its one-line description below are unchanged.

            // The three-stop segmented control.
            HStack(spacing: BrandSpacing.xxs) {
                ForEach(DecisionSensitivity.allCases, id: \.self) { option in
                    segment(option)
                }
            }
            .padding(BrandSpacing.xxs)
            .background(
                BrandColor.paperWarm.color,
                in: RoundedRectangle(cornerRadius: BrandRadius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BrandRadius.control)
                    .strokeBorder(BrandColor.mute.color.opacity(0.15), lineWidth: BrandMetrics.hairline)
            )

            // One-line description of the selected stop.
            Text(vm.decisionSensitivity.summary)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One segment. The selected stop carries the one signal-green tint (fill +
    /// on-tone label); the others are quiet mute text on the bare track.
    private func segment(_ option: DecisionSensitivity) -> some View {
        let selected = vm.decisionSensitivity == option
        return Button(action: { vm.setDecisionSensitivity(option) }) {
            Text(option.title)
                .font(BrandFont.caption)
                .foregroundStyle(selected ? BrandColor.signal.color : BrandColor.mute.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BrandSpacing.xs)
                .background(
                    selected ? BrandColor.signal.color.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: BrandRadius.small)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BrandRadius.small)
                        .strokeBorder(
                            selected ? BrandColor.signal.color.opacity(0.3) : Color.clear,
                            lineWidth: BrandMetrics.hairline
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
