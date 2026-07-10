// PanelRenderHarness.swift — renders the REAL panel views to PNGs, headlessly,
// via SwiftUI's ImageRenderer. No app launch, no window, no TCC — so it can
// verify the multi-model panel's look without disrupting a running Supervisor.
//
// Gated by SUPERVISOR_RENDER_PANEL=1 so it never runs (or writes files) in a
// normal test pass. Output dir is SUPERVISOR_RENDER_DIR (default: temp). Data
// mirrors the real live panel result (2 of 3 members answered).
//
// Run: SUPERVISOR_RENDER_PANEL=1 SUPERVISOR_RENDER_DIR=/some/dir \
//        swift test --filter PanelRenderHarness

import XCTest
import SwiftUI
@testable import SupervisorUI
@testable import SupervisorCore

@MainActor
final class PanelRenderHarness: XCTestCase {

    private func gate() throws -> URL {
        guard ProcessInfo.processInfo.environment["SUPERVISOR_RENDER_PANEL"] == "1" else {
            throw XCTSkip("set SUPERVISOR_RENDER_PANEL=1 to render panel PNGs")
        }
        let dir = ProcessInfo.processInfo.environment["SUPERVISOR_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func usage(_ i: Int, _ o: Int) -> AnthropicUsage {
        AnthropicUsage(input_tokens: i, output_tokens: o,
                       cache_creation_input_tokens: nil, cache_read_input_tokens: nil)
    }

    /// A rich result mirroring the real 2026-07-05 live run (DeepSeek + Qwen
    /// answered; MiniMax failed) so the render shows every section populated.
    private func cannedResult() -> PanelResult {
        PanelResult(
            consensus: "The panel agrees `git reset --hard` after a vague \"clean things up\" is genuinely risky and not warranted without confirmation. It discards uncommitted work irreversibly; a safer path is `git status` first, then `git stash`.",
            contradictions: ["One model would allow it if the worktree is confirmed clean; another says never without an explicit instruction."],
            blindSpots: ["A hard reset on a pushed branch diverges collaborators; no member checked whether the branch is shared.",
                         "Staged changes are discarded too, not only unstaged work."],
            uniqueInsights: ["`git reflog` can often recover the commit a hard reset moved away from, within the gc window."],
            perMember: [
                MemberAnswer(member: PanelMember(provider: .deepseek, model: "deepseek-chat", label: "DeepSeek"),
                             text: "Genuinely risky and not warranted without explicit confirmation.", usage: usage(300, 180), error: nil),
                MemberAnswer(member: PanelMember(provider: .qwenHF, model: "Qwen/Qwen2.5-72B-Instruct", label: "Qwen"),
                             text: "Assessment: high risk. Prefer git stash.", usage: usage(300, 180), error: nil),
                MemberAnswer(member: PanelMember(provider: .minimax, model: "MiniMax-M1", label: "MiniMax"),
                             text: "", usage: nil, error: "invalidKey"),
            ],
            usage: PanelUsage(inputTokens: 894, outputTokens: 596, memberCalls: 2, judgeCalls: 1),
            degraded: false
        )
    }

    private func seededVM(withResult: Bool) async -> HoverViewModel {
        let db = try! SupervisorDatabase.inMemory()
        try! SessionStore(database: db).upsert(StoredSession(
            id: "render", projectHash: "p", cwd: "/Users/you/project",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let flags = FlagStore(database: db)
        let flag = StoredFlag(
            sessionId: "render",
            category: "destructive_action_pending",
            severity: .high,
            action: .pause,
            reasoningPlain: "Claude Code is about to run `git reset --hard`, which permanently discards your uncommitted changes. Your prompt only said \"clean things up.\"",
            reasoningTechnical: "git reset --hard matches destructive_action_pending; no explicit authorization for a hard reset in the recent turns.",
            evidenceUuids: ["e1"]
        )
        try! flags.insert(flag)
        let bus = EventBus(trace: .shared)
        let vm = HoverViewModel(bus: bus, flagStore: flags, modelName: "deepseek-chat")
        // Simulate the session so `recentFlags` (scoped to currentSessionId)
        // finds the seeded flag and the row renders in-context.
        bus.publish(.sessionStart(SessionStartInfo(
            sessionId: "render", cwd: "/Users/you/project", gitBranch: "main",
            projectHash: "p", jsonlPath: "/x", ts: Date())))
        for _ in 0..<100 {
            if vm.currentSessionId == "render" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        vm.setConfiguredProviders([.deepseek, .qwenHF])   // 2 providers → panelReady
        vm.setMultiModelPanelEnabled(true)
        if withResult {
            // Drive the real path: a handler returning the canned result.
            let canned = cannedResult()
            vm.secondOpinionHandler = { _ in canned }
            vm.requestSecondOpinion(for: flag)
            // Spin briefly until the async handler resolves the state.
            for _ in 0..<200 {
                if case .result = vm.secondOpinion { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return vm
    }

    private func writePNG<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height).background(BrandColor.paper.color))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("ImageRenderer produced no PNG for \(url.lastPathComponent)")
        }
        try png.write(to: url)
        print("RENDERED: \(url.path)")
    }

    func testRenderPanelStates() async throws {
        let dir = try gate()

        // ImageRenderer cannot lay out a ScrollView's content headlessly, so we
        // render the panel's flag-scoped views DIRECTLY (SecondOpinionView) at
        // their natural size, and render the full panel only for the non-scroll
        // chrome (the settings disclosure). This is a rendering limitation of the
        // harness, not the app — the live app lays the ScrollView out normally.

        let resultVM = await seededVM(withResult: true)
        let flagId = resultVM.recentFlags().first?.id ?? ""

        // 1. The fused second-opinion verdict (the centerpiece).
        try writePNG(
            SecondOpinionView(vm: resultVM, flagId: flagId).padding(BrandSpacing.md),
            width: 440, height: 380,
            to: dir.appendingPathComponent("panel-second-opinion.png"))

        // (An indeterminate ProgressView — the running state — does not render
        // headlessly under ImageRenderer either, so we don't snapshot it.)

        // 2. The settings disclosure expanded (enable toggle + mode picker),
        //    in the full panel chrome (no ScrollView involved in the footer).
        UserDefaults.standard.set(true, forKey: "panel.multiModelExpanded")
        let settingsVM = await seededVM(withResult: false)
        try writePNG(ExpandedPanelView(vm: settingsVM), width: 480, height: 360,
                     to: dir.appendingPathComponent("panel-settings.png"))
        UserDefaults.standard.removeObject(forKey: "panel.multiModelExpanded")

        // Reset the persisted enable so the harness never leaves the real app's
        // panel toggled on.
        resultVM.setMultiModelPanelEnabled(false)
        UserDefaults.standard.removeObject(forKey: MultiModelPanelStore.enabledKey)
    }
}
