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
default:
    print("unknown subcommand: \(args[1])")
    exit(2)
}
