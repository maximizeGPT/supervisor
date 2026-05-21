// ConfigPaths.swift
//
// Single source of truth for "where does X live" answers. Tests stub
// `home` to redirect the whole tree under a temp directory; production
// code uses the real home.

import Foundation

public struct ConfigPaths: Sendable {

    /// Root of the user's home directory. Production: `~`. Tests: a temp dir.
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// `~/Library/Application Support/Supervisor/` — config + DB + heartbeat.
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Supervisor", isDirectory: true)
    }

    /// `~/Library/Logs/Supervisor/` — trace log.
    public var logsDir: URL {
        home.appendingPathComponent("Library/Logs/Supervisor", isDirectory: true)
    }

    /// `~/Library/Application Support/Supervisor/supervisor.sqlite`
    public var databasePath: URL {
        appSupportDir.appendingPathComponent("supervisor.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/heartbeat.txt`
    public var heartbeatPath: URL {
        appSupportDir.appendingPathComponent("heartbeat.txt", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/rubric.yaml` (v0.1.4+).
    public var rubricPath: URL {
        appSupportDir.appendingPathComponent("rubric.yaml", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/config.yaml`
    public var configPath: URL {
        appSupportDir.appendingPathComponent("config.yaml", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/confirmations.yaml` (v0.1.6+).
    public var confirmationsPath: URL {
        appSupportDir.appendingPathComponent("confirmations.yaml", isDirectory: false)
    }

    /// `~/Library/Logs/Supervisor/supervisor.log`
    public var traceLogPath: URL {
        logsDir.appendingPathComponent("supervisor.log", isDirectory: false)
    }

    /// `~/.claude/projects/` — root of Claude Code's per-project session
    /// directories. Read-only from Supervisor's perspective.
    public var claudeProjectsDir: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Ensure every directory we own exists. Safe to call on every launch;
    /// no-ops if dirs are already there.
    public func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}
