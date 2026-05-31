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

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            flagsSection
            Divider()
            activitySection
            Divider()
            footer
        }
        .frame(width: 480, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                severityBadge(flag.severity)
                Text(flag.category.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.relativeTime(flag.ts))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(flag.reasoningPlain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Action buttons — only show if user hasn't responded yet.
            if flag.userResponse == nil {
                HStack(spacing: 8) {
                    Button("Dismiss") {
                        vm.respondToFlag(flagId: flag.id, response: .dismissed)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.borderless)

                    Button("False positive") {
                        vm.respondToFlag(flagId: flag.id, response: .falsePositive)
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
                .padding(.top, 2)
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

    private static func responseLabel(_ response: FlagUserResponse) -> String {
        switch response {
        case .approved: return "Approved"
        case .dismissed: return "Dismissed"
        case .falsePositive: return "Marked as false positive"
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

            Text("Cost so far: \(Self.formatCost(vm.todayCostUSD()))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)

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
        HStack {
            Spacer()
            Text("\(vm.flagCount) flags total")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

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
