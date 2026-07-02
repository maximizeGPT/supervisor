// FakeClaudeCLI — test harness for ProcessLocator (v0.1.4 Part A1).
//
// Writes realistic Claude-Code-shaped JSONL events to a target path on a
// configurable cadence, optionally holds the fd open between writes, and
// records its PID to a sidecar file so tests can verify the locator
// returned the right PID.
//
// Foundation-only — no SupervisorCore import — so the harness stays
// independent of the code under test.
//
// Flags:
//   --jsonl <path>        REQUIRED. Where to write JSONL events.
//   --cwd <path>          REQUIRED. Simulated cwd: chdir'd into AND written
//                         into the first event's `cwd` field so the
//                         locator (and EventParser) sees a consistent cwd.
//   --pid-file <path>     PID sidecar. Default /tmp/fake-claude.pid. When
//                         spawned as a child via --multi-instance, the
//                         child writes to <pid-file>.child instead.
//   --interval-ms <int>   Event cadence in ms. Default 500.
//   --max-events <int>    Stop after N events (excluding the header).
//                         Default 60 (= ~30s at the default cadence).
//   --no-fd-hold          Open + write + close per event, simulating the
//                         degraded case where Claude doesn't keep the
//                         JSONL fd open between writes. The locator's
//                         lsof-based cross-check (if ever wired) should
//                         degrade gracefully here.
//   --multi-instance      Spawn a second FakeClaudeCLI in a different
//                         cwd (default /tmp) writing to <jsonl>.child.
//                         Exercises the locator's "filter by cwd"
//                         path — both processes are "Claude" but only
//                         one matches a given target cwd.
//   --session-id <uuid>   Override the generated session ID. Useful when
//                         tests need a predictable JSONL filename.
//   --replay <path>       Scenario-replay mode (v0.3.0 Wave 4). Instead of
//                         the synthetic prompt/Bash loop, read a fixture
//                         JSONL from <path> and replay its lines VERBATIM to
//                         the target transcript, one every --interval-ms, so
//                         a process-based dogfood scenario is driven by a
//                         hand-authored transcript (destructive line, resume
//                         copy, tool_result turn, …). The fixture owns all
//                         content — no queue-operation header is synthesized
//                         in this mode (the fixture supplies its own
//                         cwd-bearing lead-in). --pid-file / --cwd / fd-hold
//                         behave exactly as in the default mode, so a replay
//                         process is still locatable by ProcessLocator.
//   --child               Internal flag — set when this process was
//                         spawned by a --multi-instance parent. Suppresses
//                         further self-spawning (no infinite recursion)
//                         and writes the PID sidecar with the .child
//                         suffix so the parent's sidecar isn't clobbered.
//
// Cleanup: this binary does NOT signal-trap. Test drivers are responsible
// for SIGTERM'ing both PIDs (parent + child via pid-file + pid-file.child)
// and removing any JSONL files they created.

import Darwin
import Foundation

// MARK: - Self exec path
//
// Capture the absolute canonical path of THIS binary before `chdir` —
// otherwise the multi-instance child spawn fails when CommandLine.arguments[0]
// is a relative path (it usually is under `swift run` and SwiftPM-built
// .build/.../debug/FakeClaudeCLI invocations). _NSGetExecutablePath is
// the macOS-canonical answer; we resolve the result through realpath to
// drop `../` and similar.
let selfExecPath: String = {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else {
        return CommandLine.arguments[0]
    }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(buf, &resolved) != nil {
        return String(cString: resolved)
    }
    return String(cString: buf)
}()

// MARK: - Args

struct Args {
    var jsonlPath: String?
    var cwd: String?
    var pidFile: String = "/tmp/fake-claude.pid"
    var intervalMs: Int = 500
    var maxEvents: Int = 60
    var holdFd: Bool = true
    var multiInstance: Bool = false
    var isChild: Bool = false
    var sessionId: String = UUID().uuidString
    var replayPath: String? = nil
}

func parseArgs() -> Args {
    var args = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        let flag = argv[i]
        func value() -> String {
            guard i + 1 < argv.count else {
                FileHandle.standardError.write(Data("\(flag): missing value\n".utf8))
                exit(2)
            }
            i += 1
            return argv[i]
        }
        switch flag {
        case "--jsonl":          args.jsonlPath = value()
        case "--cwd":            args.cwd = value()
        case "--pid-file":       args.pidFile = value()
        case "--interval-ms":    args.intervalMs = Int(value()) ?? args.intervalMs
        case "--max-events":     args.maxEvents = Int(value()) ?? args.maxEvents
        case "--session-id":     args.sessionId = value()
        case "--replay":         args.replayPath = value()
        case "--no-fd-hold":     args.holdFd = false
        case "--multi-instance": args.multiInstance = true
        case "--child":          args.isChild = true
        default:
            FileHandle.standardError.write(Data("FakeClaudeCLI: unknown arg \(flag)\n".utf8))
            exit(2)
        }
        i += 1
    }
    return args
}

let args = parseArgs()
guard let jsonl = args.jsonlPath else {
    FileHandle.standardError.write(Data("FakeClaudeCLI: --jsonl is required\n".utf8))
    exit(2)
}
guard let cwd = args.cwd else {
    FileHandle.standardError.write(Data("FakeClaudeCLI: --cwd is required\n".utf8))
    exit(2)
}

// MARK: - chdir

if chdir(cwd) != 0 {
    let msg = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("FakeClaudeCLI: chdir(\(cwd)) failed: \(msg)\n".utf8))
    exit(1)
}

// MARK: - PID sidecar

let pidFilePath = args.isChild ? (args.pidFile + ".child") : args.pidFile
try? "\(getpid())".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

// MARK: - Multi-instance self-spawn

