// AgentBadge.swift
//
// The small, quiet chip that says which agent a session belongs to (Codex /
// Claude Code). It exists only because Supervisor now watches more than one
// agent; callers gate it on `HoverViewModel.isMultiAgent` so a single-agent
// user never sees it (progressive disclosure).
//
// Deliberately MONOCHROME. The band and panel spend their one accent on STATE
// (signal green = watching, attention amber = a flag); agent identity must not
// introduce a second hue or a glance becomes ambiguous. So this is a neutral
// chip in adaptive ink tones with a tiny mark — a filled square for Codex, an
// outline square for Claude Code — that reads calmly over either the band's
// light/dark material or the panel's paper surface.

import SwiftUI
import SupervisorCore

public struct AgentBadge: View {

    private let agent: AgentKind

    public init(_ agent: AgentKind) {
        self.agent = agent
    }

    public var body: some View {
        HStack(spacing: BrandSpacing.xxs) {
            mark
            Text(agent.shortName)
                .font(BrandFont.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, BrandSpacing.xs)
        .padding(.vertical, BrandSpacing.xxs)
        // Adaptive neutral fill + hairline so the chip belongs on both the band's
        // translucent material and the panel's paper, in light or dark.
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: BrandRadius.small)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.small)
                .strokeBorder(.separator, lineWidth: BrandMetrics.hairline)
        )
        .accessibilityElement()
        .accessibilityLabel("\(agent.displayName) session")
    }

    /// The tiny anchor mark. Neutral, in the secondary role so the wordmark
    /// carries the meaning and the mark is just something for the eye to catch.
    @ViewBuilder private var mark: some View {
        let side: CGFloat = 6
        switch agent {
        case .codex:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.secondary)
                .frame(width: side, height: side)
        case .claudeCode:
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(.secondary, lineWidth: 1.2)
                .frame(width: side, height: side)
        }
    }
}
