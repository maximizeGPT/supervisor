// ExpandedPanelView.swift
//
// 480x360 expanded panel that slides below the hover window on click.
//
// v0.2.0 M3 (Stitch): the panel is the live product surface. When the watched
// session has a plan, the panel shows the PLAN centerpiece (PlanView: objective
// + StatusChip, the ordered step list with the active step expanded to its
// done-criteria + boxed evaluator verdict, and a Pause / Approve plan footer).
// With no plan it shows the prior content, recent actions, flags, activity,
// owner controls, now restyled onto the brand tokens and primitives
// (BrandFont / BrandColor / BrandSectionHeader / SeverityBadge) instead of the
// old raw .system(size:) literals and inline severity-color ladder. The flag
// action buttons, resume, and owner toggles keep their existing behavior.

import SwiftUI
import SupervisorCore

public struct ExpandedPanelView: View {

    @ObservedObject var vm: HoverViewModel
    @State private var expandedFlagIds: Set<String> = []
    /// Whether the plan surface is showing the dark "plan detail" register
    /// (Stitch screen 2) instead of the compact light Plan (screen 1). Toggled
    /// by the Plan view's "Details" affordance and the detail view's "Back";
    /// panel-local state, so it resets when the panel closes/reopens.
    @State private var showingPlanDetail = false

    /// Fix-item #4b (operator feedback): when a plan exists the PLAN surface
    /// took over the whole panel with no way back to the normal Status control
    /// panel (flags / activity / controls). This panel-level toggle crosses
    /// between the two whenever a plan exists: false shows the plan surface (as
    /// before), true shows the statusSurface. A muted "Panel" affordance on the
    /// plan header sets it true; a "Back to plan" pill on the status surface
    /// sets it false. Panel-local, so it resets when the panel closes/reopens
    /// (acceptable: reopening lands on the plan, the centerpiece).
    @State private var showStatusPanel = false

    /// v0.2.0 observability (Reddit feedback D): which tab the no-plan status
    /// surface shows. `.status` is the prior panel (actions / flags / activity /
    /// controls) unchanged; `.activity` is the new per-action audit log + export.
    /// Panel-local so it resets when the panel closes/reopens; defaults to the
    /// prior content so nothing regresses for an existing user.
    @State private var statusTab: StatusTab = .status

    /// The registers of the no-plan status surface. `.review` (v0.3.x) is the
    /// code-review dimension's home — a pull surface for on-the-fly review
    /// observations, distinct from the safety-oriented Status + Activity tabs.
    private enum StatusTab: Hashable { case status, activity, review }

    /// Fix-queue #5 (panel cramping): the Status tab pins a single compact
    /// one-line status strip, lets ONLY the Flags list scroll and take all
    /// remaining height, and tucks the owner controls into two collapsible
    /// footer groups (Controls + Decision Sensitivity) that are collapsed by
    /// default so their space flows to the Flags list. Each group's open/closed
    /// state persists across panel opens via @AppStorage. The pattern follows
    /// Fantastical / Things / Raycast: one quiet context line up top, one
    /// scrolling body, collapsible secondary controls at the bottom.
    @AppStorage("panel.controlsExpanded") private var controlsExpanded = false
    @AppStorage("panel.sensitivityExpanded") private var sensitivityExpanded = false
    @AppStorage("panel.multiModelExpanded") private var multiModelExpanded = false

    /// Panel-local state for the "Add a provider key" mini-form inside the
    /// multi-model settings. Reset when the panel closes/reopens.
    @State private var showAddProvider = false
    @State private var addProviderSelection: LLMProvider = .deepseek
    @State private var addProviderKey = ""

    public init(vm: HoverViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Group {
            if let plan = vm.currentPlan() {
                // A plan exists: the panel crosses between the PLAN surface
                // (default) and the normal Status control panel via the
                // panel-level showStatusPanel toggle, so both are reachable in
                // both directions whenever the operator wants.
                if showStatusPanel {
                    statusSurface
                } else {
                    planSurface(plan)
                }
            } else {
                // No plan: the status surface is the only register, unchanged
                // (no cross-over chrome, since there is nothing to cross to).
                statusSurface
            }
        }
        .frame(width: 480, height: 360)
        .background(BrandColor.paper.color, in: RoundedRectangle(cornerRadius: BrandRadius.card))
    }

