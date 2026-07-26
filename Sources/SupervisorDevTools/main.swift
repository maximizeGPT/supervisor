// SupervisorDevTools — small CLI utility for Checkpoint C smoke testing.
//
// Subcommands:
//   inject-key <key>           Write key (argv form — leaks key into shell history
//                               and into Supervisor's own observation of the bash
//                               command. Useful for placeholder smoke only).
//   inject-key-from-env        Read $ANTHROPIC_API_KEY and write to Keychain.
//                               Use with ANTHROPIC_API_KEY=$(cat /tmp/sk.txt) ...
//                               so the literal command in shell history / Bash
//                               tool_use logs never contains the key.
//   delete-key                 Remove the entry.
//   show                       Print whether a key is present.
//   seed-offsets-eof <dir>     For every *.jsonl under <dir>/*/*.jsonl,
//                               insert a session row with jsonl_offset =
//                               current file size. Stops a fresh Supervisor
//                               from replaying 40 MB of historical events
//                               through Haiku on first start.

import AppKit
import Foundation
import SupervisorCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: SupervisorDevTools <subcommand>")
    print("  keys:      inject-key KEY | inject-key-from-env | delete-key | show")
    print("  sessions:  seed-offsets-eof DIR | locate-session | inject-test")
    print("  desktop:   desktop-target | desktop-ocr-dump | desktop-title | ocr-dump | match-test | composer-probe | composer-focus-test | scroll-test")
    print("  analysis:  context-wiki ROOT | second-brain ROOT | trust-scorecard [--since DAYS]")
    exit(2)
}

// KeychainAPIKeyStore.defaultService honors $SUPERVISOR_KEYCHAIN_PREFIX (the
// E2E isolation seam), so running these commands with the prefix exported
// operates on the TEST-namespaced items, never the live ones. Echo the
// service in every keychain command's output so which namespace was touched
// is always visible in the transcript.
let store = KeychainAPIKeyStore()
let keychainServiceLabel = KeychainAPIKeyStore.defaultService

switch args[1] {
case "inject-key":
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools inject-key <key>")
        exit(2)
    }
    do {
        try store.write(args[2])
        print("ok: key written (len=\(args[2].count)) service=\(keychainServiceLabel)")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "inject-key-from-env":
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        print("ERROR: ANTHROPIC_API_KEY not set")
        exit(2)
    }
    do {
        try store.write(key)
        print("ok: key from env written (len=\(key.count)) service=\(keychainServiceLabel)")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "delete-key":
    do { try store.delete(); print("ok: deleted service=\(keychainServiceLabel)") }
    catch { print("ERROR: \(error)"); exit(1) }
case "show":
    do {
        if let k = try store.read() {
            print("present (len=\(k.count)) service=\(keychainServiceLabel)")
        } else {
            print("absent service=\(keychainServiceLabel)")
        }
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "seed-offsets-eof":
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools seed-offsets-eof <claude-projects-dir>")
        exit(2)
    }
    let projectsDir = URL(fileURLWithPath: args[2], isDirectory: true)
    let paths = ConfigPaths()
    do { try paths.ensureDirectoriesExist() } catch { print("ERROR mkdir: \(error)"); exit(1) }
    let db: SupervisorDatabase
    do { db = try SupervisorDatabase(path: paths.databasePath) }
    catch { print("ERROR db open: \(error)"); exit(1) }
    let sessions = SessionStore(database: db)
    var seeded = 0
    let fm = FileManager.default
    guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
        print("ERROR: no projects dir at \(projectsDir.path)")
        exit(1)
    }
    for dir in projectDirs {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
        for entry in entries where entry.pathExtension == "jsonl" {
            let sessionId = entry.deletingPathExtension().lastPathComponent
            let projectHash = dir.lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: entry.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            do {
                try sessions.upsert(StoredSession(
                    id: sessionId,
                    projectHash: projectHash,
                    cwd: "/Users/main",
                    startedAt: Date(),
                    lastSeenAt: Date(),
                    jsonlPath: entry.path,
                    jsonlOffset: size
                ))
                seeded += 1
            } catch {
                print("WARN failed to seed \(sessionId): \(error)")
            }
        }
    }
    print("ok: seeded \(seeded) sessions at EOF")
