// AuditLogView.swift - v0.2.0 observability (Reddit feedback D).
//
// The Activity surface: a skimmable, per-session timeline of what Supervisor
// DECIDED and WHY. Merges audit entries (auto-answer / block / nudge / verdict)
// with significant flags (medium/high severity) so a watch-only session shows
// the flag-and-triage activity rather than reading as empty.

import AppKit
import SwiftUI
import SupervisorCore

public struct AuditLogView: View {

    @ObservedObject var vm: HoverViewModel

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let items = vm.recentActivity()
        return VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            header(count: items.count)

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: BrandSpacing.xs) {
                        ForEach(items) { item in
                            switch item {
                            case .audit(let entry):
                                AuditEntryRow(entry)
                            case .flag(let flag):
                                FlagTimelineRow(flag)
                            }
                        }
                    }
                    .padding(.horizontal, BrandSpacing.md)
                    .padding(.bottom, BrandSpacing.xs)
                }
            }

            Spacer(minLength: 0)
            exportFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandColor.paper.color)
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            BrandSectionHeader("Activity")
            Spacer()
            if count > 0 {
                Text("\(count) \(count == 1 ? "event" : "events")")
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
            }
        }
        .padding(.horizontal, BrandSpacing.md)
        .padding(.top, BrandSpacing.md)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
            Text("No activity yet")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.ink.color)
            Text("When Supervisor flags, answers, blocks, or nudges, the receipt shows here.")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrandSpacing.md)
        .padding(.vertical, BrandSpacing.sm)
    }

    // MARK: - Export footer

    private var exportFooter: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            Divider().overlay(BrandColor.mute.color.opacity(0.15))

            HStack(spacing: BrandSpacing.sm) {
                BrandSecondaryButton(
                    vm.isExporting ? "Exporting..." : "Export session report",
                    action: { vm.exportSessionReport() }
                )
                .disabled(vm.isExporting || vm.currentSessionId.isEmpty)

                if vm.isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BrandColor.mute.color)
                }
                Spacer()
            }

            if let result = vm.lastExport {
                exportResult(result)
            }
        }
        .padding(.horizontal, BrandSpacing.md)
        .padding(.bottom, BrandSpacing.md)
    }

    @ViewBuilder
    private func exportResult(_ result: HoverViewModel.ExportResult) -> some View {
        switch result {
        case let .success(_, markdownPath):
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(BrandColor.signal.color)
                Text(markdownPath.lastPathComponent)
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Reveal in Finder") {
                    Self.revealInFinder(markdownPath)
                }
                .buttonStyle(.plain)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.signal.color)
            }
        case let .failure(reason):
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(BrandColor.attention.color)
                Text(reason)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
            }
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
