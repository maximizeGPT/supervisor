// Heartbeat.swift
//
// File-based heartbeat I/O used by SupervisorHeartbeat (writes) and
// SupervisorStatusBar (reads). Not in GRDB — heartbeat needs to survive a
// SQLite write lock and needs to be readable without the GRDB dep, which
// the status-bar process technically pulls in via SupervisorCore but
// philosophically should not depend on for the most critical "is the
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

/// v0.3.0 (P0-3): writer side of the heartbeat's `network_down` signal.
///
/// The heartbeat FILE is rewritten every 5s by the SupervisorHeartbeat
/// companion, which has no view into triage failures — any flags the main
/// app wrote into that file would be stomped within seconds. So the main
/// app records "model triage is not running" (provider unreachable, or the
/// daily cost cap) in this sibling marker file instead: the contents are
/// the human-readable reason; presence means degraded. SupervisorStatusBar
/// reads the marker alongside the heartbeat and shows amber + the reason
/// while it exists. Folding the flag into the heartbeat line itself (so
/// `Heartbeat.Flag.networkDown` is carried on the wire format) requires a
/// SupervisorHeartbeat-side merge of this marker — left for the lifecycle
/// wave; the marker is the transport until then.
public struct NetworkDownMarker: Sendable {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Conventional location: `network-down.marker` next to the heartbeat
    /// file, so writer (main app) and reader (status bar) agree without a
    /// new ConfigPaths entry.
    public static func alongside(heartbeatPath: URL) -> NetworkDownMarker {
        NetworkDownMarker(path: heartbeatPath
            .deletingLastPathComponent()
            .appendingPathComponent("network-down.marker", isDirectory: false))
    }

    /// Write (or overwrite) the marker with the degraded reason. Best-effort:
    /// a failed write only costs the status-bar amber, never the pipeline.
    public func set(reason: String) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(reason.utf8).write(to: path, options: .atomic)
    }

    /// Remove the marker (recovery). Safe when the marker doesn't exist.
    public func clear() {
        try? FileManager.default.removeItem(at: path)
    }

    /// The degraded reason, or nil when not degraded. An empty/unreadable
    /// marker still reads as degraded with a generic reason — presence is
    /// the signal, the text is a nicety.
    public func read() -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let text = (try? String(contentsOf: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "model triage degraded" : text
    }
}

/// Pure evaluator used by the status-bar process. Lives in Core so it can
/// be unit-tested without an AppKit runtime.
public enum HeartbeatHealth: Equatable, Sendable {
    case green
    case amber
    case red(reason: String)

    public static func evaluate(age: TimeInterval) -> HeartbeatHealth {
        if age.isInfinite { return .red(reason: "heartbeat file missing") }
        if age < 10       { return .green }
        if age < 30       { return .amber }
        return .red(reason: "heartbeat stale (\(Int(age))s)")
    }
}
