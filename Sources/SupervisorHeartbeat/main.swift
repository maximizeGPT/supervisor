// SupervisorHeartbeat — companion process.
//
// Writes ~/Library/Application Support/Supervisor/heartbeat.txt every 5s
// while it itself is running. The status-bar companion reads this file
// to decide whether the main supervisor stack is healthy.
//
// In Phase B/C this will additionally check the main app's mach port and
// only emit heartbeats while the port is reachable. For Phase A it just
// writes unconditionally — the test is whether killing this process makes
// the status bar turn red within 30s.

import Foundation
import SupervisorCore

let paths = ConfigPaths()
try paths.ensureDirectoriesExist()

let heartbeat = HeartbeatFile(path: paths.heartbeatPath)
let trace = TraceLog(path: paths.traceLogPath)

trace.emit("heartbeat", "boot pid=\(ProcessInfo.processInfo.processIdentifier) path=\(paths.heartbeatPath.path)")
print("SupervisorHeartbeat: writing to \(paths.heartbeatPath.path) every 5s (PID \(ProcessInfo.processInfo.processIdentifier))")

// Block process exit on SIGINT/SIGTERM via signal sources, so we can flush
// a final heartbeat (or skip it) cleanly.
//
// Guard: the DispatchSourceSignal returned by makeSignalSource must be
// retained for the lifetime of the process. Storing in a module-level
// array keeps them alive — without this, they'd be deallocated as soon
// as the for loop ends and SIGTERM would be silently dropped. (Found
// during Checkpoint A: kill -TERM produced no exit; kill -9 was required.
// The fix lives in the retention, not in handler logic.)
let signalQueue = DispatchQueue(label: "supervisor.heartbeat.signal")
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        trace.emit("heartbeat", "received signal \(sig); exiting")
        trace.sync()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// Heartbeat loop.
let queue = DispatchQueue(label: "supervisor.heartbeat", qos: .utility)
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 5.0)
timer.setEventHandler {
    // F4: parent-liveness. This process is spawned as a direct child of the
    // main Supervisor.app (see startHeartbeat in SupervisorApp/main.swift). If
    // the main app crashes, this orphaned child is reparented to launchd, so
    // getppid() returns 1. Without this check the orphan keeps writing a fresh
    // heartbeat forever and the menu-bar icon stays green over a dead
    // supervisor — the exact "green dot lying" the product must never do. Stop
    // writing so the heartbeat goes stale and the icon honestly turns red.
    if getppid() == 1 {
        trace.emit("heartbeat", "parent gone (getppid=1) — stopping so the icon can go red")
        trace.sync()
        exit(0)
    }
    let beat = Heartbeat(timestamp: Date(), flags: [])
    do {
        let bytes = try heartbeat.write(beat)
        trace.emit("heartbeat", "wrote \(bytes) bytes")
    } catch {
        trace.emit("heartbeat", "write failed: \(error)")
    }
}
timer.resume()

dispatchMain()