case "inject-test":
    // Drive the REAL CGEventInjector against a target pid so the targeting
    // fix can be verified on screen: with a different app frontmost, the text
    // must land in the host of <pid>, never the frontmost app.
    guard args.count >= 4, let pid = Int32(args[2]) else {
        print("usage: SupervisorDevTools inject-test <host-pid> <text>")
        exit(2)
    }
    let text = args[3]
    let sem = DispatchSemaphore(value: 0)
    // `result` is written on @MainActor and read here after sem.signal();
    // the semaphore is the happens-before edge. Using a reference box instead
    // of a captured `var` keeps this concurrency-clean — strict concurrency
    // (Swift 6, which CI's toolchain enforces) rejects mutating a captured var
    // from concurrently-executing code. Local `swift test` never caught it
    // because it doesn't build this dev-tools target.
    final class ResultBox: @unchecked Sendable { var value = "ERROR: did not run" }
    let result = ResultBox()
    Task { @MainActor in
        let injector = CGEventInjector()
        do {
            let n = try await injector.inject(text: text, claudeCodePID: pid, targetWindowTitle: (args.count >= 5 ? args[4] : nil))
            result.value = "ok: injected \(n) bytes targeting host of pid \(pid)"
        } catch {
            result.value = "degraded/threw: \(error)"
        }
        sem.signal()
    }
    // Pump the main run loop so the @MainActor inject can progress without
    // deadlocking on a blocking wait.
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    print(result.value)
case "locate-session":
    // Diagnostic: run the app's REAL locator against a live session id (and
    // optionally a cwd) so we can characterize the session→process mapping
    // without a sandbox in the way. Prints the resolved pid/cwd/exec.
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools locate-session <session-id> [target-cwd]")
        exit(2)
    }
    let sid = args[2]
    let locator = LiveProcessLocator(execNamePatterns: ["claude", "claude-code"])
    if let h = locator.locate(bySessionId: sid) {
        print("bySessionId(\(sid)) -> FOUND pid=\(h.pid) cwd=\(h.cwd) exec=\(h.execPath)")
    } else {
        print("bySessionId(\(sid)) -> nil (not_found/ambiguous — see trace)")
    }
    if args.count >= 4 {
        let cwd = args[3]
        if let h = locator.locate(targetCwd: cwd) {
            print("byCwd(\(cwd)) -> FOUND pid=\(h.pid) cwd=\(h.cwd) exec=\(h.execPath)")
        } else {
            print("byCwd(\(cwd)) -> nil")
        }
    }
case "desktop-target":
    // Drive the real DesktopConversationTargeter: screenshot -> OCR -> match ->
    // click -> verify, for a conversation title. Prints the outcome so the
    // screenshot+OCR+click pipeline can be verified on screen.
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools desktop-target <conversation-title>")
        exit(2)
    }
    let title = args[2]
    let targeter = DesktopConversationTargeter()
    print("screen-recording granted: \(DesktopConversationTargeter.hasScreenRecordingPermission())")
    let outcome = targeter.focusConversation(targetTitle: title)
    print("outcome: \(outcome)")
case "desktop-ocr-dump":
    // READ-ONLY diagnostic: screenshot -> OCR -> print exactly what the targeter
    // sees (visible per-pane title strips, sidebar candidates). Does NOT
    // activate/click, so it's safe against a live multi-pane layout.
    let t = DesktopConversationTargeter()
    print("screen-recording granted: \(DesktopConversationTargeter.hasScreenRecordingPermission())")
    guard let img = t.captureMainDisplay() else { print("capture_failed"); exit(1) }
    let rows = t.recognizeRows(in: img)
    let titles = t.visibleConversationTitles(from: rows)
    let cands = t.sidebarCandidates(from: rows)
    print("OCR rows total: \(rows.count)")
    print("visibleConversationTitles (windows=\(titles.count)):")
    for (i, ti) in titles.enumerated() { print("  [\(i)] \"\(ti)\"") }
    print("raw rows containing ' / ' in top 80px (title-strip candidates):")
    for r in rows where r.point.y < 80 && r.text.contains(" / ") {
        print("  x=\(Int(r.point.x)) y=\(Int(r.point.y)) \"\(r.text)\"")
    }
    print("sidebarCandidates (\(cands.count)):")
    for c in cands.prefix(24) { print("  x=\(Int(c.point.x)) y=\(Int(c.point.y)) \"\(c.text)\"") }
