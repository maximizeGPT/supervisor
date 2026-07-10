// FlagTimelineRow.swift - v0.2.0 Activity timeline.
//
// A timeline row for a significant flag (medium/high severity), rendered in
// the same warm-paper card style as AuditEntryRow so the merged Activity
// timeline reads as one cohesive log. Shows the severity badge, category,
// and the flag's plain-language reasoning.

import SwiftUI
import SupervisorCore

struct FlagTimelineRow: View {

    private let flag: StoredFlag

    init(_ flag: StoredFlag) {
        self.flag = flag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: BrandSpacing.xs) {
                SeverityBadge(flag.severity)
                Text(flag.category)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.ink.color)
                    .lineLimit(1)
                Spacer(minLength: BrandSpacing.xs)
                Text(AuditEntryRow.relativeTime(flag.ts))
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            }

            Text(flag.reasoningPlain)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            if let action = actionLabel {
                HStack(spacing: BrandSpacing.xs) {
                    Text("ACTION")
                        .font(BrandFont.caption)
                        .tracking(0.4)
                        .foregroundStyle(BrandColor.mute.color)
                        .frame(width: 64, alignment: .leading)
                    Text(action)
                        .font(BrandFont.monoSmall)
                        .foregroundStyle(BrandColor.mute.color)
                }
            }
        }
        .padding(BrandSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColor.paperWarm.color,
            in: RoundedRectangle(cornerRadius: BrandRadius.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.control)
                .strokeBorder(BrandColor.mute.color.opacity(0.15), lineWidth: BrandMetrics.hairline)
        )
    }

    private var actionLabel: String? {
        switch flag.action {
        case .notify:     return nil  // quiet, no action line needed
        case .inject:     return "Injected answer"
        case .continue:   return "Dispatched task"
        case .selfExtend: return "Self-extended"
        case .pause:      return "Paused session"
        case .kill:       return "Terminated session"
        }
    }
}
