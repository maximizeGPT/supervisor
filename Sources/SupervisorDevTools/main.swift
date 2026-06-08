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
    print("--- activeConversationTitle() -> \(targeter.activeConversationTitle(from: rows).map { "\"\($0)\"" } ?? "nil")")
default:
    print("unknown subcommand: \(args[1])")
    exit(2)
}
