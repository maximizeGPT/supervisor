// HoverView.swift
//
// 240x40 always-on-top hover band. The compact "live instrument" read of the
// whole app: a breathing pulse dot, the plain session label, an optional
// secondary detail line, and a flag-count badge. It is the smallest surface in
// the system, so it carries the same design language as the Plan card at the
// tightest density, one green accent for the live/watching pulse, the calm
// amber attention tone for a flag, type-driven hierarchy, hairline chrome.
//
// v0.2.0 M3: retokenized off the old raw .system(size:) literals and the
// .green/.blue/.yellow/.orange/.red dot ladder. The live dot is now the shared
// PulseDot primitive (the same breathing concentric halo the Plan view's
// "Running" indicator and the active-step icon use), tinted by state through
// the tokens: signal green while watching/acting, the attention amber while a
// flag is up, mute while it is mid-check. The flag badge reuses the severity
// attention tone instead of a bare system red. All vm bindings are unchanged.

import SwiftUI
import SupervisorCore

public struct HoverView: View {

    @ObservedObject var vm: HoverViewModel

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: BrandSpacing.sm) {
            // The live indicator. dot + pause/kill overlay-glyph sit in a
            // ZStack so the overlay anchors to the dot regardless of the
            // row's other layout (v0.1.4 Gap 5).
            ZStack {
                PulseDot(tint: dotTint)
                if let icon = actionOverlayIcon {
                    Image(systemName: icon)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(BrandColor.paper.color)
                        .offset(x: 6, y: -6)
                }
            }
            // Fixed footprint matching the dot so the label sits at a steady
            // left edge as the halo breathes (PulseDot is statusDot-cored
            // inside a pulseHalo-wide breathing ring).
            .frame(width: BrandMetrics.statusDot, height: BrandMetrics.statusDot)

            // Which agent this session belongs to — shown only when Supervisor
            // is watching more than one agent kind, so a single-agent user sees
            // no added chrome. Monochrome by design; state keeps the one accent.
            if vm.isMultiAgent {
                AgentBadge(vm.currentAgent)
            }

            // The band floats over a translucent material on top of whatever
            // is frontmost (a light or dark terminal), and the window follows
            // the system appearance. The brand ink/mute tokens are tuned for
            // the light paper surface and would wash out on a dark material,
            // so the TEXT stays on the adaptive primary/secondary roles that
            // read in both modes. The one accent (the pulse dot, the flag
            // badge) is saturated enough to hold either way and stays on the
            // brand tokens.
            Text(vm.plainLabel)
                .font(BrandFont.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if !vm.detailLabel.isEmpty {
                Text("\u{00B7}")
                    .font(BrandFont.note)
                    .foregroundStyle(.secondary)
                Text(vm.detailLabel)
                    .font(BrandFont.note)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: BrandSpacing.xs)

            // A quiet, self-clearing whisper that there's something new in Review.
            // Mute tone (informational, never the amber safety accent); it clears
            // the moment the owner opens the Review tab. Placed before the flag
            // badge so the safety signal stays primary.
            if vm.unseenReviewCount > 0 {
                reviewIndicator
                    .transition(.opacity)
            }

            if vm.flagCount > 0 {
                flagBadge
            }
        }
        .animation(BrandMotion.standard, value: vm.unseenReviewCount)
        .padding(.horizontal, BrandSpacing.sm)
        .padding(.vertical, BrandSpacing.sm)
        .frame(width: 240, height: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BrandRadius.control))
        // The quiet resting chrome: a hairline rule at the Plan card's 1px
        // weight, but on the adaptive separator role (not the light-tuned
        // mute token) so it reads as a soft edge over either a light or dark
        // material.
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.control)
                .strokeBorder(.separator, lineWidth: BrandMetrics.hairline)
        )
        // v0.8.1: action flash, a visible signal-green border glow when
        // Supervisor acts. Now on the brand signal token + the expressive
        // motion beat (the one moment worth noticing), not an ad-hoc duration.
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.control)
                .strokeBorder(BrandColor.signal.color, lineWidth: vm.actionFlash ? 3 : 0)
                .opacity(vm.actionFlash ? 1 : 0)
                .animation(BrandMotion.expressive, value: vm.actionFlash)
        )
        .scaleEffect(vm.actionFlash ? 1.03 : 1.0)
        .animation(BrandMotion.expressive, value: vm.actionFlash)
    }

    /// The pulse-dot tint, expressing activity through the one-accent rule:
    ///   - idle / watching: signal green (the live "all clear" breath).
    ///   - triaging: mute grey (a neutral mid-check, not a live-green claim
    ///     and not an alarm).
    ///   - flagged: the calm amber attention tone, folded through the same
    ///     severity -> color mapping SeverityBadge owns (medium/high amber,
    ///     low mute), so the dot and any flag badge agree on the hue.
    private var dotTint: Color {
        switch vm.activity {
        case .idle:                      return BrandColor.signal.color
        case .triaging:                  return BrandColor.mute.color
        case .flagged(let severity, _, _, _, _): return SeverityBadge.color(for: severity)
        }
    }

    /// v0.1.4 Gap 5: SF Symbol name to overlay on the dot for pause / kill,
    /// distinguishing them from a plain notify at-a-glance. The overlay sits
    /// in the dot's upper-right corner at 7pt, tight against the dot so it
    /// reads as part of the same indicator. nil for idle / triaging / notify.
    private var actionOverlayIcon: String? {
        guard case let .flagged(_, action, _, _, _) = vm.activity else { return nil }
        switch action {
        case .pause:                      return "pause.fill"
        case .kill:                       return "xmark"
        case .inject, .notify, .continue, .selfExtend: return nil
        }
    }

    /// The flag-count badge. A small severity-tinted capsule with a leading
    /// warning glyph, matching the SeverityBadge vocabulary (the attention
    /// amber as a low-opacity fill + solid-tone label/glyph), not a bare
    /// system-red pill.
    private var flagBadge: some View {
        HStack(spacing: BrandSpacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("\(vm.flagCount)")
                .font(BrandFont.caption)
        }
        .foregroundStyle(BrandColor.attention.color)
        .padding(.horizontal, BrandSpacing.xs)
        .padding(.vertical, BrandSpacing.xxs)
        .background(BrandColor.attention.color.opacity(0.14), in: Capsule())
    }

    /// The quiet unseen-review whisper. Deliberately calmer than the flag badge:
    /// the mute tone (not the amber safety accent) and an `eye` glyph, so it reads
    /// as "there's something to read when you're ready," never as an alert. It
    /// clears the instant the owner opens the Review tab (markReviewsSeen).
    private var reviewIndicator: some View {
        HStack(spacing: BrandSpacing.xxs) {
            Image(systemName: "eye")
                .font(.system(size: 9, weight: .semibold))
            Text("\(vm.unseenReviewCount)")
                .font(BrandFont.caption)
        }
        .foregroundStyle(BrandColor.mute.color)
        .padding(.horizontal, BrandSpacing.xs)
        .padding(.vertical, BrandSpacing.xxs)
        .background(BrandColor.mute.color.opacity(0.18), in: Capsule())
    }
}
