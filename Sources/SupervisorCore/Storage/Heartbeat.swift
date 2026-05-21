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
