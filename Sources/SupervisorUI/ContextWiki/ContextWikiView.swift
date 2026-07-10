// ContextWikiView.swift — the "Context Health" window.
//
// A calm, one-glance read on a project's AI-context health, built entirely on
// the Supervisor brand vocabulary (paper/ink ground, ONE signal-green accent,
// amber ONLY for genuine attention, the 4pt spacing scale, quiet motion). The
// register is deliberately Jobs/Wispr/Plaid: a single verdict, a ranked list of
// non-destructive cleanups, exactly ONE lit next action, and an honest sign-off
// that never pretends work was done.
//
// This layout is the product of a design-critique panel. Deliberate choices it
// encodes:
//   - ONE summary instrument (the verdict), not three. No mixed-unit charts.
//   - Approving RECORDS sign-off; it does not edit files, so the approved state
//     reads "ready to apply" (full opacity, undoable), never "done" (strikethrough
//     / fade), which would falsely claim work happened.
//   - Only the top unresolved card gets the filled primary action; the rest are
//     quiet until they become the top — one lit path down the list.
//   - Amber is spent once (the single notable item), never as repeated chrome,
//     and never as sub-14pt text (it fails contrast); its hue lives in fills.
//   - Sign-offs have a real destination (copy as a task list), so the flow never
//     dead-ends.

import AppKit
import SwiftUI
import SupervisorCore

public struct ContextWikiView: View {

    @ObservedObject var vm: ContextWikiViewModel

    public init(vm: ContextWikiViewModel) { self.vm = vm }

