// Heartbeat.swift
//
// File-based heartbeat I/O. SupervisorHeartbeat writes the file; the main
// Supervisor app reads it (in-process) to drive the menu-bar health icon.
// Not in GRDB — heartbeat needs to survive a SQLite write lock and needs
// to be readable without depending on GRDB for the most critical "is the
// supervisor alive" answer.
//
// Format: one line, two fields, space-separated.
//   <unix-epoch-millis> <state-flags>
// where state-flags is a comma-separated set of: ok, ax_lost, notif_lost,
// network_down. Missing flag → not set. Empty flags written as `-`.

import Foundation

public struct Heartbeat: Sendable, Equatable {
    public let timestamp: Date
    public let flags: Set<Flag>

    public enum Flag: String, Sendable, CaseIterable {
        case axLost = "ax_lost"
        case notifLost = "notif_lost"
        case networkDown = "network_down"
    }

    public init(timestamp: Date = Date(), flags: Set<Flag> = []) {
        self.timestamp = timestamp
        self.flags = flags
    }
}

public struct HeartbeatFile: Sendable {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Overwrite the heartbeat file with the current timestamp + flags.
    /// Atomic via temp-file + rename. Returns the bytes written.
    @discardableResult
    public func write(_ beat: Heartbeat) throws -> Int {
        let millis = Int64(beat.timestamp.timeIntervalSince1970 * 1000)
        let flagStr: String = beat.flags.isEmpty
            ? "-"
            : beat.flags.map { $0.rawValue }.sorted().joined(separator: ",")
        let line = "\(millis) \(flagStr)\n"
        let data = Data(line.utf8)

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = path.appendingPathExtension("tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // Atomic rename so a reader never sees a partial line.
        _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
        // replaceItemAt removes the temp on success; clean up on failure path.
        try? FileManager.default.removeItem(at: tmp)
        return data.count
    }

    /// Read and parse the heartbeat. Returns nil if the file is missing,
    /// corrupt, or malformed.
    public func read() throws -> Heartbeat? {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch let e as NSError where e.code == NSFileReadNoSuchFileError {
            return nil
        }

        guard let line = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 1, let millis = Int64(parts[0]) else { return nil }

        let ts = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        var flags: Set<Heartbeat.Flag> = []
        if parts.count == 2 && parts[1] != "-" {
            for tok in parts[1].split(separator: ",") {
                if let f = Heartbeat.Flag(rawValue: String(tok)) {
                    flags.insert(f)
                }
            }
        }
        return Heartbeat(timestamp: ts, flags: flags)
    }

    /// Time since the last write. Returns .infinity if the file is missing.
    public func ageSeconds(asOf now: Date = Date()) throws -> TimeInterval {
        guard let beat = try read() else { return .infinity }
        return now.timeIntervalSince(beat.timestamp)
    }
}

/// Pure evaluator used by the status-bar process. Lives in Core so it can
/// be unit-tested without an AppKit runtime.
public enum HeartbeatHealth: Equatable, Sendable {
    case green
    case amber
    case red(reason: String)

    /// Tolerance for benign backward clock jitter (an NTP nudge, sleep/resume
    /// skew, or sub-second drift between the writer's and reader's clocks). An age
    /// slightly below zero is treated as "just written." An age MORE negative than
    /// this is a beat that claims to come from the FUTURE — not evidence of
    /// liveness — so it is treated as stale/unknown (RED), never green. See FIX 3.
    public static let clockJitterToleranceSeconds: TimeInterval = 2

