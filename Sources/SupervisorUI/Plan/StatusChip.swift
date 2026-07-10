// StatusChip.swift — v0.2.0 M3.
//
// The plan-state pill from the Stitch brief: Screen 1's "Running" status word
// and Screen 2's "Awaiting approval" capsule are the same component at two
// registers. One chip, a small set of cases, so the plan's lifecycle reads
// the same wherever it shows.
//
// Per STITCH_SPEC section 3d the chip is a fully-rounded `Capsule()` with a
// quiet fill and a caption-weight label. It carries NO green: green is the
// live pulse dot beside it and the one primary action, not the chip. The
// `awaitingApproval` case is the approval gate's visible signal — the footer's
// "Approve plan" primary is enabled only while this chip shows.
//
// The chip maps from the domain `Plan.Status` via `init(planStatus:)` so call
// sites pass the live plan directly; the small presentation enum keeps the
// component independent of every Plan.Status case (draft/approved/completed/
// aborted fold onto the nearest meaningful chip).

import SwiftUI
import SupervisorCore

public struct StatusChip: View {

    /// The presentation states the chip renders. A deliberately small set:
    /// the states the brief shows, plus `completed` and `aborted` for
    /// terminal plans.
    public enum State: Equatable {
        case awaitingApproval
        case running
        case paused
        /// A live session kill (the operator or a safety rule stopped the
        /// session). Passed explicitly by the panel (like `.paused`); the plan
        /// record has no killed status of its own, so a `running` plan under a
        /// live kill still reads "Stopped" instead of "Running" (RC fix #5).
        case stopped
        case completed
        case aborted
    }

    /// The resolved presentation state. Internal so tests can assert the
    /// Plan.Status -> chip mapping without rendering.
    let chipState: State
    private let dark: Bool

    public init(_ state: State, dark: Bool = false) {
        self.chipState = state
        self.dark = dark
    }

    /// Map the domain plan status onto a chip state. `paused` is passed
    /// explicitly by the panel when Supervisor is globally paused (the plan
    /// record has no paused status of its own), so a `running` plan under a
    /// global pause can still show "Paused" without a model change.
    ///
    /// `.approved` maps to `.awaitingApproval` (not `.running`) because the
    /// approved-but-not-yet-started transient state is closer to "waiting"
    /// than "running," and mapping it to running caused the Approve button
    /// to grey out while the chip said "Running."
    public init(planStatus: Plan.Status, dark: Bool = false) {
        let mapped: State
        switch planStatus {
        case .draft, .awaitingApproval, .approved: mapped = .awaitingApproval
        case .running:                             mapped = .running
        case .paused:                              mapped = .paused
        case .completed:                           mapped = .completed
        case .aborted:                             mapped = .aborted
        }
        self.init(mapped, dark: dark)
    }

    private var label: String {
        switch chipState {
        case .awaitingApproval: return "Awaiting approval"
        case .running:          return "Running"
        case .paused:           return "Paused"
        case .stopped:          return "Stopped"
        case .completed:        return "Completed"
        case .aborted:          return "Aborted"
        }
    }

    public var body: some View {
        Text(label)
            .font(BrandFont.caption)
            .tracking(0.3)
            .foregroundStyle(labelColor)
            .padding(.horizontal, BrandSpacing.sm)
            .padding(.vertical, BrandSpacing.xxs)
            .background(fillColor, in: Capsule())
            .overlay(
                Capsule().strokeBorder(strokeColor, lineWidth: BrandMetrics.hairline)
            )
    }

    // Light register: ink label on a warm-paper capsule. Dark register
    // (Screen 2): a light paper label on a translucent paper fill, the way
    // the brief draws the "Awaiting approval" pill on the near-black surface.
    private var labelColor: Color {
        dark ? BrandColor.paper.color : BrandColor.ink.color
    }

    private var fillColor: Color {
        dark ? BrandColor.paper.color.opacity(0.12) : BrandColor.paperWarm.color
    }

    private var strokeColor: Color {
        dark ? BrandColor.paper.color.opacity(0.18)
             : BrandColor.mute.color.opacity(0.25)
    }
}