    public var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            if vm.report == nil {
                loadingBody
            } else if vm.isClean {
                clearBody
            } else {
                // The verdict + tabs are PINNED (always one glance); only the
                // content list scrolls beneath them.
                hero
                segmented.padding(.horizontal, BrandSpacing.lg).padding(.bottom, BrandSpacing.md)
                ScrollView { paneContent.padding(.horizontal, BrandSpacing.lg).padding(.bottom, BrandSpacing.md) }
                if vm.acceptedCount > 0 { approvalBar }
            }
            footer
        }
        .frame(minWidth: 620, minHeight: 500)
        .background(BrandColor.paper.color)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: BrandSpacing.sm) {
            RoundedRectangle(cornerRadius: 5).fill(BrandColor.signal.color).frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(BrandColor.ink.color.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Context Health").font(BrandFont.title.weight(.semibold)).foregroundStyle(BrandColor.ink.color)
                Text(shortRoot).font(BrandFont.monoSmall).foregroundStyle(BrandColor.mute.color)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: BrandSpacing.md)
            reauditButton
        }
        .padding(.leading, 72)      // clear the window's traffic lights
        .padding(.trailing, BrandSpacing.lg)
        .padding(.vertical, BrandSpacing.md)
    }

    private var reauditButton: some View {
        Button(action: { vm.runAudit() }) {
            HStack(spacing: 6) {
                if vm.isAuditing {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                Text(vm.isAuditing ? "Auditing…" : "Re-audit").font(BrandFont.button)
            }
            .foregroundStyle(BrandColor.ink.color)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(BrandColor.paperWarm.color, in: RoundedRectangle(cornerRadius: BrandRadius.control))
            .overlay(RoundedRectangle(cornerRadius: BrandRadius.control).strokeBorder(BrandColor.mute.color.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(vm.isAuditing)
        .help("Re-scan this project's context files")
    }

    private var hairline: some View {
        Rectangle().fill(BrandColor.mute.color.opacity(0.14)).frame(height: BrandMetrics.hairline)
            .padding(.horizontal, BrandSpacing.lg)
    }

    // MARK: - Bodies

    private var loadingBody: some View {
        VStack(spacing: BrandSpacing.md) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Reading your context…").font(BrandFont.body).foregroundStyle(BrandColor.mute.color)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var paneContent: some View {
        switch vm.tab {
        case .recommendations: recommendationsPane
        case .wiki:            wikiPane
        case .schema:          schemaPane
        }
    }

    // MARK: - Hero (the ONE summary instrument)

    private var hero: some View {
        let v = vm.verdict
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                PulseDotMini(color: BrandColor.signal.color)   // healthy = green; amber is reserved for the flagged item
                Text(eyebrowText).font(BrandFont.caption).tracking(0.7).textCase(.uppercase)
                    .foregroundStyle(BrandColor.mute.color)
            }
            .padding(.bottom, 4)
            accentedHeadline(v).font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
            Text(v.subline).font(BrandFont.body).foregroundStyle(BrandColor.mute.color).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(scopeLine).font(BrandFont.monoSmall).foregroundStyle(BrandColor.mute.color.opacity(0.85))
                .padding(.top, 3)
        }
        .padding(.horizontal, BrandSpacing.lg)
        .padding(.top, BrandSpacing.xl)
        .padding(.bottom, BrandSpacing.lg)
    }

    private var eyebrowText: String {
        let skills = Set((vm.report?.sources ?? []).compactMap(\.skill)).count
        return skills > 0 ? "Audited just now · \(skills) skills" : "Audited just now"
    }

    /// One quiet line of scan scope, with units — replaces the old 3-summary stack.
    private var scopeLine: String {
        let total = vm.report?.metrics.totalSources ?? 0
        let prose = vm.report?.metrics.proseSources ?? 0
        return "\(total) files scanned · \(prose) are context the model reads"
    }

    private func accentedHeadline(_ v: ContextWikiViewModel.Verdict) -> Text {
        let accent = v.severity == .info ? BrandColor.signal.color : BrandColor.attention.color
        guard let range = v.headline.range(of: v.accentWord) else {
            return Text(v.headline).foregroundColor(BrandColor.ink.color)
        }
        let pre = String(v.headline[v.headline.startIndex..<range.lowerBound])
        let mid = String(v.headline[range])
        let post = String(v.headline[range.upperBound...])
        return Text(pre).foregroundColor(BrandColor.ink.color)
            + Text(mid).foregroundColor(accent)
            + Text(post).foregroundColor(BrandColor.ink.color)
    }

    // MARK: - Segmented control

    private var segmented: some View {
        HStack(spacing: 2) {
            segButton("Recommendations", .recommendations)
            segButton("Wiki", .wiki)
            segButton("Schema", .schema)
        }
        .padding(3)
        .background(BrandColor.paperWarm.color, in: RoundedRectangle(cornerRadius: BrandRadius.control))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segButton(_ title: String, _ tag: ContextWikiViewModel.Tab) -> some View {
        let selected = vm.tab == tag
        return Button(action: { withAnimation(BrandMotion.standard) { vm.tab = tag } }) {
            Text(title).font(BrandFont.button)
                .foregroundStyle(selected ? BrandColor.ink.color : BrandColor.mute.color)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6).fill(BrandColor.paper.color)
                            .shadow(color: BrandColor.ink.color.opacity(0.08), radius: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panes

    private var recommendationsPane: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.sm) {
            Text("Ranked by impact. Reviewing is safe — approving records your sign-off, it doesn't touch any file.")
                .font(BrandFont.note).foregroundStyle(BrandColor.mute.color).lineSpacing(3)
                .padding(.bottom, BrandSpacing.xxs)
            ForEach(vm.actionable) { rec in
                RecommendationCard(rec: rec, vm: vm, isPrimary: vm.isTopUnresolved(rec))
            }
        }
    }

    private var wikiPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Topics that live in more than one place. The home is where each should live; the rest link to it.")
                .font(BrandFont.note).foregroundStyle(BrandColor.mute.color).lineSpacing(3)
                .padding(.bottom, BrandSpacing.sm)
            if vm.duplicatedTopics.isEmpty {
                Text("No cross-file duplication detected.").font(BrandFont.body).foregroundStyle(BrandColor.mute.color)
                    .padding(.vertical, BrandSpacing.md)
            } else {
                ForEach(Array(vm.duplicatedTopics.prefix(40).enumerated()), id: \.offset) { _, topic in
                    WikiTopicRow(topic: topic)
                }
            }
        }
    }

    private var schemaPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The conventions that keep it from re-bloating — regenerated each audit, yours to adopt.")
                .font(BrandFont.note).foregroundStyle(BrandColor.mute.color).lineSpacing(3)
                .padding(.bottom, BrandSpacing.sm)
            ForEach(Array(vm.schemaRules.enumerated()), id: \.offset) { i, rule in
                SchemaRuleRow(index: i + 1, rule: rule)
            }
        }
    }

    // MARK: - Approval bar (the destination for sign-offs — flow never dead-ends)

    private var approvalBar: some View {
        HStack(spacing: BrandSpacing.md) {
            Text("\(vm.acceptedCount) approved").font(BrandFont.button).foregroundStyle(BrandColor.ink.color)
            Text("ready to apply").font(BrandFont.note).foregroundStyle(BrandColor.mute.color)
            Spacer()
            CopyTasksButton(vm: vm)
        }
        .padding(.horizontal, BrandSpacing.lg).padding(.vertical, BrandSpacing.sm)
        .background(BrandColor.signal.color.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(BrandColor.mute.color.opacity(0.14)).frame(height: BrandMetrics.hairline) }
    }

    // MARK: - Clear state

    private var clearBody: some View {
        VStack(spacing: BrandSpacing.md) {
            Spacer()
            RoundedRectangle(cornerRadius: 14).fill(BrandColor.signal.color).frame(width: 52, height: 52)
                .overlay(Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(BrandColor.paper.color))
                .shadow(color: BrandColor.signal.color.opacity(0.4), radius: 12, y: 8)
                .padding(.bottom, BrandSpacing.xs)
            Text("All clear. Your context is lean.").font(.system(size: 19, weight: .semibold)).foregroundStyle(BrandColor.ink.color)
            Text("No duplication, no oversized files, nothing to prune. Supervisor re-checks when your context changes.")
                .font(BrandFont.body).foregroundStyle(BrandColor.mute.color).multilineTextAlignment(.center)
                .lineSpacing(4).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(BrandSpacing.lg)
    }

    // MARK: - Footer (states the guarantee once)

    private var footer: some View {
        HStack(spacing: BrandSpacing.sm) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(BrandColor.mute.color)
            Text(vm.isClean ? "Re-checks automatically as your context changes."
                            : "Nothing changes until you approve it, and approving never edits a file.")
                .font(BrandFont.note).foregroundStyle(BrandColor.mute.color)
            Spacer(minLength: BrandSpacing.sm)
        }
        .padding(.horizontal, BrandSpacing.lg).padding(.vertical, BrandSpacing.md)
        .frame(maxWidth: .infinity)
        .background(BrandColor.paperWarm.color.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(BrandColor.mute.color.opacity(0.14)).frame(height: BrandMetrics.hairline) }
    }

    // MARK: - Helpers

    private var shortRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return vm.root.path.hasPrefix(home) ? "~" + vm.root.path.dropFirst(home.count) : vm.root.path
    }
}