case "match-test":
    // Verify the Path B LLM conversation matcher against real titles, using
    // the user's CONFIGURED provider + key (same path the app uses), so the
    // live failing case can be checked without rebuilding the app:
    //   SupervisorDevTools match-test "<target>" "<candidate0>" "<candidate1>" ...
    guard args.count >= 4 else {
        print("usage: SupervisorDevTools match-test <target-title> <candidate> [candidate...]")
        exit(2)
    }
    let target = args[2]
    let candidates = args[3...].map { DesktopConversationCandidate(text: $0, point: .zero) }
    let paths = ConfigPaths()
    let provider = (try? FileActiveProviderStore(path: paths.activeProviderPath).read()) ?? .anthropic
    guard let key = ((try? KeychainProviderKeyStore().read(provider)) ?? nil), !key.isEmpty else {
        print("ERROR: no API key for active provider \(provider.rawValue)")
        exit(1)
    }
    let client = LLMClient(provider: provider, apiKey: key, redactor: DefaultRedactor(), traceLog: .shared)
    print("provider=\(provider.rawValue) model=\(provider.defaultTriageModel)")
    print("target: \"\(target)\"")
    for (i, c) in candidates.enumerated() { print("  [\(i)] \"\(c.text)\"") }
    // match() blocks on a semaphore while a detached Task runs the LLM call on
    // the cooperative pool (off this thread), so calling it directly is fine.
    let matcher = LLMConversationMatcher(client: client)
    if let (cand, conf) = matcher.match(target: target, candidates: candidates) {
        let idx = candidates.firstIndex(of: cand) ?? -1
        let verdict = conf >= 0.6 ? "WOULD SWITCH (>= 0.6 gate)" : "below 0.6: would NOT switch (degrade to notify)"
        print("MATCH idx=\(idx) conf=\(String(format: "%.2f", conf)) title=\"\(cand.text)\" -> \(verdict)")
    } else {
        print("nil (LLM failure; the injector would fall back to the local matcher)")
    }
case "ocr-dump":
    // Read-only: activate Claude (as the real targeter does before capturing),
    // screenshot, run the REAL OCR + extraction heuristics, and print every row
    // with its position so the sidebar / active-title heuristics can be fixed
    // against the actual on-screen layout. No click, no inject.
    if let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
        claude.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.7)
    } else {
        print("WARN: Claude desktop not running — capturing whatever is frontmost")
    }
    let targeter = DesktopConversationTargeter()
    print("screen-recording granted: \(DesktopConversationTargeter.hasScreenRecordingPermission())")
    guard let img = targeter.captureMainDisplay() else { print("CAPTURE FAILED"); exit(1) }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let rows = targeter.recognizeRows(in: img)
    print("screen \(Int(bounds.width))x\(Int(bounds.height)), \(rows.count) OCR rows (top->bottom; L=left30% T=top5.5%):")
    for r in rows.sorted(by: { $0.point.y < $1.point.y }) {
        let l = r.point.x < bounds.width * 0.30 ? "L" : "-"
        let t = r.point.y < bounds.height * 0.055 ? "T" : "-"
        let txt = r.text.count > 78 ? String(r.text.prefix(78)) + "…" : r.text
        print(String(format: "  [%4d,%4d] %@%@ | %@", Int(r.point.x), Int(r.point.y), l, t, txt))
    }
    print("--- sidebarCandidates() -> \(targeter.sidebarCandidates(from: rows).count): ---")
    for c in targeter.sidebarCandidates(from: rows) { print("    @[\(Int(c.point.x)),\(Int(c.point.y))] \"\(c.text)\"") }
    print("--- visibleConversationTitles() -> \(targeter.visibleConversationTitles(from: rows))")
    print("--- activeConversationTitle() -> \(targeter.activeConversationTitle(from: rows).map { "\"\($0)\"" } ?? "nil")")
