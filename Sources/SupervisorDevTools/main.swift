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
import CoreGraphics
import Foundation
import SupervisorCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: SupervisorDevTools <inject-key KEY | inject-key-from-env | delete-key | show | seed-offsets-eof DIR>")
    exit(2)
}

let store = KeychainAPIKeyStore()

switch args[1] {
case "inject-key":
    guard args.count >= 3 else {
        print("usage: SupervisorDevTools inject-key <key>")
        exit(2)
    }
    do {
        try store.write(args[2])
        print("ok: key written (len=\(args[2].count))")
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
        print("ok: key from env written (len=\(key.count))")
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
case "delete-key":
    do { try store.delete(); print("ok: deleted") }
    catch { print("ERROR: \(error)"); exit(1) }
case "show":
    do {
        if let k = try store.read() {
            print("present (len=\(k.count))")
        } else {
            print("absent")
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
    if args.count >= 3, args[2] == "--all" {
        print("ALL rows (x,y,text), sorted by y:")
        for r in rows.sorted(by: { $0.point.y < $1.point.y }) {
            print("  x=\(Int(r.point.x)) y=\(Int(r.point.y)) \"\(r.text.prefix(48))\"")
        }
    }
case "desktop-click":
    // Re-OCR live and click the screen label matching <needle>, confined to an
    // optional x-column. The reusable "find a control and click it" primitive —
    // for the MCQ Submit, the Stop button, etc. Usage: desktop-click <label> [minX] [maxX]
    guard args.count >= 3 else { print("usage: desktop-click <label> [minX] [maxX]"); exit(2) }
    let cNeedle = args[2]
    let cMinX = args.count >= 4 ? (Double(args[3]) ?? 0) : 0
    let cMaxX = args.count >= 5 ? (Double(args[4]) ?? 99999) : 99999
    let ct = DesktopConversationTargeter()
    guard let cimg = ct.captureMainDisplay() else { print("capture_failed"); exit(1) }
    let crows = ct.recognizeRows(in: cimg).filter { Double($0.point.x) >= cMinX && Double($0.point.x) <= cMaxX }
    guard let cpt = crows.first(where: { $0.text.localizedCaseInsensitiveContains(cNeedle) })?.point else {
        print("'\(cNeedle)' not found in x=[\(Int(cMinX)),\(Int(cMaxX))].")
        print("rows: " + crows.sorted { $0.point.y < $1.point.y }.prefix(24).map { "(\(Int($0.point.x)),\(Int($0.point.y)))\($0.text.prefix(14))" }.joined(separator: " | "))
        exit(1)
    }
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "com.anthropic.claudefordesktop" { app.activate(options: []); break }
    usleep(400_000)
    print("clicking '\(cNeedle)' at (\(Int(cpt.x)),\(Int(cpt.y)))")
    ct.click(at: cpt)
case "desktop-mcq-answer":
    // Answer an on-screen AskUserQuestion (MCQ) widget by the universal "Other"
    // path: click Other → focus the text field → paste the answer → click Submit.
    // Re-OCRs live (robust to layout). Optional minX/maxX confine it to ONE
    // pane's column. Usage: desktop-mcq-answer "<answer>" [minX] [maxX]
    guard args.count >= 3 else { print("usage: desktop-mcq-answer <answer> [minX] [maxX]"); exit(2) }
    let mcqAnswer = args[2]
    let mcqMinX = args.count >= 4 ? (Double(args[3]) ?? 0) : 0
    let mcqMaxX = args.count >= 5 ? (Double(args[4]) ?? 99999) : 99999
    let mt = DesktopConversationTargeter()
    guard let mimg = mt.captureMainDisplay() else { print("capture_failed"); exit(1) }
    let mrows = mt.recognizeRows(in: mimg).filter {
        Double($0.point.x) >= mcqMinX && Double($0.point.x) <= mcqMaxX
    }
    func mfind(_ needle: String) -> CGPoint? {
        mrows.first { $0.text.localizedCaseInsensitiveContains(needle) }?.point
    }
    guard let fieldPt = mfind("Type your own") ?? mfind("Other"),
          let submitPt = mfind("Submit") else {
        print("MCQ controls not found in x=[\(Int(mcqMinX)),\(Int(mcqMaxX))].")
        print("rows: " + mrows.prefix(16).map { "(\(Int($0.point.x)),\(Int($0.point.y)))\($0.text.prefix(14))" }.joined(separator: " | "))
        exit(1)
    }
    let otherPt = mfind("Other") ?? fieldPt
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "com.anthropic.claudefordesktop" { app.activate(options: []); break }
    usleep(500_000)
    print("Other@(\(Int(otherPt.x)),\(Int(otherPt.y))) field@(\(Int(fieldPt.x)),\(Int(fieldPt.y))) Submit@(\(Int(submitPt.x)),\(Int(submitPt.y)))")
    mt.click(at: otherPt); usleep(350_000)
    mt.click(at: fieldPt); usleep(350_000)
    let mpb = NSPasteboard.general; mpb.clearContents(); mpb.setString(mcqAnswer, forType: .string)
    let mcsrc = CGEventSource(stateID: .hidSystemState)
    if let dn = CGEvent(keyboardEventSource: mcsrc, virtualKey: 9, keyDown: true) { dn.flags = .maskCommand; dn.post(tap: .cghidEventTap) }
    if let up = CGEvent(keyboardEventSource: mcsrc, virtualKey: 9, keyDown: false) { up.flags = .maskCommand; up.post(tap: .cghidEventTap) }
    usleep(450_000)
    mt.click(at: submitPt)
    print("submitted answer to MCQ: \(mcqAnswer.prefix(60))")
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
default:
    print("unknown subcommand: \(args[1])")
    exit(2)
}
