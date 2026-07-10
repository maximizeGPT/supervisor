// ReviewView.swift — v0.3.x REVIEW dimension.
//
// The Review tab: a calm, scannable home for the code-review observations
// Supervisor surfaced while the session wrote code. Reviews are PULL, not push —
// this is where the owner comes to read them, on their own time.
//
// Two states, both intentional:
//   - Empty: a quiet, confident "reviewing… nothing to flag" — silence is the
//     good outcome, so the empty state reassures rather than reading as broken.
//   - Findings: newest-first cards, each an expandable ReviewFindingRow.
//
// Opening the tab clears the quiet unseen badge on the hover band (a read
// receipt), so the band only whispers when there is genuinely something new.

import SwiftUI
import SupervisorCore

public struct ReviewView: View {

    @ObservedObject var vm: HoverViewModel

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        // Reading storeRevision here ties the whole view to store writes, so a new
        // finding re-renders the list live (RC fix #1 pattern).
        _ = vm.storeRevision
        let findings = vm.recentReviews()

        return VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            header(count: findings.count)

            if findings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: BrandSpacing.xs) {
                        ForEach(findings, id: \.id) { finding in
                            ReviewFindingRow(finding)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, BrandSpacing.md)
                    .padding(.bottom, BrandSpacing.xs)
                    .animation(BrandMotion.standard, value: vm.storeRevision)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandColor.paper.color)
        .onAppear { vm.markReviewsSeen() }
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            BrandSectionHeader("Review")
            Spacer()
            if count > 0 {
                Text("\(count) \(count == 1 ? "observation" : "observations")")
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            }
        }
        .padding(.horizontal, BrandSpacing.md)
        .padding(.top, BrandSpacing.md)
    }

    // MARK: - Empty state (silence is the good outcome)

    private var emptyState: some View {
        let enabled = vm.isReviewEnabled()
        return VStack(spacing: BrandSpacing.sm) {
            Spacer(minLength: 0)
            Image(systemName: enabled ? "eye" : "eye.slash")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(BrandColor.mute.color.opacity(0.55))
            Text(enabled ? "Reviewing as your session writes code" : "Code review is off")
                .font(BrandFont.body)
                .foregroundStyle(BrandColor.ink.color)
                .multilineTextAlignment(.center)
            Text(enabled
                 ? "Substantive issues in the code will appear here. No news is good news — Supervisor stays quiet unless something is worth a look."
                 : "Turn on the review dimension to have Supervisor review each change as your session writes it, and surface substantive issues here.")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, BrandSpacing.lg)
    }
}