case "composer-probe":
    // Read-only: activate Claude, screenshot, and report WHERE composerPoint
    // would click to focus the composer — WITHOUT clicking or typing. Verifies
    // the Piece-1 locator against the live screen before any paste touches it.
    if let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
        claude.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.7)
    } else {
        print("WARN: Claude desktop not running — capturing whatever is frontmost")
    }
    let targeter = DesktopConversationTargeter()
    print("screen-recording granted: \(DesktopConversationTargeter.hasScreenRecordingPermission())")
    guard let img = targeter.captureMainDisplay() else { print("CAPTURE FAILED"); exit(1) }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let rows = targeter.recognizeRows(in: img)
    let bandTop = bounds.height * 0.82
    print("screen \(Int(bounds.width))x\(Int(bounds.height)); bottom band (y>=\(Int(bandTop))):")
    for r in rows.filter({ $0.point.y >= bandTop }).sorted(by: { $0.point.y < $1.point.y }) {
        print(String(format: "  [%4d,%4d] | %@", Int(r.point.x), Int(r.point.y), r.text))
    }
    if let pt = targeter.composerPoint(from: rows, screen: bounds) {
        print("--- composerPoint -> (\(Int(pt.x)),\(Int(pt.y)))  [NO click performed]")
    } else {
        print("--- composerPoint -> nil (no bottom-band anchor found)")
    }
case "composer-focus-test":
    // Piece-1 mechanism verification: focus the composer (the new code), paste a
    // marked test string WITHOUT submitting (no Return -> no real turn), then OCR
    // to confirm the string landed in the composer. Clears it afterward IFF it
    // landed (never sends destructive keys into an unknown focus). Isolates
    // focusComposer from the already-proven targeting arc.
    guard args.count >= 3 else { print("usage: composer-focus-test <text>"); exit(2) }
    let probe = args[2]
    guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else {
        print("Claude desktop not running"); exit(1)
    }
    claude.activate(options: [.activateIgnoringOtherApps]); Thread.sleep(forTimeInterval: 0.6)
    let pid = claude.processIdentifier
    let targeter = DesktopConversationTargeter()
    let src = CGEventSource(stateID: .hidSystemState)
    func postKey(_ vk: CGKeyCode, _ flags: CGEventFlags = []) {
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false) else { return }
        d.flags = flags; u.flags = flags
        d.postToPid(pid); usleep(30_000); u.postToPid(pid)
    }
    targeter.focusComposer()  // <-- the new code under test (locate + click composer)
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents(); pb.setString(probe, forType: .string)
    postKey(9, .maskCommand)  // Cmd-V (paste, NO Return)
    Thread.sleep(forTimeInterval: 0.5)
    var landed = false
    if let img2 = targeter.captureMainDisplay() {
        let bandTop = CGDisplayBounds(CGMainDisplayID()).height * 0.78
        let band = targeter.recognizeRows(in: img2).filter { $0.point.y >= bandTop }
        let needle = probe.lowercased()
        landed = band.contains { needle.contains($0.text.lowercased()) || $0.text.lowercased().contains("focus test") }
        print(landed ? "LANDED ✓ — probe text is in the composer (the focus click worked)"
                     : "NOT FOUND ✗ — probe text not in the bottom band (focus likely missed)")
        print("bottom-band text after paste:")
        for r in band.sorted(by: { $0.point.y < $1.point.y }) { print("    [\(Int(r.point.x)),\(Int(r.point.y))] \(r.text)") }
    }
    if landed {
        postKey(0, .maskCommand)  // Cmd-A (select all in the focused composer)
        usleep(60_000)
        postKey(51)               // Delete (clear)
        print("(composer cleared)")
    } else {
        print("(left as-is — not clearing into an unknown focus)")
    }
    pb.clearContents(); if let saved { pb.setString(saved, forType: .string) }
    print("(clipboard restored)")
