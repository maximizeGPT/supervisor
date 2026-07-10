// SecondOpinionView.swift
//
// The inline render of a multi-model panel "second opinion" on a flag. Lives
// INSIDE the flag row (which is already a paperWarm card), so it uses a hairline
// rule + sections rather than a nested card. Follows the calm instrument
// vocabulary: signal green marks the consensus, the one amber attention tone
// marks disagreements / blind spots, mono carries the cost, and the reveal is
// the single expressive beat. No red, no gradients, no glass.
//
// Reads `vm.secondOpinion` and renders only when its flag id matches this row,
// so a request on one flag never paints another. Running / result / failed each
// get a distinct, honest state.

import SwiftUI
import SupervisorCore

struct SecondOpinionView: View {

    @ObservedObject var vm: HoverViewModel
    let flagId: String

    var body: some View {
        Group {
            if vm.secondOpinion.flagId == flagId {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(BrandMotion.expressive, value: vm.secondOpinion.flagId)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            Divider().overlay(BrandColor.mute.color.opacity(0.15))

            switch vm.secondOpinion {
            case let .running(id) where id == flagId:
                runningView
            case let .result(id, result) where id == flagId:
                resultView(result)
            case let .failed(id, reason) where id == flagId:
                failedView(reason)
            default:
                EmptyView()
            }
        }
        .padding(.top, BrandSpacing.xxs)
    }

    // MARK: - Running

    private var runningView: some View {
        HStack(spacing: BrandSpacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(BrandColor.signal.color)
            Text("Consulting the panel\u{2026}")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
            Spacer()
        }
        .padding(.vertical, BrandSpacing.xxs)
    }

    // MARK: - Result

    private func resultView(_ result: PanelResult) -> some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            // Consensus — the headline. A solid signal dot + "Consensus" label,
            // then the fused answer in ink. The one accent leads the eye here.
            VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
                HStack(spacing: BrandSpacing.xs) {
                    Circle()
                        .fill(BrandColor.signal.color)
                        .frame(width: BrandMetrics.statusDot, height: BrandMetrics.statusDot)
                    Text(result.degraded ? "Lead answer" : "Consensus")
                        .font(BrandFont.caption)
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(BrandColor.signal.color)
                }
                Text(result.consensus.isEmpty ? "The panel returned no consensus." : result.consensus)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Honest degrade note.
            if result.degraded {
                Label("The judge was unavailable, so this is the lead model's answer, not a fused verdict.",
                      systemImage: "exclamationmark.triangle")
                    .font(BrandFont.note)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(BrandColor.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Disagreements + blind spots carry the calm amber attention tone;
            // unique insights stay neutral (an addition, not a warning).
            labeledList("Contradictions", glyph: "arrow.triangle.branch",
                        tone: BrandColor.attention.color, items: result.contradictions)
            labeledList("Blind spots", glyph: "eye.slash",
                        tone: BrandColor.attention.color, items: result.blindSpots)
            labeledList("Unique insights", glyph: "sparkles",
                        tone: BrandColor.mute.color, items: result.uniqueInsights)

            // Who answered + cost, in the quiet mono meta vocabulary.
            metaRow(result)
        }
    }

    /// A labeled list section. Renders nothing when `items` is empty (so a clean
    /// consensus doesn't leave three empty headers behind).
    @ViewBuilder
    private func labeledList(_ title: String, glyph: String, tone: Color, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
                Text(title)
                    .font(BrandFont.caption)
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(BrandColor.mute.color)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
                        Image(systemName: glyph)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tone)
                            .frame(width: BrandMetrics.iconSmall)
                        Text(item)
                            .font(BrandFont.note)
                            .foregroundStyle(BrandColor.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// "N of M models answered · X tokens" plus a quiet Done affordance. Fusion
    /// results carry no per-member breakdown, so the count clause is dropped
    /// there rather than showing "0 of 0".
    private func metaRow(_ result: PanelResult) -> some View {
        HStack(spacing: BrandSpacing.xs) {
            if !result.perMember.isEmpty {
                let answered = result.perMember.filter { $0.succeeded }.count
                Text("\(answered) of \(result.perMember.count) models \u{00B7} \(tokenSummary(result.usage))")
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            } else {
                Text(tokenSummary(result.usage))
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            }
            Spacer()
            Button("Done") { vm.dismissSecondOpinion() }
                .buttonStyle(.plain)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
        }
        .padding(.top, BrandSpacing.xxs)
    }

    private func tokenSummary(_ u: PanelUsage) -> String {
        "\(u.inputTokens + u.outputTokens) tokens"
    }

    // MARK: - Failed

    private func failedView(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BrandColor.attention.color)
            Text(reason)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { vm.dismissSecondOpinion() }
                .buttonStyle(.plain)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
        }
        .padding(.vertical, BrandSpacing.xxs)
    }
}