    /// Fix-item #4b: whether the status surface should show its "Back to plan"
    /// control. True only when a plan exists (so the cross-over is meaningful);
    /// when there is no plan the status surface is unchanged. A small computed
    /// seam so the rule is unit-testable without rendering layout.
    var showsBackToPlanControl: Bool {
        vm.currentPlan() != nil
    }

    // MARK: - Plan surface (v0.2.0 M3 centerpiece)

    /// The plan surface has two registers in the SAME panel: the compact light
    /// Plan (screen 1, with the Pause / Approve footer) and the dark plan-detail
    /// view (screen 2). `showingPlanDetail` swaps between them; the "Details"
    /// affordance enters and the detail view's "Back" exits, both animated on
    /// the standard motion so the register change reads as one calm transition.
    @ViewBuilder
    private func planSurface(_ plan: Plan) -> some View {
        if showingPlanDetail {
            ScrollView {
                PlanDetailView(
                    plan: plan,
                    isPaused: vm.supervisorPaused,
                    onBack: {
                        withAnimation(BrandMotion.standard) { showingPlanDetail = false }
                    }
                )
            }
            .background(BrandColor.ink.color)
        } else {
            compactPlanSurface(plan)
        }
    }

    private func compactPlanSurface(_ plan: Plan) -> some View {
        let planView = PlanView(
            plan: plan,
            // Fold the LIVE session pause/kill into the plan chip so a paused or
            // killed session never reads "Running" (RC fix #5). Global
            // supervisorPaused OR a live session pause both show "Paused".
            isPaused: vm.supervisorPaused || vm.isPaused,
            isStopped: vm.isKilled,
            approvedOptimistically: vm.approvedPlanIds.contains(plan.id),
            onApprove: { vm.approvePlan(planId: plan.id) },
            onPauseToggle: { vm.toggleSupervisorPaused() },
            onShowDetail: {
                withAnimation(BrandMotion.standard) { showingPlanDetail = true }
            },
            onShowPanel: {
                // Cross over to the normal Status control panel. Same calm
                // standard motion as the Details toggle so it reads as one
                // transition; "Back to plan" on the status surface returns.
                withAnimation(BrandMotion.standard) { showStatusPanel = true }
            }
        )
        return VStack(spacing: 0) {
            ScrollView { planView }
            Divider().overlay(BrandColor.mute.color.opacity(0.15))
            planView.footer
                .padding(.horizontal, BrandSpacing.lg)
                .padding(.vertical, BrandSpacing.md)
        }
    }

    // MARK: - Status surface (no active plan, the prior panel, retokenized)

    private var statusSurface: some View {
        VStack(spacing: 0) {
            // Fix-item #4b: a "Back to plan" row pinned above the header, shown
            // ONLY when a plan exists. It is the clear way back from the status
            // panel to the PLAN surface; with no plan it is absent, so the
            // status surface is exactly as before.
            if showsBackToPlanControl, let plan = vm.currentPlan() {
                backToPlanBar(plan)
                divider
            }
            header
            tabBar
            divider
            // The two registers share the panel below the header + tab bar. The
            // Status tab is the prior content (unchanged); the Activity tab is
            // the new audit log + export. Switching never touches the Plan
            // surface (that path is chosen above, before this view is built).
            switch statusTab {
            case .status:
                statusContent
            case .activity:
                AuditLogView(vm: vm)
            case .review:
                ReviewView(vm: vm)
            }
        }
    }