case "scroll-test":
    // Verify scrollSidebar actually moves the sidebar and in the right
    // direction: capture, scroll DOWN, capture again, and report which
    // conversations are NEW (proving scroll-to-find can reach off-screen ones).
    if let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
        claude.activate(options: [.activateIgnoringOtherApps]); Thread.sleep(forTimeInterval: 0.7)
    }
    let targeter = DesktopConversationTargeter()
    func cands() -> [String] {
        guard let img = targeter.captureMainDisplay() else { return [] }
        return targeter.sidebarCandidates(from: targeter.recognizeRows(in: img)).map(\.text)
    }
    let before = cands()
    print("before:        \(before.count) candidates; top: \(before.prefix(4))")
    targeter.scrollSidebar(toTop: false); Thread.sleep(forTimeInterval: 0.4)
    let afterDown = cands()
    let newOnes = afterDown.filter { !before.contains($0) }
    print("after down:    \(afterDown.count) candidates; \(newOnes.count) NEW: \(newOnes.prefix(5))")
    print(newOnes.isEmpty ? "  -> scroll-down revealed NOTHING new (wrong direction, no scroll, or at bottom)" : "  -> scroll-down works (revealed off-screen conversations)")
    targeter.scrollSidebar(toTop: true); Thread.sleep(forTimeInterval: 0.4)
    let afterTop = cands()
    print("after to-top:  \(afterTop.count) candidates; top: \(afterTop.prefix(4))")
case "desktop-title":
    // The targeting identity: compare the FROZEN transcript aiTitle against the
    // LIVE title Claude Desktop currently displays for a sessionId. Divergence
    // is the root cause of both the wrong-chat bleed and the silent degrade.
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools desktop-title <sessionId>")
        exit(2)
    }
    let sid = args[2]
    let frozen = DesktopConversationTargeter.readAiTitle(sessionId: sid)
    let live = DesktopConversationTargeter.readDesktopTitle(sessionId: sid)
    print("session:                 \(sid)")
    print("aiTitle (JSONL, frozen): \(frozen.map { "\"\($0)\"" } ?? "nil")")
    print("desktop title (live):    \(live.map { "\"\($0)\"" } ?? "nil")")
    print(frozen == live ? "  -> MATCH (no drift)" : "  -> DIVERGED: targeting must use the live title (this fix)")