// MARK: - Copy-tasks button (with a transient confirmation)

struct CopyTasksButton: View {
    @ObservedObject var vm: ContextWikiViewModel
    @State private var copied = false
    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(vm.approvedTasksText(), forType: .string)
            withAnimation(BrandMotion.standard) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(BrandMotion.standard) { copied = false } }
        }) {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                Text(copied ? "Copied" : "Copy as task list").font(BrandFont.button)
            }
            .foregroundStyle(BrandColor.paper.color)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(BrandColor.signal.color, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Copy the approved cleanups as a task list to hand to a session or do yourself")
    }
}

// MARK: - Recommendation card

struct RecommendationCard: View {
    let rec: Recommendation
    @ObservedObject var vm: ContextWikiViewModel
    /// Whether this is the single top unresolved item (gets the filled action).
    let isPrimary: Bool

    var body: some View {
        let approved = vm.isAccepted(rec)
        let expanded = vm.isExpanded(rec)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: BrandSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rec.title).font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(BrandColor.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rec.rationale).font(BrandFont.body).foregroundStyle(BrandColor.mute.color)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    chips(expanded: expanded)
                }
                Spacer(minLength: BrandSpacing.sm)
                approveControl(approved: approved)
            }
            if expanded { filesList.padding(.top, BrandSpacing.md) }
        }
        .padding(.vertical, BrandSpacing.md).padding(.trailing, BrandSpacing.md).padding(.leading, 18)
        .background(approved ? BrandColor.signal.color.opacity(0.05) : BrandColor.paper.color)
        .clipShape(RoundedRectangle(cornerRadius: BrandRadius.card))
        .overlay(RoundedRectangle(cornerRadius: BrandRadius.card).strokeBorder(BrandColor.mute.color.opacity(0.16)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: BrandRadius.card, bottomLeadingRadius: BrandRadius.card)
                .fill(approved ? BrandColor.signal.color : stripeColor).frame(width: 3)
        }
        .animation(BrandMotion.standard, value: approved)
    }

    // Chips: kind + the impact magnitude (green only when it's a real win) + files.
    // No repeated "needs sign-off" chip — the guarantee is stated once in the footer.
    private func chips(expanded: Bool) -> some View {
        HStack(spacing: 6) {
            chip(kindLabel, fg: BrandColor.inkDeep.color, bg: BrandColor.mute.color.opacity(0.08))
            impactChip
            if !rec.affectedPaths.isEmpty {
                Button(action: { withAnimation(BrandMotion.standard) { vm.toggleFiles(rec) } }) {
                    HStack(spacing: 3) {
                        Text("\(rec.affectedPaths.count) file\(rec.affectedPaths.count == 1 ? "" : "s")")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(BrandColor.mute.color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(BrandColor.paperWarm.color, in: RoundedRectangle(cornerRadius: BrandRadius.small))
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide affected files" : "Show affected files")
            }
        }
        .padding(.top, 9)
    }

    // Impact: a green chip when the win is real (any bytes pruned, or >= 10 lines);
    // otherwise a quiet mute magnitude so green is never spent on trivia.
    @ViewBuilder private var impactChip: some View {
        if rec.estBytesSaved > 0 {
            chip("saves \(humanBytes(rec.estBytesSaved))", fg: BrandColor.signal.color, bg: BrandColor.signal.color.opacity(0.10))
        } else if rec.estLinesSaved >= 10 {
            chip("saves ~\(rec.estLinesSaved) lines", fg: BrandColor.signal.color, bg: BrandColor.signal.color.opacity(0.10))
        } else if rec.estLinesSaved > 0 {
            Text("~\(rec.estLinesSaved) lines").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(BrandColor.mute.color)
        } else if let over = overBudget {
            Text(over).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(BrandColor.mute.color)
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(fg).padding(.horizontal, 7).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: BrandRadius.small))
    }

    // Approve = record sign-off. Approved state reads "Ready to apply" (undoable),
    // NOT "done" — nothing was edited. Only the top unresolved card is filled.
    @ViewBuilder private func approveControl(approved: Bool) -> some View {
        if approved {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(BrandColor.signal.color)
                    Text("Ready to apply").font(.system(size: 11, weight: .medium)).foregroundStyle(BrandColor.signal.color)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(BrandColor.signal.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Button("Undo") { withAnimation(BrandMotion.standard) { vm.undo(rec) } }
                    .buttonStyle(.plain).font(BrandFont.button).foregroundStyle(BrandColor.mute.color)
            }
        } else if isPrimary {
            Button(action: { withAnimation(BrandMotion.expressive) { vm.accept(rec) } }) {
                Text("Approve").font(BrandFont.button).foregroundStyle(BrandColor.paper.color)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(BrandColor.signal.color, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
        } else {
            Button(action: { withAnimation(BrandMotion.expressive) { vm.accept(rec) } }) {
                Text("Approve").font(BrandFont.button).foregroundStyle(BrandColor.signal.color)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(BrandColor.signal.color.opacity(0.4)))
            }.buttonStyle(.plain)
        }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(BrandColor.mute.color.opacity(0.14)).frame(height: BrandMetrics.hairline).padding(.bottom, 4)
            ForEach(Array(rec.affectedPaths.prefix(12).enumerated()), id: \.offset) { _, path in
                HStack(spacing: 7) {
                    Circle().fill(BrandColor.mute.color).frame(width: 4, height: 4)
                    Text(shorten(path)).font(BrandFont.monoSmall).foregroundStyle(BrandColor.inkDeep.color)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var kindLabel: String {
        switch rec.kind {
        case .extractShared: return "extract shared"
        case .merge: return "merge"
        case .prune: return "prune"
        case .link: return "link"
        case .split: return "split"
        case .schemaRule: return "convention"
        }
    }

    private var overBudget: String? {
        // For a split rec, surface the over-budget magnitude from the rationale
        // as a quiet, honest number rather than a green "win".
        guard rec.kind == .split else { return nil }
        return "over budget"
    }

    // Amber ONLY for a genuinely notable/major item; everything else a single quiet
    // mute (no illegible minor-vs-info opacity ramp).
    private var stripeColor: Color {
        switch rec.severity {
        case .major, .notable: return BrandColor.attention.color
        default:               return BrandColor.mute.color.opacity(0.45)
        }
    }

    private func humanBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let r = path.range(of: "/skills/") { return String(path[r.upperBound...]) }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Wiki topic row

struct WikiTopicRow: View {
    let topic: WikiTopic
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topic.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(BrandColor.ink.color)
                    .lineLimit(1).truncationMode(.tail)
                // Count badge: amber HUE via tint, but the label is ink (amber text
                // <14pt fails contrast).
                Text("\(topic.appearsIn.count) files").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BrandColor.inkDeep.color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(BrandColor.attention.color.opacity(0.16), in: RoundedRectangle(cornerRadius: BrandRadius.small))
            }
            Text(homesLine).font(BrandFont.monoSmall).foregroundStyle(BrandColor.mute.color)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, BrandSpacing.md)
        .overlay(alignment: .bottom) { Rectangle().fill(BrandColor.mute.color.opacity(0.12)).frame(height: BrandMetrics.hairline) }
    }
    private var homesLine: String {
        let base = { (p: String) in (p as NSString).lastPathComponent }
        let home = topic.canonicalHome.map(base) ?? "?"
        let others = topic.appearsIn.filter { $0 != topic.canonicalHome }.map(base)
        return "home \(home)" + (others.isEmpty ? "" : " · also in " + others.joined(separator: ", "))
    }
}

// MARK: - Schema rule row

struct SchemaRuleRow: View {
    let index: Int
    let rule: Recommendation
    var body: some View {
        HStack(alignment: .top, spacing: BrandSpacing.md) {
            Text("\(index)").font(.system(size: 12, weight: .semibold).monospaced()).foregroundStyle(BrandColor.signal.color).frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(BrandColor.ink.color)
                Text(rule.rationale).font(BrandFont.body).foregroundStyle(BrandColor.mute.color).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BrandSpacing.md)
        .overlay(alignment: .bottom) { Rectangle().fill(BrandColor.mute.color.opacity(0.12)).frame(height: BrandMetrics.hairline) }
    }
}

// MARK: - Mini pulse dot

struct PulseDotMini: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().fill(color).opacity(on ? 0.28 : 0.12).scaleEffect(on ? 2.1 : 1.4))
            .animation(BrandMotion.pulse, value: on)
            .onAppear { on = true }
    }
}