    /// Fix-item #4b: the "Back to plan" row at the top of the status surface,
    /// shown only when a plan exists. A muted leading chevron + "Back to plan"
    /// label (navigation chrome, no green) on the left, and the plan's live
    /// StatusChip on the right so the operator sees the plan's state at a glance
    /// while in the control panel. Tapping returns to the plan surface on the
    /// same calm standard motion as the cross-over the other way.
    private func backToPlanBar(_ plan: Plan) -> some View {
        Button {
            withAnimation(BrandMotion.standard) { showStatusPanel = false }
        } label: {
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Back to plan")
                    .font(BrandFont.note)
                Spacer()
                if vm.isKilled {
                    StatusChip(.stopped)
                } else if vm.supervisorPaused || vm.isPaused {
                    StatusChip(.paused)
                } else {
                    StatusChip(planStatus: plan.status)
                }
            }
            .foregroundStyle(BrandColor.mute.color)
            .contentShape(Rectangle())
            .padding(.horizontal, BrandSpacing.md)
            .padding(.vertical, BrandSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    /// The Status tab content, restructured (fix-queue #5, round 2) so the Flags
    /// list is the clearly dominant region. Two prior pinned blocks ("Current
    /// activity" multi-row + "Recent actions") were eating the height above the
    /// flags; now the only pinned context is a single compact one-line status
    /// strip, and "Recent actions" is gone (the Activity tab's AuditLogView
    /// already merges interventions + significant flags into the per-session
    /// timeline, so it was redundant here):
    ///
    ///   1. Pinned: a tiny one-line status strip (model / turns / tools, plus
    ///      "Now:" when present), ~one text line tall.
    ///   2. Scrolling middle: ONLY the Flags list, taking all remaining height
    ///      (.frame(maxHeight: .infinity)). With the footer groups collapsed
    ///      (the default) it fills essentially the whole panel below the strip.
    ///   3. Fixed footer: the owner controls, split into two collapsible groups
    ///      (Controls, Decision Sensitivity), collapsed by default and persisted
    ///      via @AppStorage, then the "N flags this session" footer at the very
    ///      bottom.
    private var statusContent: some View {
        VStack(spacing: 0) {
            // 1. Pinned top: one compact status line (does not scroll).
            statusStrip
            divider

            // 2. Scrolling middle: the Flags list AND the collapsible sections
            //    share ONE scroll. Previously the collapsible groups were fixed
            //    below a greedy flags list, so expanding several of them overflowed
            //    the 360pt panel and CLIPPED (no scroll) — unprofessional. Now the
            //    whole middle scrolls, so any combination of expanded sections is
            //    reachable. The ScrollView fills the middle, so a near-empty panel
            //    still reads normally (content at top) and a full one scrolls.
            ScrollView {
                VStack(spacing: 0) {
                    flagsSection
                    divider
                    controlsDisclosure
                    divider
                    sensitivityDisclosure
                    divider
                    panelDisclosure
                    contextHealthSection   // provides its own leading divider when wired
                }
            }
            .frame(maxHeight: .infinity)

            // 3. Pinned bottom: the flag count.
            divider
            footer
        }
    }

    /// The ambient Context Health line — its own quiet section (not a tab, so it
    /// never fights the Status/Activity/Review tabs). Renders only when the app
    /// wired a monitor; otherwise the whole feature stays inert. Its own axis:
    /// project context, not session state.
    @ViewBuilder private var contextHealthSection: some View {
        if let health = vm.contextHealth {
            divider
            ContextHealthSection(health: health, onOpen: vm.onOpenContextHealth)
        }
    }

    // MARK: - Multi-model panel section (opt-in, collapsible footer)

    /// The opt-in multi-model deliberation panel setting, in its own collapsible
    /// footer group (collapsed by default, persisted) to match Controls /
    /// Decision Sensitivity. Collapsed it's a single header row; expanded it
    /// reveals the on/off pill, a mode picker, and a plain-language cost note.
    /// Off by default, so nothing changes for an existing user until they opt in.
    private var panelDisclosure: some View {
        collapsibleSection(title: "Multi-model panel", isExpanded: $multiModelExpanded) {
            VStack(alignment: .leading, spacing: BrandSpacing.sm) {
                togglePill(
                    title: vm.multiModelPanelEnabled ? "Panel: on" : "Panel: off",
                    systemImage: vm.multiModelPanelEnabled ? "person.3.fill" : "person.3",
                    tint: vm.multiModelPanelEnabled ? BrandColor.signal.color : BrandColor.mute.color,
                    action: { vm.setMultiModelPanelEnabled(!vm.multiModelPanelEnabled) }
                )
                if vm.multiModelPanelEnabled {
                    HStack(spacing: BrandSpacing.xs) {
                        modePill(.diy, label: "Cross-provider")
                        modePill(.fusion, label: "OpenRouter Fusion")
                        Spacer()
                    }
                    Text(panelHint)
                        .font(BrandFont.note)
                        .foregroundStyle(BrandColor.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                    providersSubsection
                }
            }
            .padding(.horizontal, BrandSpacing.md)
            .padding(.bottom, BrandSpacing.sm)
        }
    }

    /// The provider-key manager inside the panel settings: which providers have
    /// a key, plus an "Add a provider key" mini-form so a user can enable the
    /// panel (which needs 2+ providers, or an OpenRouter key) without
    /// re-onboarding. Keys write to the same per-provider Keychain store triage
    /// uses, so `panelReady` and the "Second opinion" affordance flip on at once.
    private var providersSubsection: some View {
        let unconfigured = LLMProvider.allCases.filter { !vm.configuredProviders.contains($0) }
        return VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            Text(configuredProvidersLine)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .fixedSize(horizontal: false, vertical: true)

            if showAddProvider, !unconfigured.isEmpty {
                addProviderForm(unconfigured)
            } else if !unconfigured.isEmpty {
                Button {
                    addProviderSelection = unconfigured.first ?? .deepseek
                    withAnimation(BrandMotion.standard) { showAddProvider = true }
                } label: {
                    HStack(spacing: BrandSpacing.xxs) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Add a provider key")
                            .font(BrandFont.caption)
                    }
                    .foregroundStyle(BrandColor.signal.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var configuredProvidersLine: String {
        let cfg = vm.configuredProviders
        if cfg.isEmpty {
            return "No provider keys yet. Add two or more (or one OpenRouter key) to run a panel."
        }
        return "Configured: \(cfg.map { $0.displayName }.joined(separator: ", "))"
    }

    /// The inline add-key form: pick an un-keyed provider, paste its key, Save.
    /// The hover's expanded panel overrides `canBecomeKey`, so the SecureField
    /// takes input. No validation call here — a bad key just fails its panel
    /// member (the result shows "N of M answered"), matching the panel's
    /// fault-tolerance rather than blocking on a per-provider check.
    private func addProviderForm(_ unconfigured: [LLMProvider]) -> some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            Picker("", selection: $addProviderSelection) {
                ForEach(unconfigured, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(BrandColor.signal.color)
            .frame(maxWidth: 180, alignment: .leading)

            SecureField(addProviderSelection.keyPlaceholder, text: $addProviderKey)
                .textFieldStyle(.roundedBorder)
                .font(BrandFont.note)

            HStack(spacing: BrandSpacing.sm) {
                Button {
                    // Honest save flow: keep the form (and the typed key) until
                    // the save actually succeeds. The old flow cleared + closed
                    // here, silently claiming success before — and regardless
                    // of — the Keychain write's outcome.
                    vm.addProviderKey(addProviderSelection, key: addProviderKey)
                } label: {
                    Text(vm.isSavingProviderKey ? "Saving\u{2026}" : "Save")
                        .font(BrandFont.caption)
                        .foregroundStyle(BrandColor.paper.color)
                        .padding(.horizontal, BrandSpacing.sm)
                        .padding(.vertical, BrandSpacing.xxs)
                        .background(
                            BrandColor.signal.color.opacity(addProviderKey.isEmpty ? 0.4 : 1.0),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(addProviderKey.isEmpty || vm.isSavingProviderKey)

                Button("Cancel") {
                    addProviderKey = ""
                    withAnimation(BrandMotion.standard) { showAddProvider = false }
                }
                .buttonStyle(.plain)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
            }

            // The Keychain write failed: say so, in the one calm attention tone.
            // The key stays in the field so the user can retry without re-pasting.
            if let saveError = vm.providerKeySaveError {
                Text(saveError)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: vm.isSavingProviderKey) { saving in
            // Close the form only on a CONFIRMED save (finished + no error).
            if !saving, vm.providerKeySaveError == nil {
                addProviderKey = ""
                withAnimation(BrandMotion.standard) { showAddProvider = false }
            }
        }
    }

    /// A mode-selector pill (DIY vs Fusion). The selected one carries the calm
    /// signal-green tinted-chip treatment; the other stays a neutral outline —
    /// the same one-accent discipline the rest of the panel uses.
    private func modePill(_ mode: PanelMode, label: String) -> some View {
        let selected = vm.panelMode == mode
        return Button(action: { vm.setPanelMode(mode) }) {
            Text(label)
                .font(BrandFont.note)
                .foregroundStyle(selected ? BrandColor.ink.color : BrandColor.mute.color)
                .padding(.horizontal, BrandSpacing.sm)
                .padding(.vertical, BrandSpacing.xxs)
                .background(
                    selected ? BrandColor.signal.color.opacity(0.12) : BrandColor.paper.color,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        selected ? BrandColor.signal.color.opacity(0.3) : BrandColor.mute.color.opacity(0.2),
                        lineWidth: BrandMetrics.hairline
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// One-line, plain-language guidance under the mode picker: what to add when
    /// the selected mode isn't runnable, or the cost reality when it is.
    private var panelHint: String {
        if !vm.panelReady {
            return vm.panelMode == .fusion
                ? "Add an OpenRouter key to use Fusion."
                : "Add at least two provider keys to run a cross-provider panel."
        }
        return "A panel asks several models plus a judge (about 4-5x a single call). Use it on decisions worth the cost."
    }

    /// The small two-tab switcher (Status / Activity) for the no-plan surface.
    /// Token-styled in the same quiet vocabulary as the controls: a tracked
    /// caption label with the selected tab carrying the one signal-green accent
    /// (an underline + on-tone label), the others muted. Activity shows a small
    /// count when there are logged decisions.
    private var tabBar: some View {
        HStack(spacing: BrandSpacing.lg) {
            tab("Status", tag: .status, count: nil)
            tab("Activity", tag: .activity, count: vm.activityCount())
            tab("Review", tag: .review, count: vm.reviewCount())
            Spacer()
        }
        .padding(.horizontal, BrandSpacing.md)
        .padding(.bottom, BrandSpacing.xs)
    }

    private func tab(_ title: String, tag: StatusTab, count: Int?) -> some View {
        let selected = statusTab == tag
        return Button(action: { withAnimation(BrandMotion.standard) { statusTab = tag } }) {
            VStack(spacing: BrandSpacing.xxs) {
                HStack(spacing: BrandSpacing.xxs) {
                    Text(title)
                        .font(BrandFont.caption)
                        .tracking(0.4)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(BrandFont.monoSmall)
                    }
                }
                .foregroundStyle(selected ? BrandColor.ink.color : BrandColor.mute.color)
                Rectangle()
                    .fill(selected ? BrandColor.signal.color : Color.clear)
                    .frame(height: BrandMetrics.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Divider().overlay(BrandColor.mute.color.opacity(0.15))
    }

    // MARK: - Controls section (owner runtime toggles, collapsible footer)

    /// Fix-queue #5: the owner pause/resume + 4h-cap toggles, now living in a
    /// collapsible footer group (collapsed by default, persisted). Collapsed,
    /// it is a single tappable header row, so its space reclaims to the Flags
    /// list above; expanded, it reveals the toggle pills exactly as before.
    private var controlsDisclosure: some View {
        collapsibleSection(title: "Controls", isExpanded: $controlsExpanded) {
            HStack(spacing: BrandSpacing.sm) {
                // Global pause / resume, Supervisor goes dormant (no triage,
                // dispatch, or inject) until resumed. Resume reads in signal
                // (the way back to live); pausing reads in the calm amber
                // attention tone (a held, not-live state).
                togglePill(
                    title: vm.supervisorPaused ? "Resume Supervisor" : "Pause Supervisor",
                    systemImage: vm.supervisorPaused ? "play.fill" : "pause.fill",
                    tint: vm.supervisorPaused ? BrandColor.signal.color : BrandColor.attention.color,
                    action: { vm.toggleSupervisorPaused() }
                )

                // 4-hour loop cap on / off. "Off" (uncapped) is an attention
                // state; the default capped state is a quiet neutral.
                togglePill(
                    title: vm.loopCapDisabled ? "4h cap: off" : "4h cap: on",
                    systemImage: vm.loopCapDisabled ? "infinity" : "timer",
                    tint: vm.loopCapDisabled ? BrandColor.attention.color : BrandColor.mute.color,
                    action: { vm.toggleLoopCapDisabled() }
                )
                Spacer()
            }
            .padding(.horizontal, BrandSpacing.md)
            .padding(.bottom, BrandSpacing.sm)
        }
    }

    /// Fix-queue #5: the decision-sensitivity dial, in its own collapsible
    /// footer group (collapsed by default, persisted). The dial itself is
    /// unchanged; it is only tucked behind a disclosure so its height reclaims
    /// to the Flags list when the owner is not adjusting it.
    private var sensitivityDisclosure: some View {
        collapsibleSection(title: "Decision Sensitivity", isExpanded: $sensitivityExpanded) {
            // v0.2.0 (Reddit feedback E): the decision-sensitivity dial - how
            // aggressively Supervisor acts vs. asks. Token-styled segmented
            // control with a one-line description; default Balanced == today.
            SensitivityControl(vm: vm)
                .padding(.horizontal, BrandSpacing.md)
                .padding(.bottom, BrandSpacing.sm)
        }
    }

    /// A collapsible footer group in the panel's quiet section vocabulary. The
    /// header row is a tappable BrandSectionHeader plus a chevron that rotates
    /// on the standard motion; tapping toggles the bound @AppStorage flag so
    /// the open/closed state persists across panel opens. We use a custom row
    /// rather than a raw DisclosureGroup so the chrome matches the brand tokens
    /// instead of the chunky default macOS triangle.
    @ViewBuilder
    private func collapsibleSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            Button {
                withAnimation(BrandMotion.standard) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: BrandSpacing.xs) {
                    BrandSectionHeader(title)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BrandColor.mute.color)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, BrandSpacing.md)
                .padding(.vertical, BrandSpacing.sm)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// A compact owner-control toggle pill, token-driven so the controls row
    /// reads as part of the instrument panel rather than default macOS
    /// bordered chrome. The `tint` is a low-opacity fill + solid label/glyph,
    /// the same tinted-chip vocabulary the severity badge and status chip use.
    private func togglePill(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: BrandSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(BrandFont.note)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, BrandSpacing.sm)
            .padding(.vertical, BrandSpacing.xs)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.25), lineWidth: BrandMetrics.hairline)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: BrandSpacing.xs) {
            Text("Supervisor")
                .font(BrandFont.title)
                .foregroundStyle(BrandColor.ink.color)
            Text("\u{25B8}")
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
            Text(vm.sessionCwd.isEmpty ? "no session" : vm.sessionCwd)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, BrandSpacing.md)
        .padding(.vertical, BrandSpacing.sm)
    }

    // MARK: - Flags section

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xs) {
            BrandSectionHeader("Flags")
                .padding(.horizontal, BrandSpacing.md)
                .padding(.top, BrandSpacing.sm)

            let flags = vm.recentFlags(limit: 5)
            if flags.isEmpty {
                Text("No flags this session")
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .padding(.horizontal, BrandSpacing.md)
                    .padding(.vertical, BrandSpacing.sm)
            } else {
                // No inner ScrollView here: statusContent now wraps the whole
                // middle (flags + the collapsible sections) in ONE scroll, so a
                // nested vertical scroll would fight the outer one. The flags just
                // render as a list and scroll with everything else.
                VStack(spacing: BrandSpacing.xs) {
                    ForEach(flags, id: \.id) { flag in
                        flagRow(flag)
                    }
                }
                .padding(.horizontal, BrandSpacing.md)
                .padding(.bottom, BrandSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flagRow(_ flag: StoredFlag) -> some View {
        let isExpanded = expandedFlagIds.contains(flag.id)

        return VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
            // Header row, always visible, clickable to toggle.
            HStack {
                SeverityBadge(flag.severity)
                Text(flag.category.replacingOccurrences(of: "_", with: " "))
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.ink.color)
                    .lineLimit(1)
                Spacer()
                Text(Self.relativeTime(flag.ts))
                    .font(BrandFont.monoSmall)
                    .foregroundStyle(BrandColor.mute.color)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(BrandColor.mute.color)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(BrandMotion.standard) {
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
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .lineLimit(2)
            }

            // Expanded: full reasoning + technical + asymmetry note.
            if isExpanded {
                VStack(alignment: .leading, spacing: BrandSpacing.xs) {
                    Text(flag.reasoningPlain)
                        .font(BrandFont.note)
                        .foregroundStyle(BrandColor.mute.color)

                    if !flag.reasoningTechnical.isEmpty {
                        Text("Technical:")
                            .font(BrandFont.caption)
                            .foregroundStyle(BrandColor.mute.color)
                        Text(flag.reasoningTechnical)
                            .font(BrandFont.note)
                            .foregroundStyle(BrandColor.mute.color)
                    }

                    if let note = flag.asymmetryNote, !note.isEmpty {
                        Text("Asymmetry:")
                            .font(BrandFont.caption)
                            .foregroundStyle(BrandColor.mute.color)
                        Text(note)
                            .font(BrandFont.note)
                            .foregroundStyle(BrandColor.mute.color)
                    }

                    // Action + severity details.
                    HStack(spacing: BrandSpacing.sm) {
                        Text("Action: \(flag.action.rawValue)")
                            .font(BrandFont.note)
                            .foregroundStyle(BrandColor.mute.color)
                        Text("Severity: \(flag.severity.rawValue)")
                            .font(BrandFont.note)
                            .foregroundStyle(BrandColor.mute.color)
                    }
                }
                .padding(.top, BrandSpacing.xxs)
            }

            // Action buttons. Only show if the user hasn't responded yet.
            // Override is the primary control: a real bordered button in
            // the brand signal color, not bare red text. It's a normal
            // human override, not a destructive action, so it must not
            // read as alarm-red. Dismiss and False positive stay as quiet
            // text actions so Override is clearly the prominent one.
            if flag.userResponse == nil {
                HStack(spacing: BrandSpacing.sm) {
                    // Override is the prominent control, a normal human
                    // override, not a destructive action, so it carries the
                    // one signal-green accent as a tinted pill (the same chip
                    // vocabulary as the controls / status chip), never an
                    // alarm-red. Dismiss / False positive stay quiet text
                    // actions so Override clearly leads.
                    Button {
                        vm.rejectFlag(flagId: flag.id, action: flag.action)
                    } label: {
                        Text("Override")
                            .font(BrandFont.caption)
                            .foregroundStyle(BrandColor.signal.color)
                            .padding(.horizontal, BrandSpacing.sm)
                            .padding(.vertical, BrandSpacing.xxs)
                            .background(BrandColor.signal.color.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    BrandColor.signal.color.opacity(0.3),
                                    lineWidth: BrandMetrics.hairline
                                )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(overrideHelp(flag))

                    Button("Dismiss") {
                        vm.respondToFlag(flagId: flag.id, response: .dismissed)
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)

                    Button("False positive") {
                        vm.respondToFlag(flagId: flag.id, response: .falsePositive)
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                }
                .padding(.top, BrandSpacing.xxs)
            } else {
                Text(Self.responseLabel(flag.userResponse!))
                    .font(BrandFont.note)
                    .foregroundStyle(BrandColor.mute.color)
                    .padding(.top, BrandSpacing.xxs)
            }

            // Multi-model panel: an opt-in "Second opinion" on this flag. Shows
            // only when the owner enabled the panel and it's runnable, and only
            // while no request for THIS flag is already in flight or shown (the
            // inline result below carries its own dismiss). A quiet neutral pill,
            // not the one green accent — that's reserved for Override + consensus.
            if vm.multiModelPanelEnabled, vm.panelReady, vm.secondOpinion.flagId != flag.id, !vm.secondOpinionInFlight {
                Button {
                    withAnimation(BrandMotion.standard) { vm.requestSecondOpinion(for: flag) }
                } label: {
                    HStack(spacing: BrandSpacing.xxs) {
                        Image(systemName: "person.3")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Second opinion")
                            .font(BrandFont.caption)
                    }
                    .foregroundStyle(BrandColor.mute.color)
                    .padding(.horizontal, BrandSpacing.sm)
                    .padding(.vertical, BrandSpacing.xxs)
                    .background(BrandColor.paper.color, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(BrandColor.mute.color.opacity(0.25), lineWidth: BrandMetrics.hairline)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Ask a panel of models for an independent read on this flag. Bills every panel member plus a judge.")
                .padding(.top, BrandSpacing.xxs)
            }

            SecondOpinionView(vm: vm, flagId: flag.id)
        }
        .padding(BrandSpacing.sm)
        // Match the Plan card's surface vocabulary: warm-paper fill, control
        // radius, a hairline rule. A flag row reads as a small card on the
        // panel, the same flat fill+hairline treatment used everywhere, not a
        // borderless tinted block.
        .background(
            BrandColor.paperWarm.color,
            in: RoundedRectangle(cornerRadius: BrandRadius.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BrandRadius.control)
                .strokeBorder(BrandColor.mute.color.opacity(0.15), lineWidth: BrandMetrics.hairline)
        )
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

    // MARK: - Status strip (compact one-line activity context)

    /// Fix-queue #5 (round 2): the prior multi-row "Current activity" section
    /// was eating height above the Flags list. It is now a single compact,
    /// muted one-line status strip: "<model> / <turns> turns / <tools> tools"
    /// plus " / Now: <detailLabel>" truncated to one line when present. It drops
    /// the BrandSectionHeader and the multi-row layout, so it costs ~one text
    /// line of height and the Flags list dominates. The Resume control stays
    /// reachable: when (and only when) the session is paused it renders inline
    /// trailing on the same row, so it adds no height in the common not-paused
    /// case.
    private var statusStrip: some View {
        HStack(spacing: BrandSpacing.xs) {
            // Which agent this session belongs to — leads the context line, but
            // only when more than one agent kind is being watched.
            if vm.isMultiAgent {
                AgentBadge(vm.currentAgent)
            }
            Text(statusStripText)
                .font(BrandFont.note)
                .foregroundStyle(BrandColor.mute.color)
                .lineLimit(1)
                .truncationMode(.tail)

            if vm.isPaused {
                Spacer(minLength: BrandSpacing.xs)
                resumeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrandSpacing.md)
        .padding(.vertical, BrandSpacing.xs)
    }

    /// The one-line status text. Model is included only when known; the "Now:"
    /// clause is appended only when there is a live detail label. Uses a middot
    /// separator to match the panel's quiet status vocabulary. No em dashes.
    private var statusStripText: String {
        var parts: [String] = []
        if !vm.modelName.isEmpty {
            parts.append(vm.modelName)
        }
        parts.append("\(vm.turnCount) turns")
        parts.append("\(vm.toolCallCount) tools")
        var line = parts.joined(separator: " \u{00B7} ")
        if !vm.detailLabel.isEmpty {
            line += " \u{00B7} Now: \(vm.detailLabel)"
        }
        return line
    }

    /// The compact Resume control, shown inline on the status strip only while
    /// the session is paused. Resuming Claude Code is a real green primary
    /// action (the way back to live), so it carries the one signal-green fill
    /// with a paper label. Fades while in flight.
    private var resumeButton: some View {
        Button(action: { vm.resumePausedSession() }) {
            HStack(spacing: BrandSpacing.xs) {
                if vm.isResuming {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BrandColor.paper.color)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                }
                Text(vm.isResuming ? "Resuming..." : "Resume")
                    .font(BrandFont.button)
            }
            .foregroundStyle(BrandColor.paper.color)
            .padding(.horizontal, BrandSpacing.sm)
            .padding(.vertical, BrandSpacing.xxs)
            .background(BrandColor.signal.color.opacity(vm.isResuming ? 0.4 : 1.0))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isResuming)
        .fixedSize()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            // `flagsThisRunCount()` reads FlagStore's current-work-window scope
            // live, so "this run" matches its label. (The old `flagCount` is a
            // process-lifetime counter seeded at launch and bumped on every
            // session's flag, so it drifted — showed 22 for a ~3-flag window.)
            // The per-session list above is separately scoped.
            let flagsThisRun = vm.flagsThisRunCount()
            Text("\(flagsThisRun) \(flagsThisRun == 1 ? "flag" : "flags") this run")
                .font(BrandFont.monoSmall)
                .foregroundStyle(BrandColor.mute.color)
            Spacer()
        }
        .padding(.vertical, BrandSpacing.sm)
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

// MARK: - Context Health section

/// The ambient Context Health line: a single quiet, tappable row under a
/// CONTEXT HEALTH overline, in the panel's existing section grammar. Calm and
/// mute when the context is lean (green is the sole brand accent and this
/// non-event doesn't earn it); a single STATIC amber cue only at notable+.
/// Tapping opens the full window. Re-audits on appear only when the context
/// changed, so it never shows a stale "lean".
struct ContextHealthSection: View {
    @ObservedObject var health: ContextHealthMonitor
    let onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: BrandSpacing.xxs) {
            BrandSectionHeader("Context Health")
                .padding(.horizontal, BrandSpacing.md)
                .padding(.top, BrandSpacing.sm)
            Button { onOpen?() } label: { row }
                .buttonStyle(.plain)
        }
        .onAppear { health.refreshIfNeeded() }
    }

    private var row: some View {
        HStack(spacing: BrandSpacing.sm) {
            Image(systemName: "leaf")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isNotable ? BrandColor.attention.color : BrandColor.mute.color)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(BrandFont.body).foregroundStyle(BrandColor.ink.color)
                if let sub { Text(sub).font(BrandFont.note).foregroundStyle(BrandColor.mute.color) }
            }
            Spacer(minLength: BrandSpacing.sm)
            if isNotable {
                Circle().fill(BrandColor.attention.color).frame(width: 6, height: 6)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BrandColor.mute.color)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, BrandSpacing.md)
        .padding(.vertical, BrandSpacing.xs)
    }

    private var isNotable: Bool {
        if case .cleanups(_, _, let n) = health.state { return n }
        return false
    }

    private var headline: String {
        switch health.state {
        case .unknown, .checking:
            return "Checking your context…"
        case .lean:
            return "Context is lean"
        case .cleanups(let count, _, let notable):
            let s = count == 1 ? "" : "s"
            return notable ? "\(count) cleanup\(s)" : "\(count) small cleanup\(s)"
        }
    }

    private var sub: String? {
        switch health.state {
        case .unknown, .checking:
            return nil
        case .lean:
            return health.lastAuditAt.map { "checked \(Self.ago($0)), nothing to clean up" } ?? "nothing to clean up"
        case .cleanups(_, let lines, _):
            return lines > 0 ? "~\(lines) reclaimable lines" : "worth a look"
        }
    }

    private static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