case "context-wiki":
    // Run the Context Wiki auditor end-to-end against a project root and write
    // the artifacts (CONTEXT-WIKI.md / CONTEXT-SCHEMA.md / RECOMMENDATIONS.md +
    // audit-report.json). This is the runnable proof of the general capability —
    // point it at ANY directory with CLAUDE.md / SKILL.md / commands.
    //
    //   context-wiki <root> [--survey] [--out DIR] [--persist]
    //     --survey   also run the cheap-model per-source semantic pass (needs a
    //                configured provider + key). Off by default (deterministic-only).
    //     --out DIR  where to write artifacts (default: appSupport/context-wiki/<name>).
    //     --persist  record a summary row in the Supervisor DB (context_audits).
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools context-wiki <root> [--survey] [--out DIR] [--persist]")
        exit(2)
    }
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    let runSurvey = args.contains("--survey")
    let persist = args.contains("--persist")
    let outDir: URL = {
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        let name = root.lastPathComponent.isEmpty ? "root" : root.lastPathComponent
        return ConfigPaths().appSupportDir
            .appendingPathComponent("context-wiki", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }()

    // Optional survey: build a client from the configured provider + key, exactly
    // like the app does. Absent key -> deterministic-only (never a hard failure).
    // A `let` (built once here) so it can be captured by the audit Task below;
    // a captured `var` is rejected under strict concurrency.
    let surveyor: SourceSurveyor? = {
        guard runSurvey else { return nil }
        let paths = ConfigPaths()
        let provider = (try? FileActiveProviderStore(path: paths.activeProviderPath).read()) ?? .anthropic
        guard let key = ((try? KeychainProviderKeyStore().read(provider)) ?? nil), !key.isEmpty else {
            print("survey: requested but no API key for active provider — running deterministic-only")
            return nil
        }
        let client = LLMClient(provider: provider, apiKey: key, redactor: DefaultRedactor(), traceLog: .shared)
        print("survey: ON (provider=\(provider.rawValue), model=\(provider.defaultTriageModel))")
        return SourceSurveyor(client: client)
    }()

    let auditor = ContextAuditor()
    let renderer = WikiRenderer()
    let box = ResultBox2()
    let sem = DispatchSemaphore(value: 0)
    Task {
        let report = await auditor.audit(root: root, surveyor: surveyor)
        box.report = report
        sem.signal()
    }
    sem.wait()
    guard let report = box.report else { print("ERROR: audit produced no report"); exit(1) }

    do {
        let written = try renderer.writeArtifacts(report, to: outDir)
        print("")
        print(renderer.consoleSummary(report))
        print("")
        print("artifacts written to \(outDir.path):")
        print("  \(written.wikiPath.lastPathComponent)")
        print("  \(written.schemaPath.lastPathComponent)")
        print("  \(written.recommendationsPath.lastPathComponent)")
        print("  \(written.reportJSONPath.lastPathComponent)")
    } catch {
        print("ERROR writing artifacts: \(error)")
        exit(1)
    }

    if persist {
        let paths = ConfigPaths()
        do {
            try paths.ensureDirectoriesExist()
            let db = try SupervisorDatabase(path: paths.databasePath)
            let row = try ContextAuditStore(database: db).record(report)
            print("persisted audit row id=\(row.id) (context_audits)")
        } catch {
            print("WARN: could not persist audit: \(error)")
        }
    }
case "second-brain":
    // Run ONE Second Brain iteration against a project root: distill candidate
    // memories from its recent session transcripts (deterministic, redacted),
    // optimize them into the ledger (merge/confirm/retire), and render
    // SECOND-BRAIN.md (+ the plain-JSON ledger twin). Prints the iteration's
    // delta summary.
    //
    //   second-brain <root> [--out DIR] [--persist]
    //     --out DIR  where to write artifacts (default: appSupport/second-brain/<name>).
    //                Passing it is an explicit request for files, so artifacts
    //                are written even without --persist.
    //     --persist  record the iteration in the Supervisor DB (second_brain_ledgers).
    //                Without --persist (and without an explicit --out) the run
    //                is a dry preview: the prior persisted ledger is still READ
    //                (so the iteration number is honest), but the new state is
    //                not saved and no artifacts are written.
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools second-brain <root> [--out DIR] [--persist]")
        exit(2)
    }
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    let persist = args.contains("--persist")
    let explicitOutDir: URL? = {
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return nil
    }()
    let defaultOutDir: URL = {
        let name = root.lastPathComponent.isEmpty ? "root" : root.lastPathComponent
        return ConfigPaths().appSupportDir
            .appendingPathComponent("second-brain", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }()
    let outDir = explicitOutDir ?? defaultOutDir

    // DB open stays here (the CLI decides how loudly to degrade); the loop's
    // business rules live in SecondBrainCoordinator (issue #54 item 2) so the
    // app and the CLI can never diverge on resume/dry-run/persist semantics.
    var db: SupervisorDatabase? = nil
    do {
        let paths = ConfigPaths()
        try paths.ensureDirectoriesExist()
        db = try SupervisorDatabase(path: paths.databasePath)
    } catch {
        print("WARN: could not open Supervisor DB (\(error)) — starting a fresh ledger")
    }

    // Write files only when asked: --persist saves state, and an explicit
    // --out is a request for files. A plain dry preview writing the SAME
    // artifacts a persisted run writes would desync the files from the DB
    // while promising "the new state is not saved".
    let artifactsDir: URL? = (persist || explicitOutDir != nil) ? outDir : nil

    let dbForTask = db
    let iterationBox = IterationBox()
    let brainSem = DispatchSemaphore(value: 0)
    Task {
        do {
            iterationBox.result = try await SecondBrainCoordinator().runIteration(
                root: root,
                database: dbForTask,
                persistToDatabase: persist,
                artifactsDir: artifactsDir
            )
        } catch {
            iterationBox.error = error
        }
        brainSem.signal()
    }
    brainSem.wait()

    if let error = iterationBox.error {
        // Artifact-write failure still shows the full iteration report the
        // pre-coordinator CLI printed before attempting the write.
        if let failure = error as? SecondBrainCoordinator.ArtifactWriteFailure {
            if let n = failure.resumedFromIteration {
                print("resuming from iteration \(n) (\(failure.resumedActiveEntryCount ?? 0) active entries)")
            }
            print("")
            print(failure.consoleSummary)
            print("")
            print("ERROR writing artifacts: \(failure.underlying)")
        } else {
            print("ERROR writing artifacts: \(error)")
        }
        exit(1)
    }
    guard let result = iterationBox.result else {
        print("ERROR: iteration did not run")
        exit(1)
    }
    if let n = result.resumedFromIteration {
        print("resuming from iteration \(n) (\(result.resumedActiveEntryCount ?? 0) active entries)")
    }
    print("")
    print(result.consoleSummary)
    print("")
    if let paths = result.artifactPaths {
        print("artifacts written to \(outDir.path):")
        print("  \(paths.brain.lastPathComponent)")
        print("  \(paths.ledgerJSON.lastPathComponent)")
    } else {
        print("dry preview: artifacts/ledger not written (pass --persist to save, or --out DIR for files)")
    }
    if let rowID = result.persistedRowID {
        print("persisted iteration row id=\(rowID) (second_brain_ledgers)")
    }
    for warning in result.warnings {
        print("WARN: \(warning)")
    }
case "trust-scorecard":
    // issue #60 metric 1: the dismissal-rate half of the measured-experience
    // gate. Aggregates per-category flag outcomes straight from the local
    // sqlite — volume by severity, the explicit user responses the hover panel
    // records on flags.user_response (approved / dismissed / false_positive /
    // rejected / none — the panel labels "rejected" as Override), and the
    // actions Supervisor actually took (audit_entries.kind) — over a trailing
    // window. No LLM, no network, no row writes (first run on a fresh machine
    // still creates the empty DB file, matching every other DB-backed
    // subcommand). A rising dismissal rate = users learning to ignore
    // Supervisor, measured before they churn.
    //
    //   trust-scorecard [--since DAYS]
    //     --since DAYS  trailing window in days (default 30).
    var sinceDays = 30
    if let i = args.firstIndex(of: "--since") {
        guard i + 1 < args.count, let days = Int(args[i + 1]), days > 0 else {
            print("usage: SupervisorDevTools trust-scorecard [--since DAYS]  (DAYS = positive integer)")
            exit(2)
        }
        sinceDays = days
    }
    let paths = ConfigPaths()
    let db: SupervisorDatabase
    do {
        try paths.ensureDirectoriesExist()
        db = try SupervisorDatabase(path: paths.databasePath)
    } catch {
        print("ERROR db open: \(error)")
        exit(1)
    }
    do {
        print(try TrustScorecard.load(database: db, sinceDays: sinceDays).render())
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
default:
    print("unknown subcommand: \(args[1])")
    exit(2)
}

/// Small reference box so the detached audit Task can hand its result back across
/// the semaphore without mutating a captured `var` (Swift 6 strict concurrency).
/// Named `…2` to avoid colliding with the `ResultBox` in the inject-test case.
final class ResultBox2: @unchecked Sendable { var report: AuditReport? = nil }

/// Same pattern for the second-brain iteration Task.
final class IterationBox: @unchecked Sendable {
    var result: SecondBrainCoordinator.IterationResult? = nil
    var error: Error? = nil
}