if args.multiInstance && !args.isChild {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: selfExecPath)
    var childArgs: [String] = [
        "--jsonl", "\(jsonl).child",
        "--cwd", "/tmp",
        "--pid-file", args.pidFile,            // child appends ".child" itself
        "--interval-ms", "\(args.intervalMs)",
        "--max-events", "\(args.maxEvents)",
        "--session-id", UUID().uuidString,
        "--child",
    ]
    if !args.holdFd { childArgs.append("--no-fd-hold") }
    child.arguments = childArgs
    do {
        try child.run()
    } catch {
        FileHandle.standardError.write(Data("FakeClaudeCLI: spawn child failed: \(error)\n".utf8))
    }
}

// MARK: - JSONL writer

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

var heldFd: Int32 = -1
if args.holdFd {
    heldFd = open(jsonl, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if heldFd < 0 {
        let msg = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("FakeClaudeCLI: open(\(jsonl)) failed: \(msg)\n".utf8))
        exit(1)
    }
}

func writeData(_ data: Data) {
    if args.holdFd {
        _ = data.withUnsafeBytes { ptr -> Int in
            write(heldFd, ptr.baseAddress, data.count)
        }
        fsync(heldFd)
    } else {
        let fd = open(jsonl, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { ptr -> Int in
            write(fd, ptr.baseAddress, data.count)
        }
        close(fd)
    }
}

func writeEvent(_ json: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
    data.append(0x0A) // newline
    writeData(data)
}

/// Append a preformed JSONL line verbatim (used by --replay so a
/// hand-authored fixture's exact bytes — timestamps, sidechain flags,
/// destructive commands — reach the transcript unmodified).
func writeRawLine(_ line: String) {
    var data = Data(line.utf8)
    if data.last != 0x0A { data.append(0x0A) }
    writeData(data)
}

// MARK: - Replay mode (v0.3.0 Wave 4)
//
// Drive a process-based dogfood scenario from a fixture transcript. Each
// line is replayed on the --interval-ms cadence so the tail sees writes
// arrive over time (realistic), not as one atomic dump. The fixture owns
// all content, INCLUDING the cwd-bearing lead-in the parser needs for
// sessionStart, so no synthetic header is written here.
if let replayPath = args.replayPath {
    guard let contents = try? String(contentsOfFile: replayPath, encoding: .utf8) else {
        FileHandle.standardError.write(Data("FakeClaudeCLI: --replay \(replayPath) unreadable\n".utf8))
        exit(1)
    }
    let interval = TimeInterval(args.intervalMs) / 1000.0
    for raw in contents.split(separator: "\n", omittingEmptySubsequences: true) {
        Thread.sleep(forTimeInterval: interval)
        writeRawLine(String(raw))
    }
    if args.holdFd && heldFd >= 0 { close(heldFd) }
    unlink(pidFilePath)
    exit(0)
}

// MARK: - Event sequence

// Header (queue-operation lookalike; carries cwd + sessionId so EventParser
// can emit sessionStart on the first line).
writeEvent([
    "type": "queue-operation",
    "timestamp": isoFormatter.string(from: Date()),
    "sessionId": args.sessionId,
    "cwd": cwd,
    "gitBranch": "main",
])

// Alternating user prompt + assistant tool_use cycle. Realistic-ish:
// matches the shape EventParser handles (user message with string content,
// assistant message with content array containing a Bash tool_use block).
// v0.3.0 Wave 4: the cycle now also emits the matching tool_result after
// each Bash call and an occasional assistant text block, so the fake covers
// the full turn shape (call → result → prose), not just call. The original
// prompt/Bash alternation is preserved so ProcessLocator tests — which only
// care that a process is writing on a cadence in a known cwd — are
// unaffected.
for i in 0..<args.maxEvents {
    Thread.sleep(forTimeInterval: TimeInterval(args.intervalMs) / 1000.0)
    let ts = isoFormatter.string(from: Date())
    if i % 2 == 0 {
        writeEvent([
            "type": "user",
            "timestamp": ts,
            "sessionId": args.sessionId,
            "uuid": "u-\(i)",
            "message": [
                "role": "user",
                "content": "fake user prompt \(i)",
            ] as [String: Any],
        ])
    } else {
        writeEvent([
            "type": "assistant",
            "timestamp": ts,
            "sessionId": args.sessionId,
            "uuid": "a-\(i)",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "t-\(i)",
                        "name": "Bash",
                        "input": ["command": "echo fake-claude tick \(i)"] as [String: Any],
                    ] as [String: Any]
                ] as [Any],
            ] as [String: Any],
        ])
        // The matching tool_result for the Bash call above — a user-role turn
        // carrying a tool_result block (the shape EventParser turns into
        // .bashToolResult).
        writeEvent([
            "type": "user",
            "timestamp": isoFormatter.string(from: Date()),
            "sessionId": args.sessionId,
            "uuid": "r-\(i)",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "t-\(i)",
                        "content": "fake-claude tick \(i)",
                        "is_error": false,
                    ] as [String: Any]
                ] as [Any],
            ] as [String: Any],
        ])
    }
    // Occasional assistant prose (a stop-shaped "done" turn), so the
    // assistant-text shape is exercised too.
    if i % 5 == 4 {
        writeEvent([
            "type": "assistant",
            "timestamp": isoFormatter.string(from: Date()),
            "sessionId": args.sessionId,
            "uuid": "at-\(i)",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "text",
                        "text": "Done with step \(i). Let me know what to do next.",
                    ] as [String: Any]
                ] as [Any],
            ] as [String: Any],
        ])
    }
}

if args.holdFd && heldFd >= 0 {
    close(heldFd)
}

// PID sidecar cleanup so re-runs don't get stale data.
unlink(pidFilePath)