    /// Evaluate health from the wall-clock heartbeat age and, optionally, the
    /// ENGINE-progress age.
    ///
    /// - `age` is seconds since the heartbeat file was last stamped — proves the
    ///   supervisor PROCESS tree is alive (the child stamps it on a timer).
    /// - `engineAge` is seconds since the main app's TriageEngine last advanced
    ///   its progress token (see `EngineProgress`/`ConfigPaths.engineProgressPath`).
    ///   `nil` means the caller has no engine signal (legacy call sites / unit
    ///   tests) and the result is process-only — unchanged from the original
    ///   behavior.
    ///
    /// FIX 4 (hang detection): a live process is NOT sufficient for green. When an
    /// `engineAge` is supplied, the overall health is the WORSE of the process
    /// signal and the engine signal, so a fresh heartbeat over a HUNG engine (the
    /// process is alive but the engine loop has stopped advancing its token) reads
    /// amber/red — never a lying green.
    public static func evaluate(age: TimeInterval, engineAge: TimeInterval? = nil) -> HeartbeatHealth {
        let process = classify(age: age, subject: "heartbeat", missingReason: "heartbeat file missing")
        guard let engineAge else { return process }
        let engine = classify(age: engineAge, subject: "engine", missingReason: "engine progress missing (engine never ticked)")
        return worse(process, engine)
    }

    /// Shared age → state classifier used for BOTH the process heartbeat and the
    /// engine-progress token. Same green/amber/red thresholds; `subject` only
    /// shapes the red reason string.
    private static func classify(age: TimeInterval, subject: String, missingReason: String) -> HeartbeatHealth {
        if age.isInfinite { return .red(reason: missingReason) }
        // FIX 3: a sufficiently-negative (future-dated) age is suspicious, not
        // fresh. A timestamp ahead of `now` (backward clock step from NTP
        // correction, sleep/resume, VM restore, or a manual change) is NOT
        // evidence that the writer is alive — if the writer then dies it would
        // otherwise coast in green for |age|+10s. Map it to RED (the stale/unknown
        // treatment). A tiny negative within tolerance is benign jitter → fall
        // through to the normal (green) path.
        if age < -clockJitterToleranceSeconds {
            return .red(reason: "\(subject) timestamp in the future (\(Int(age))s) — clock stepped back")
        }
        if age < 10 { return .green }
        if age < 30 { return .amber }
        return .red(reason: "\(subject) stale (\(Int(age))s)")
    }

    /// Combine two health signals, keeping the more alarming one: red > amber > green.
    private static func worse(_ a: HeartbeatHealth, _ b: HeartbeatHealth) -> HeartbeatHealth {
        func rank(_ h: HeartbeatHealth) -> Int {
            switch h {
            case .green: return 0
            case .amber: return 1
            case .red:   return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }
}

// MARK: - Engine-progress token (FIX 4)

public extension ConfigPaths {
    /// `~/Library/Application Support/Supervisor/engine-progress.txt`
    ///
    /// The ENGINE-liveness token, distinct from `heartbeatPath` (which the child
    /// SupervisorHeartbeat process stamps on a dumb timer to prove the process
    /// TREE is alive). The main app's TriageEngine advances this file from its
    /// periodic run-loop tick, so it only stays fresh while the engine is actually
    /// cycling. A fresh `heartbeat.txt` alongside a STALE `engine-progress.txt`
    /// means the process is alive but the engine has HUNG — the status bar then
    /// honestly shows amber/red instead of a lying green.
    var engineProgressPath: URL {
        appSupportDir.appendingPathComponent("engine-progress.txt", isDirectory: false)
    }
}

/// Writer for the engine-progress token (FIX 4). The main app's engine calls
/// `recordTick()` once per run-loop cycle; the status-bar companion reads the
/// file's age (via `HeartbeatFile.ageSeconds`) and folds it into
/// `HeartbeatHealth.evaluate(age:engineAge:)`.
public enum EngineProgress {
    /// Stamp one engine-loop tick into the default engine-progress file. Call from
    /// the engine's periodic tick (e.g. `TriageEngine.checkIdleStates`) so the
    /// token advances only while the engine loop is genuinely running. Best-effort
    /// and non-throwing: a failed write simply lets the token age, which the
    /// status bar reads as engine-stale (degrades toward red) — it can never
    /// produce a false green.
    @discardableResult
    public static func recordTick(paths: ConfigPaths = ConfigPaths(), at time: Date = Date()) -> Bool {
        do {
            _ = try HeartbeatFile(path: paths.engineProgressPath).write(Heartbeat(timestamp: time))
            return true
        } catch {
            return false
        }
    }
}
