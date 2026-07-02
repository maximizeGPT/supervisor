// ExpandedPanelView.swift
//
// 480x360 expanded panel that slides below the hover window on click.
// Shows recent flags, session metrics (model, turns, tool calls, cost),
// and current activity. Per DESIGN.md section 6.2.
//
// v0.1.7: first vertical slice. Flag action buttons (Approve/Dismiss/
// False positive) and session switching are deferred — they require
// router wiring and multi-session UI respectively.

import SwiftUI
import SupervisorCore

public struct ExpandedPanelView: View {

    @ObservedObject var vm: HoverViewModel
    @State private var expandedFlagIds: Set<String> = []

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionsSection
            Divider()
            flagsSection
            Divider()
            activitySection
            Divider()
            controlsSection
            Divider()
            footer
        }
        .frame(width: 480, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Controls section (owner runtime toggles)

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTROLS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            HStack(spacing: 8) {
                // Global pause / resume — Supervisor goes dormant (no triage,
                // dispatch, or inject) until resumed.
                Button(action: { vm.toggleSupervisorPaused() }) {
                    Label(vm.supervisorPaused ? "Resume Supervisor" : "Pause Supervisor",
                          systemImage: vm.supervisorPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .tint(vm.supervisorPaused ? BrandColor.signal.color : .orange)

                // 4-hour loop cap on / off.
                Button(action: { vm.toggleLoopCapDisabled() }) {
                    Label(vm.loopCapDisabled ? "4h cap: off" : "4h cap: on",
                          systemImage: vm.loopCapDisabled ? "infinity" : "timer")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .tint(vm.loopCapDisabled ? .orange : BrandColor.mute.color)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("supervisor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\u{25B8}")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(vm.sessionCwd.isEmpty ? "no session" : vm.sessionCwd)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions section (what Supervisor DID)

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT ACTIONS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            if vm.recentActions.isEmpty {
                Text("No actions taken yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.recentActions.prefix(5)) { action in
                        HStack(spacing: 6) {
                            actionIcon(action.action)
                            Text(action.plainDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.relativeTime(action.ts))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: 100)
    }

    private func actionIcon(_ action: FlagAction) -> some View {
        let (icon, color): (String, Color) = {
            switch action {
            case .pause:      return ("pause.fill", .orange)
            case .kill:       return ("xmark.circle.fill", .red)
            case .inject:     return ("text.bubble.fill", .blue)
            case .continue:   return ("arrow.right.circle.fill", BrandColor.signal.color)
            case .selfExtend: return ("wrench.fill", .purple)
            case .notify:     return ("bell.fill", .secondary)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(color)
    }

    // MARK: - Flags section

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT FLAGS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            let flags = vm.recentFlags(limit: 5)
            if flags.isEmpty {
                Text("No flags this session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(flags, id: \.id) { flag in
                            flagRow(flag)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func flagRow(_ flag: StoredFlag) -> some View {
        let isExpanded = expandedFlagIds.contains(flag.id)

        return VStack(alignment: .leading, spacing: 2) {
            // Header row — always visible, clickable to toggle.
            HStack {
                severityBadge(flag.severity)
                Text(flag.category.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.relativeTime(flag.ts))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedFlagIds.remove(flag.id)
                    } else {
                        expandedFlagIds.insert(flag.id)
                    }
                }
            }

            // Collapsed: 2-line truncated reasoning.
            if !isExpanded {
                Text(flag.reasoningPlain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Expanded: full reasoning + technical + asymmetry note.
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flag.reasoningPlain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if !flag.reasoningTechnical.isEmpty {
                        Text("Technical:")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(flag.reasoningTechnical)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                    if let note = flag.asymmetryNote, !note.isEmpty {
                        Text("Asymmetry:")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(note)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                    // Action + severity details.
                    HStack(spacing: 8) {
                        Text("Action: \(flag.action.rawValue)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Severity: \(flag.severity.rawValue)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            // Action buttons. Only show if the user hasn't responded yet.
            // Override is the primary control: a real bordered button in
            // the brand signal color, not bare red text. It's a normal
            // human override, not a destructive action, so it must not
            // read as alarm-red. Dismiss and False positive stay as quiet
            // text actions so Override is clearly the prominent one.
            if flag.userResponse == nil {
                HStack(spacing: 10) {
                    Button("Override") {
                        vm.rejectFlag(flagId: flag.id, action: flag.action)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(BrandColor.signal.color)
                    .help(overrideHelp(flag))

                    Button("Dismiss") {
                        vm.respondToFlag(flagId: flag.id, response: .dismissed)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.borderless)
                    .foregroundStyle(BrandColor.mute.color)

                    Button("False positive") {
                        vm.respondToFlag(flagId: flag.id, response: .falsePositive)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.borderless)
                    .foregroundStyle(BrandColor.mute.color)
                }
                .padding(.top, 3)
            } else {
                Text(Self.responseLabel(flag.userResponse!))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(6)
        .background(severityBackground(flag.severity), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Tooltip text for the Override button. Says what overriding does in
    /// this flag's context. Plain sentences, no dashes.
    private func overrideHelp(_ flag: StoredFlag) -> String {
        switch flag.action {
        case .pause:
            return "Let Claude Code continue. This resumes the paused session."
        case .kill:
            return "The session already ended. This clears the flag."
        default:
            return "Override Supervisor on this flag."
        }
    }

    private static func responseLabel(_ response: FlagUserResponse) -> String {
        switch response {
        case .approved: return "Approved"
        case .dismissed: return "Dismissed"
        case .falsePositive: return "Marked as false positive"
        case .rejected: return "Overridden"
        }
    }

    private func severityBadge(_ severity: FlagSeverity) -> some View {
        Text(severity.rawValue.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(severityColor(severity), in: RoundedRectangle(cornerRadius: 2))
    }

    private func severityColor(_ severity: FlagSeverity) -> Color {
        switch severity {
        case .low:    return .yellow
        case .medium: return .orange
        case .high:   return .red
        }
    }

    private func severityBackground(_ severity: FlagSeverity) -> Color {
        severityColor(severity).opacity(0.08)
    }

    // MARK: - Activity section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CURRENT ACTIVITY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 4) {
                if !vm.modelName.isEmpty {
                    Text("Model: \(vm.modelName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\u{00B7}")
                        .foregroundStyle(.secondary)
                }
                Text("\(vm.turnCount) turns")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\u{00B7}")
                    .foregroundStyle(.secondary)
                Text("\(vm.toolCallCount) tool calls")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !vm.detailLabel.isEmpty {
                Text("Now: \(vm.detailLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if vm.isPaused {
                Button(action: { vm.resumePausedSession() }) {
                    HStack(spacing: 4) {
                        if vm.isResuming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                        }
                        Text(vm.isResuming ? "Resuming..." : "Resume Claude Code")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.signal.color)
                .disabled(vm.isResuming)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("\(vm.flagCount) flags this session")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text("\u{00B7}")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            // v0.3.0 (audit F1): today's spend, finally rendered — the
            // README's cost-view claim lives here. Cheap single-row read;
            // querying inside body follows the recentFlags pattern above.
            Text(Self.footerCostText(vm.todayCostUSD()))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    /// Footer spend line, e.g. "$0.43 today". Static so tests pin the
    /// exact string the footer renders.
    static func footerCostText(_ usd: Double) -> String {
        "\(formatCost(usd)) today"
    }

    static func formatCost(_ usd: Double) -> String {
        if usd < 0.01 { return "$0.00" }
        return String(format: "$%.2f", usd)
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
